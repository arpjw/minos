let current_level = ref 0

let enter_level () = incr current_level
let leave_level () = decr current_level

let fresh_var () =
  let id = Types.fresh_id () in
  Types.TVar (ref (Types.Unbound (id, !current_level)))

let fresh_row_var () =
  let id = Types.fresh_id () in
  Types.RVar (ref (Types.Unbound (id, !current_level)))

let generalize (t : Types.ty) : Types.scheme =
  let vars = ref [] in
  let rec go = function
    | Types.TVar { contents = Types.Link t } -> go t
    | Types.TVar { contents = Types.Unbound (id, lvl) } when lvl > !current_level ->
        if not (List.mem id !vars) then vars := id :: !vars
    | Types.TVar _ -> ()
    | Types.TCon _ -> ()
    | Types.TArr (a, b) -> go a; go b
    | Types.TRec row -> go_row row
  and go_row = function
    | Types.RNil -> ()
    | Types.RExt (_, t, r) -> go t; go_row r
    | Types.RVar { contents = Types.Link (Types.TRec r) } -> go_row r
    | Types.RVar { contents = Types.Link _ } -> ()
    | Types.RVar { contents = Types.Unbound (id, lvl) } when lvl > !current_level ->
        if not (List.mem id !vars) then vars := id :: !vars
    | Types.RVar _ -> ()
  in
  go t;
  Types.Forall (!vars, t)

let instantiate (Types.Forall (ids, t)) : Types.ty =
  if ids = [] then t
  else begin
    let subst = List.map (fun id -> (id, fresh_var ())) ids in
    let rec go = function
      | Types.TVar { contents = Types.Link t } -> go t
      | Types.TVar { contents = Types.Unbound (id, _) } as tv ->
          (match List.assoc_opt id subst with
           | Some fresh -> fresh
           | None -> tv)
      | Types.TCon _ as t -> t
      | Types.TArr (a, b) -> Types.TArr (go a, go b)
      | Types.TRec row -> Types.TRec (go_row row)
    and go_row = function
      | Types.RNil -> Types.RNil
      | Types.RExt (l, t, r) -> Types.RExt (l, go t, go_row r)
      | Types.RVar { contents = Types.Link (Types.TRec r) } -> go_row r
      | Types.RVar { contents = Types.Link _ } -> Types.RNil
      | Types.RVar { contents = Types.Unbound (id, _) } as rv ->
          (match List.assoc_opt id subst with
           | Some (Types.TVar r) -> Types.RVar r
           | Some _ -> failwith "instantiate: expected row variable substitution"
           | None -> rv)
    in
    go t
  end
