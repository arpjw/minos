type error =
  | UnificationFailure of Types.ty * Types.ty
  | OccursCheck        of int * Types.ty
  | UnboundVariable    of string
  | RowLabelMismatch   of string

exception TypeError of error

let raise_unification t1 t2 = raise (TypeError (UnificationFailure (t1, t2)))
let raise_occurs id t       = raise (TypeError (OccursCheck (id, t)))
let raise_unbound x         = raise (TypeError (UnboundVariable x))

let pp_error = function
  | UnificationFailure (t1, t2) ->
      let rec pp_ty = function
        | Types.TVar { contents = Types.Link t } -> pp_ty t
        | Types.TVar { contents = Types.Unbound (id, _) } -> Printf.sprintf "'%d" id
        | Types.TCon s -> s
        | Types.TArr (a, b) -> Printf.sprintf "(%s -> %s)" (pp_ty a) (pp_ty b)
        | Types.TRec _ -> "{...}"
      in
      Printf.sprintf "cannot unify %s with %s" (pp_ty t1) (pp_ty t2)
  | OccursCheck (id, _) ->
      Printf.sprintf "occurs check failed for variable '%d" id
  | UnboundVariable x ->
      Printf.sprintf "unbound variable: %s" x
  | RowLabelMismatch l ->
      Printf.sprintf "row label mismatch: %s" l
