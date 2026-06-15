type level = int

type ty =
  | TVar  of tvar ref
  | TCon  of string
  | TArr  of ty * ty
  | TRec  of row

and tvar =
  | Unbound of int * level
  | Link    of ty

and row =
  | RNil
  | RExt  of string * ty * row
  | RVar  of tvar ref

type scheme = Forall of int list * ty

let next_id = ref 0
let fresh_id () = incr next_id; !next_id

let rec repr = function
  | TVar { contents = Link t } -> repr t
  | t -> t
