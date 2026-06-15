let pp_ty (t : Types.ty) : string =
  let counter = ref 0 in
  let names : (int, string) Hashtbl.t = Hashtbl.create 8 in
  let name_of id =
    match Hashtbl.find_opt names id with
    | Some n -> n
    | None ->
        let i = !counter in
        incr counter;
        let letter = Char.chr (Char.code 'a' + (i mod 26)) in
        let n = if i < 26 then String.make 1 letter
                else String.make 1 letter ^ string_of_int (i / 26) in
        Hashtbl.add names id n;
        n
  in
  let rec go parens = function
    | Types.TVar { contents = Types.Link t } -> go parens t
    | Types.TVar { contents = Types.Unbound (id, _) } -> name_of id
    | Types.TCon s -> s
    | Types.TArr (a, b) ->
        let sa = go true a in
        let sb = go false b in
        let s = sa ^ " -> " ^ sb in
        if parens then "(" ^ s ^ ")" else s
    | Types.TRec row ->
        let inner = go_row row in
        if inner = "" then "{}" else "{ " ^ inner ^ " }"
  and go_row = function
    | Types.RNil -> ""
    | Types.RExt (l, t, Types.RNil) ->
        let st = go false t in
        l ^ ": " ^ st
    | Types.RExt (l, t, (Types.RExt _ as r)) ->
        let st = go false t in
        let sr = go_row r in
        l ^ ": " ^ st ^ ", " ^ sr
    | Types.RExt (l, t, Types.RVar { contents = Types.Unbound (id, _) }) ->
        let st = go false t in
        l ^ ": " ^ st ^ " | " ^ name_of id
    | Types.RExt (l, t, Types.RVar { contents = Types.Link (Types.TRec r) }) ->
        go_row (Types.RExt (l, t, r))
    | Types.RExt (l, t, Types.RVar { contents = Types.Link _ }) ->
        l ^ ": " ^ go false t
    | Types.RVar { contents = Types.Unbound (id, _) } -> "| " ^ name_of id
    | Types.RVar { contents = Types.Link (Types.TRec r) } -> go_row r
    | Types.RVar { contents = Types.Link _ } -> ""
  in
  go false t

let pp_scheme (Types.Forall (_, t)) : string =
  pp_ty t
