type lit =
  | LInt  of int
  | LBool of bool
  | LUnit

type expr =
  | Lit of lit
  | Var of string
  | Lam of string * expr
  | App of expr * expr
  | Let of string * expr * expr
  | LetRec of string * expr * expr
  | If  of expr * expr * expr
  | Ann of expr * ty_ann
  | Record of (string * expr) list
  | Select of expr * string

and ty_ann =
  | TAVar  of string
  | TACon  of string
  | TAArr  of ty_ann * ty_ann
  | TARec  of (string * ty_ann) list
