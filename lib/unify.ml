let occurs (id : int) (level : int) (t : Types.ty) : unit =
  let rec go = function
    | Types.TVar { contents = Types.Link t }      -> go t
    | Types.TVar ({ contents = Types.Unbound (id', lvl) } as r) ->
        if id = id' then Error.raise_occurs id t
        else if lvl > level then r := Types.Unbound (id', level)
    | Types.TCon _        -> ()
    | Types.TArr (a, b)  -> go a; go b
    | Types.TRec row      -> go_row row
  and go_row = function
    | Types.RNil             -> ()
    | Types.RExt (_, t, r)  -> go t; go_row r
    | Types.RVar { contents = Types.Link (Types.TRec row) } -> go_row row
    | Types.RVar { contents = Types.Link _ } -> ()
    | Types.RVar ({ contents = Types.Unbound (id', lvl) } as r) ->
        if id = id' then Error.raise_occurs id t
        else if lvl > level then r := Types.Unbound (id', level)
  in
  go t

let rec unify (t1 : Types.ty) (t2 : Types.ty) : unit =
  let t1 = Types.repr t1 in
  let t2 = Types.repr t2 in
  if t1 == t2 then ()
  else match t1, t2 with
  | Types.TCon a, Types.TCon b when a = b -> ()
  | Types.TArr (a1, b1), Types.TArr (a2, b2) ->
      unify a1 a2;
      unify b1 b2
  | Types.TRec r1, Types.TRec r2 ->
      unify_rows r1 r2
  | Types.TVar ({ contents = Types.Unbound (id, lvl) } as r), t
  | t, Types.TVar ({ contents = Types.Unbound (id, lvl) } as r) ->
      occurs id lvl t;
      r := Types.Link t
  | _ ->
      Error.raise_unification t1 t2

(* Flatten a row into a field list and an optional tail variable ref. *)
and flatten_row row =
  let rec go acc = function
    | Types.RNil -> (List.rev acc, None)
    | Types.RExt (l, t, rest) -> go ((l, t) :: acc) rest
    | Types.RVar { contents = Types.Link (Types.TRec r) } -> go acc r
    | Types.RVar { contents = Types.Link _ } -> (List.rev acc, None)
    | Types.RVar r -> (List.rev acc, Some r)
  in
  go [] row

and unify_rows (r1 : Types.row) (r2 : Types.row) : unit =
  let (fields1, tail1) = flatten_row r1 in
  let (fields2, tail2) = flatten_row r2 in
  (* Unify types of shared labels; collect per-side leftovers *)
  let only_in1 = ref [] in
  let only_in2 = ref [] in
  List.iter (fun (l, t) ->
    match List.assoc_opt l fields2 with
    | Some t' -> unify t t'
    | None    -> only_in1 := (l, t) :: !only_in1
  ) fields1;
  List.iter (fun (l, t) ->
    if not (List.mem_assoc l fields1) then
      only_in2 := (l, t) :: !only_in2
  ) fields2;
  let l1 = !only_in1 in   (* in r1, not in r2 → must go into r2's tail *)
  let l2 = !only_in2 in   (* in r2, not in r1 → must go into r1's tail *)
  let make_row fields tail =
    List.fold_right (fun (lbl, t) r -> Types.RExt (lbl, t, r)) fields
      (match tail with Some r -> Types.RVar r | None -> Types.RNil)
  in
  (* Error if a closed side can't absorb the other's extra fields *)
  if l2 <> [] && tail1 = None then
    Error.raise_unification (Types.TRec r1) (Types.TRec r2);
  if l1 <> [] && tail2 = None then
    Error.raise_unification (Types.TRec r1) (Types.TRec r2);
  (* Wire up tails:
       r1's tail must contain l2 (fields r1 doesn't have) + shared fresh tail
       r2's tail must contain l1 (fields r2 doesn't have) + shared fresh tail  *)
  match tail1, tail2 with
  | None, None ->
      (* both closed; already checked l1=[] and l2=[] above *)
      ()
  | Some r, None ->
      (* l1=[] enforced above; l2 may be empty here *)
      r := Types.Link (Types.TRec (make_row l2 None))
  | None, Some r ->
      r := Types.Link (Types.TRec (make_row l1 None))
  | Some r1t, Some r2t ->
      if r1t == r2t then ()  (* same var: rows are already structurally equal *)
      else if l1 = [] && l2 = [] then begin
        (* no leftovers: just link the two tails together *)
        r1t := Types.Link (Types.TRec (Types.RVar r2t))
      end else begin
        let fresh = ref (Types.Unbound (Types.fresh_id (), 0)) in
        (* r1's tail gets the fields r2 has that r1 doesn't (l2), then fresh *)
        r1t := Types.Link (Types.TRec (make_row l2 (Some fresh)));
        (* r2's tail gets the fields r1 has that r2 doesn't (l1), then fresh *)
        r2t := Types.Link (Types.TRec (make_row l1 (Some fresh)))
      end
