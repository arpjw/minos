module StringMap = Map.Make(String)

type t = Types.scheme StringMap.t

let empty : t = StringMap.empty

let extend (env : t) (name : string) (s : Types.scheme) : t =
  StringMap.add name s env

let lookup (env : t) (name : string) : Types.scheme option =
  StringMap.find_opt name env

let remove (env : t) (name : string) : t =
  StringMap.remove name env

let base : t =
  let int_op = Types.(Forall ([], TArr (TCon "Int", TArr (TCon "Int", TCon "Int")))) in
  let cmp_op = Types.(Forall ([], TArr (TCon "Int", TArr (TCon "Int", TCon "Bool")))) in
  List.fold_left (fun env (name, s) -> extend env name s) empty
    [ ("+",  int_op)
    ; ("-",  int_op)
    ; ("*",  int_op)
    ; ("/",  int_op)
    ; ("<",  cmp_op)
    ; (">",  cmp_op)
    ; ("==", cmp_op)
    ; ("not", Types.Forall ([], Types.TArr (Types.TCon "Bool", Types.TCon "Bool")))
    ]
