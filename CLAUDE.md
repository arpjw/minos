# Minos

A from-scratch Hindley-Milner type inference engine written in OCaml, extended with
row polymorphism for structural records, compiled to JavaScript via js_of_ocaml and
served as an interactive browser playground.

---

## Repository Layout

```
minos/
  lib/
    ast.ml              -- expression and literal types
    types.ml            -- type representation, type variables, rows
    env.ml              -- typing environment and type schemes
    lexer.ml            -- tokenizer
    parser.ml           -- recursive descent parser
    infer.ml            -- constraint generation, instantiation, generalization
    unify.ml            -- unification algorithm
    generalize.ml       -- level-based let-generalization
    print.ml            -- type pretty printer
    error.ml            -- error types and source location tracking
  bin/
    main.ml             -- native REPL entry point
  web/
    main_js.ml          -- js_of_ocaml entry point, exposes infer to JS
    index.html          -- playground shell
    editor.js           -- CodeMirror setup, debounce, type overlay rendering
    style.css           -- playground styles
  test/
    test_infer.ml       -- Alcotest test suite
  dune-project
  dune                  -- build rules for lib, bin, web, test
  README.md
```

---

## Phase 0: Project Scaffold

**Goal:** A compilable, empty project with correct dune configuration and dependency
pinning. Nothing runs yet, but `dune build` succeeds.

### Steps

**0.1 — Initialize opam switch**

Create a local opam switch pinned to OCaml 5.1.0. OCaml 5.x is required for the
Effect handler runtime and for the latest js_of_ocaml compatibility.

```
opam switch create . ocaml.5.1.0
eval $(opam env)
```

**0.2 — Install dependencies**

```
opam install dune alcotest menhir sedlex js_of_ocaml js_of_ocaml-ppx
```

Dependency rationale:
- `dune` — build system
- `alcotest` — test framework (clean output, good diffing)
- `menhir` — parser generator (used optionally; you may hand-roll instead)
- `sedlex` — Unicode-aware lexer generator (optional if hand-rolling)
- `js_of_ocaml` — OCaml to JavaScript compiler
- `js_of_ocaml-ppx` — ppx for JavaScript FFI annotations

**0.3 — Write dune-project**

```lisp
(lang dune 3.14)
(name minos)
```

**0.4 — Write root dune file**

```lisp
(library
 (name minos_lib)
 (modules ast types env lexer parser infer unify generalize print error)
 (libraries str))

(executable
 (name main)
 (modules main)
 (libraries minos_lib))

(executable
 (name main_js)
 (modules main_js)
 (libraries minos_lib js_of_ocaml)
 (js_of_ocaml (flags (:standard --opt 3))))

(test
 (name test_infer)
 (modules test_infer)
 (libraries minos_lib alcotest))
```

**0.5 — Create stub files**

Create each file in `lib/`, `bin/`, `web/`, and `test/` with a single comment line.
Run `dune build` and confirm it succeeds before moving on.

---

## Phase 1: AST and Type Definitions

**Goal:** Define the two core data types the entire project operates on. No logic,
only structure.

### Steps

**1.1 — Write ast.ml**

```ocaml
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
```

`Ann` carries an explicit type annotation written by the user. `Record` and `Select`
are the surface syntax for row-polymorphic records. `ty_ann` is the user-facing type
syntax (before inference); `ty` in types.ml is the internal representation (after
elaboration). They are deliberately separate.

`LetRec` handles recursive let-bindings (`let rec f = ...`) as a distinct node so
inference can treat the fixpoint correctly without hacking the normal `Let` case.

**1.2 — Write types.ml**

```ocaml
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
```

Detailed explanation of each constructor:

`TVar (ref (Unbound (id, level)))` — a type variable not yet unified with anything.
`id` is a unique integer. `level` is the binding depth at which this variable was
created, used to decide which variables can be generalized at a `let` boundary.

`TVar (ref (Link t))` — a type variable that has been unified. Following chains of
`Link`s leads to the canonical type. You must always follow links before inspecting
a type variable — write a `repr` function that does this.

`TCon s` — a ground type constructor. `"Int"`, `"Bool"`, `"Unit"`.

`TArr (a, b)` — function type `a -> b`.

`TRec row` — a record type described by a row.

`RNil` — the empty row (closed record, no more fields).
`RExt (label, ty, rest)` — a row with one more field `label : ty` prepended to `rest`.
`RVar (ref ...)` — an open row variable; unifying it adds more fields.

`scheme = Forall (ids, ty)` — a polymorphic type. `ids` are the integer IDs of the
type variables universally quantified over. When you instantiate a scheme, you replace
each variable in `ids` with a fresh `Unbound` at the current level.

**1.3 — Write a repr function in types.ml**

```ocaml
let rec repr = function
  | TVar { contents = Link t } -> repr t
  | t -> t
```

Every function in unify.ml and infer.ml must call `repr` before pattern matching on
a type. Without this, you will match on stale `Link`-wrapped types and get wrong
behavior. Build this habit from the start.

**1.4 — Run dune build**

Both files have no external dependencies yet. Build must succeed before proceeding.

---

## Phase 2: Typing Environment

**Goal:** A module that maps variable names to type schemes and supports the standard
environment operations needed during inference.

### Steps

**2.1 — Write env.ml**

```ocaml
module StringMap = Map.Make(String)

type t = Types.scheme StringMap.t

let empty : t = StringMap.empty

let extend (env : t) (name : string) (s : Types.scheme) : t =
  StringMap.add name s env

let lookup (env : t) (name : string) : Types.scheme option =
  StringMap.find_opt name env

let remove (env : t) (name : string) : t =
  StringMap.remove name env
```

`t` is a purely functional map. You never mutate it — you always produce a new
extended environment when entering a binder. This is correct because OCaml's
`Map.Make` is persistent.

**2.2 — Add a base environment**

```ocaml
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
    ; ("not", Forall ([], TArr (TCon "Bool", TCon "Bool")))
    ]
```

This gives the REPL arithmetic and comparison without needing to parse primitive
declarations. The inferencer treats these exactly like user-defined let-bindings.

---

## Phase 3: Lexer

**Goal:** Convert a string of source text into a list of tokens. No interpretation,
no tree structure — just classification of character sequences.

### Steps

**3.1 — Define the token type in lexer.ml**

```ocaml
type token =
  | TInt    of int
  | TBool   of bool
  | TIdent  of string
  | TLet
  | TRec
  | TIn
  | TFun
  | TIf
  | TThen
  | TElse
  | TTrue
  | TFalse
  | TUnit
  | TArrow          (* -> *)
  | TFatArrow       (* => reserved for future use *)
  | TEquals
  | TColon
  | TDot
  | TPipe
  | TLParen
  | TRParen
  | TLBrace
  | TRBrace
  | TComma
  | TSemicolon
  | TEOF
```

**3.2 — Write the lexer as a hand-rolled scanner**

Use a `pos` ref tracking current index into a `string`. Write helper functions:

- `peek () : char option` — look at current char without advancing
- `advance () : char` — return current char and increment pos
- `skip_while f` — advance while `f (peek ())` holds
- `read_while f : string` — collect chars while predicate holds, return as string

The main function is `next_token () : token`. It calls `skip_while is_whitespace`,
then dispatches on the current character:

- Digit → read digits into a string, `int_of_string`, return `TInt`
- Letter or underscore → read identifier, check against keyword table
- `(` → return `TLParen`; but first peek for `()`  → `TUnit`
- `-` → peek for `>`, if found return `TArrow`, else lex as operator
- `{`, `}`, `,`, `;`, `:`, `|`, `.` → single-character tokens
- `=` → peek for `=`, if found return `TEqEq`, else `TEquals`
- End of string → return `TEOF`
- Anything else → raise a `LexError` with position

**3.3 — Write tokenize : string -> token list**

Repeatedly call `next_token` until `TEOF`, collecting results into a list. Include
`TEOF` as the last element so the parser always has a sentinel to check against.

**3.4 — Test the lexer manually**

Before writing the parser, test tokenize on these strings and print the results:

```
"let f = fun x -> x"
"let rec fact = fun n -> if n == 0 then 1 else n * fact (n - 1)"
"{ x = 1, y = true }"
```

Fix any issues before proceeding. The lexer must be correct before the parser can work.

---

## Phase 4: Parser

**Goal:** Convert a token list into an Ast.expr. Use recursive descent — no
generator, no menhir. Recursive descent gives better error messages and is
sufficient for this grammar.

### Steps

**4.1 — Set up the parser state**

```ocaml
type state = {
  mutable tokens : Lexer.token list;
  mutable pos    : int;
}

let make_state tokens = { tokens; pos = 0 }

let peek s =
  if s.pos < List.length s.tokens
  then List.nth s.tokens s.pos
  else Lexer.TEOF

let advance s =
  let t = peek s in
  s.pos <- s.pos + 1;
  t

let expect s tok =
  let t = advance s in
  if t <> tok then
    failwith (Printf.sprintf "Expected %s" (Lexer.show_token tok))
```

`show_token` is a function you write that converts a token to a string for error
messages. Write it now — you will call it constantly during debugging.

**4.2 — Write the grammar**

The grammar in precedence order, lowest to highest:

```
expr     ::= let_expr | fun_expr | if_expr | ann_expr
ann_expr ::= app_expr (: type)?
app_expr ::= atom+                        (left-associative application)
atom     ::= int | bool | unit | ident | ( expr ) | { record } | atom . label

let_expr ::= let rec? ident = expr in expr
fun_expr ::= fun ident+ -> expr
if_expr  ::= if expr then expr else expr

type     ::= type_atom (-> type)?         (right-associative)
type_atom::= ident | ( type ) | { row }
row      ::= label : type (, label : type)* (| ident)?
```

Application is left-associative and binds tighter than everything else. This means
`f x y` parses as `App (App (f, x), y)`. Implement `parse_app` by parsing atoms in
a loop until the next token cannot start an atom, then fold them left.

**4.3 — Implement parse_expr, parse_app, parse_atom**

`parse_expr` checks the leading token and dispatches:
- `TLet` → `parse_let`
- `TFun` → `parse_fun`
- `TIf`  → `parse_if`
- else → `parse_ann`

`parse_ann` calls `parse_app`, then checks for `TColon`; if present, parses a type
annotation and wraps in `Ann`.

`parse_app` enters a loop collecting atoms, exits when `peek` is not a valid atom
start. If one atom, return it. If multiple, fold: `List.fold_left (fun acc e -> App
(acc, e)) head rest`.

`parse_atom` dispatches on token:
- `TInt n` → advance, return `Lit (LInt n)`
- `TTrue` / `TFalse` → advance, return `Lit (LBool ...)`
- `TUnit` → advance, return `Lit LUnit`
- `TIdent x` → advance, return `Var x`
- `TLParen` → advance, parse_expr, expect `TRParen`, return expr
- `TLBrace` → `parse_record`
- else → `failwith "Expected expression"`

**4.4 — Implement parse_let**

```
expect TLet
is_rec <- peek = TRec (advance if so)
name <- expect TIdent, extract string
expect TEquals
rhs <- parse_expr
expect TIn
body <- parse_expr
return if is_rec then LetRec (name, rhs, body) else Let (name, rhs, body)
```

**4.5 — Implement parse_fun**

```
expect TFun
params <- read one or more TIdent (loop until token is not TIdent)
expect TArrow
body <- parse_expr
return fold_right (fun p acc -> Lam (p, acc)) params body
```

`fold_right` here is correct: `fun x y -> e` should parse as `Lam ("x", Lam ("y",
e))`, not the other way around.

**4.6 — Implement parse_record and parse_select**

`parse_record` reads `{ label = expr, ... }` and returns `Record [(label, expr)]`.
Labels are `TIdent`. Fields are comma-separated. Closing `}` terminates.

`parse_select` is handled in `parse_atom` after parsing any atom: after you have an
atom, check if `peek = TDot`. If so, advance, read `TIdent` as label, wrap in
`Select (atom, label)`, and loop (to handle `r.x.y` chains).

**4.7 — Test the parser**

Write a `string_of_expr` function and test parse → print round-trips on:

```
"let id = fun x -> x in id 42"
"fun x -> fun y -> x"
"if true then 1 else 0"
"let f = fun r -> r.x in f { x = 1, y = 2 }"
"let rec fact = fun n -> if n == 0 then 1 else n * (fact (n - 1)) in fact 5"
```

Fix all parsing issues before touching inference.

---

## Phase 5: Unification

**Goal:** The function `unify : ty -> ty -> unit` that makes two types equal by
mutating type variable refs. This is the core algorithmic kernel of the whole system.
Write and test it before inference so you can trust it in isolation.

### Steps

**5.1 — Write error.ml**

```ocaml
type error =
  | UnificationFailure of Types.ty * Types.ty
  | OccursCheck        of int * Types.ty
  | UnboundVariable    of string
  | RowLabelMismatch   of string

exception TypeError of error

let raise_unification t1 t2 = raise (TypeError (UnificationFailure (t1, t2)))
let raise_occurs id t       = raise (TypeError (OccursCheck (id, t)))
let raise_unbound x         = raise (TypeError (UnboundVariable x))
```

**5.2 — Write occurs_check in unify.ml**

```ocaml
let occurs (id : int) (level : int) (t : Types.ty) : unit =
  let rec go = function
    | Types.TVar { contents = Types.Link t }      -> go t
    | Types.TVar ({ contents = Types.Unbound (id', lvl) } as r) ->
        if id = id' then Error.raise_occurs id t
        else if lvl > level then r := Types.Unbound (id', level)
    | Types.TCon _         -> ()
    | Types.TArr (a, b)   -> go a; go b
    | Types.TRec row       -> go_row row
  and go_row = function
    | Types.RNil            -> ()
    | Types.RExt (_, t, r) -> go t; go_row r
    | Types.RVar { contents = Types.Link (Types.TRec row) } -> go_row row
    | Types.RVar { contents = Types.Unbound (id', lvl) } as r ->
        if id = id' then Error.raise_occurs id t
        else if lvl > level then
          (match r with
           | { contents = Types.Unbound (i, _) } -> r := Types.Unbound (i, level)
           | _ -> ())
    | Types.RVar _ -> ()
  in
  go t
```

The occurs check does two things simultaneously: it detects infinite types (same ID
appears inside itself) and it performs level compression. Level compression is the
key optimization: when you encounter a type variable at a deeper level than the
current binding level, you lower its level. This prevents variables from being
generalized when they are constrained by outer scopes.

**5.3 — Write unify in unify.ml**

```ocaml
let rec unify (t1 : Types.ty) (t2 : Types.ty) : unit =
  let t1 = Types.repr t1 in
  let t2 = Types.repr t2 in
  match t1, t2 with
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
```

Call `repr` on both arguments first, every time. The match on `TVar` handles both
orders (variable on left or right) in a single case using OCaml's or-pattern. When
the variable is on the right side, `t` is the left side. After the occurs check,
mutate `r` to point at `t`.

**5.4 — Write unify_rows in unify.ml**

Row unification is more involved. The algorithm:

Given rows `r1` and `r2`, rewrite both into canonical form: a list of `(label, ty)`
pairs and an optional tail variable. Then:
- For each label in `r1`, find the same label in `r2` and unify their types.
- Labels in `r1` not in `r2` must be unified into `r2`'s tail variable (if any).
- Labels in `r2` not in `r1` must be unified into `r1`'s tail variable (if any).
- If both have tails, the leftover labels go into a fresh row variable shared by both.
- If one has no tail and there are leftover labels from the other, it is a type error.

```ocaml
and unify_rows (r1 : Types.row) (r2 : Types.row) : unit =
  let flatten_row row =
    let rec go acc = function
      | Types.RNil -> (List.rev acc, None)
      | Types.RExt (l, t, rest) -> go ((l, t) :: acc) rest
      | Types.RVar { contents = Types.Link (Types.TRec r) } -> go acc r
      | Types.RVar { contents = Types.Link _ } -> failwith "ill-formed row link"
      | Types.RVar r -> (List.rev acc, Some r)
    in go [] row
  in
  let (fields1, tail1) = flatten_row r1 in
  let (fields2, tail2) = flatten_row r2 in
  (* match up shared labels, collect leftovers *)
  let matched  = ref [] in
  let only_in1 = ref [] in
  let only_in2 = ref [] in
  List.iter (fun (l, t) ->
    match List.assoc_opt l fields2 with
    | Some t' -> matched := (l, t, t') :: !matched
    | None    -> only_in1 := (l, t) :: !only_in1
  ) fields1;
  List.iter (fun (l, t) ->
    if not (List.mem_assoc l fields1) then
      only_in2 := (l, t) :: !only_in2
  ) fields2;
  List.iter (fun (_, t1, t2) -> unify t1 t2) !matched;
  let make_row fields tail =
    List.fold_right (fun (l, t) r -> Types.RExt (l, t, r)) fields
      (match tail with Some r -> Types.RVar r | None -> Types.RNil)
  in
  (match !only_in1, !only_in2, tail1, tail2 with
   | [], [], None,    None    -> ()
   | [], [], Some r1, Some r2 when r1 == r2 -> ()
   | [], [], Some r,  None   -> r := Types.Link (Types.TRec Types.RNil)
   | [], [], None,   Some r  -> r := Types.Link (Types.TRec Types.RNil)
   | [], [], Some r1, Some r2 ->
       let fresh = Types.RVar (ref (Types.Unbound (fresh_id (), 0))) in
       r1 := Types.Link (Types.TRec fresh);
       r2 := Types.Link (Types.TRec fresh)
   | l1, [],  None,    _     -> Error.raise_unification (Types.TRec r1) (Types.TRec r2)
   | [],  l2, _,      None   -> Error.raise_unification (Types.TRec r1) (Types.TRec r2)
   | l1, [],  Some r, _      -> r := Types.Link (Types.TRec (make_row l1 tail2))
   | [],  l2, _,     Some r  -> r := Types.Link (Types.TRec (make_row l2 tail1))
   | l1, l2,  Some r1, Some r2 ->
       let fresh_r = ref (Types.Unbound (fresh_id (), 0)) in
       r1 := Types.Link (Types.TRec (make_row l1 (Some fresh_r)));
       r2 := Types.Link (Types.TRec (make_row l2 (Some fresh_r)))
   | _ -> Error.raise_unification (Types.TRec r1) (Types.TRec r2))
```

This is the most complex function in the project. Test it thoroughly in isolation
before connecting it to inference.

**5.5 — Add fresh_id to types.ml**

```ocaml
let next_id = ref 0
let fresh_id () = incr next_id; !next_id
```

A global counter for type variable IDs. Simple and sufficient.

**5.6 — Test unification**

Write unit tests covering:

- `unify (TCon "Int") (TCon "Int")` → no error
- `unify (TCon "Int") (TCon "Bool")` → UnificationFailure
- `unify (TVar a) (TCon "Int")` → a becomes Link (TCon "Int")
- `unify (TVar a) (TArr (TVar a, TCon "Int"))` → OccursCheck
- `unify (TRec (RExt ("x", TCon "Int", RNil))) (TRec (RExt ("x", TCon "Bool", RNil)))` → UnificationFailure
- `unify (TRec (RExt ("x", TCon "Int", RVar r))) (TRec (RExt ("y", TCon "Bool", RNil)))` → r becomes RExt ("y", Bool, RNil)

All six must pass before proceeding.

---

## Phase 6: Generalization and Instantiation

**Goal:** The two functions that implement let-polymorphism. This is the hardest
conceptual step.

### Steps

**6.1 — Write generalize.ml**

```ocaml
let current_level = ref 0

let enter_level () = incr current_level
let leave_level () = decr current_level

let fresh_var () =
  let id = Types.fresh_id () in
  Types.TVar (ref (Types.Unbound (id, !current_level)))

let fresh_row_var () =
  let id = Types.fresh_id () in
  Types.RVar (ref (Types.Unbound (id, !current_level)))
```

`current_level` is a global int tracking how many `let` bindings deep you currently
are. It starts at 0. When you enter the RHS of a `let`, increment it. When you leave,
decrement it. Type variables created at a given level can only be generalized by
bindings at or above that level.

**6.2 — Write generalize**

```ocaml
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
    | Types.RVar { contents = Types.Unbound (id, lvl) } when lvl > !current_level ->
        if not (List.mem id !vars) then vars := id :: !vars
    | Types.RVar _ -> ()
  in
  go t;
  Types.Forall (!vars, t)
```

Walk the type. Collect IDs of `Unbound` variables whose level exceeds the current
level. These are the variables that do not appear free in any outer scope, so they
are safe to universally quantify. Return a `Forall` scheme.

**6.3 — Write instantiate**

```ocaml
let instantiate (Types.Forall (ids, t)) : Types.ty =
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
    | Types.RVar { contents = Types.Unbound (id, _) } as rv ->
        (match List.assoc_opt id subst with
         | Some (Types.TVar r) -> Types.RVar r
         | Some _ -> failwith "instantiate: expected row variable substitution"
         | None -> rv)
  in
  go t
```

For each quantified variable, create a fresh unbound variable at the current level.
Build a substitution table. Walk the type replacing old variable IDs with fresh ones.
This produces a new copy of the type where all polymorphic variables are fresh, ready
to be unified independently at each use site.

**6.4 — Test generalize and instantiate**

Test:
- Infer `fun x -> x` at level 0, generalize → `Forall ([a], TArr (TVar a, TVar a))`
- Instantiate that scheme twice → two different fresh type variables, not the same ref
- A type variable at level 0 when `current_level = 0` is NOT generalized (it would
  escape its scope)

---

## Phase 7: Type Inference

**Goal:** The main inference pass. Given an environment and an expression, produce a
type. This is where phases 1–6 come together.

### Steps

**7.1 — Write infer.ml header**

```ocaml
open Types
open Generalize
open Unify
open Error

let rec infer (env : Env.t) (expr : Ast.expr) : ty =
  match expr with
  ...
```

**7.2 — Implement Lit case**

```ocaml
| Ast.Lit (Ast.LInt _)  -> TCon "Int"
| Ast.Lit (Ast.LBool _) -> TCon "Bool"
| Ast.Lit Ast.LUnit     -> TCon "Unit"
```

**7.3 — Implement Var case**

```ocaml
| Ast.Var x ->
    (match Env.lookup env x with
     | Some scheme -> instantiate scheme
     | None -> raise_unbound x)
```

Look up the variable, instantiate its scheme with fresh type variables. Every use of
a polymorphic function gets fresh copies.

**7.4 — Implement Lam case**

```ocaml
| Ast.Lam (x, body) ->
    let param_ty = fresh_var () in
    let env' = Env.extend env x (Forall ([], param_ty)) in
    let body_ty = infer env' body in
    TArr (param_ty, body_ty)
```

The parameter gets a monomorphic scheme `Forall ([], param_ty)` — lambda parameters
are not polymorphic (only `let`-bound values are). Infer the body in the extended
environment. Return `param_ty -> body_ty`.

**7.5 — Implement App case**

```ocaml
| Ast.App (f, arg) ->
    let f_ty   = infer env f in
    let arg_ty = infer env arg in
    let res_ty = fresh_var () in
    unify f_ty (TArr (arg_ty, res_ty));
    res_ty
```

Create a fresh result type variable. Assert that the function's type must be
`arg_ty -> res_ty`. Unification fills in the details. Return `res_ty`.

**7.6 — Implement Let case**

```ocaml
| Ast.Let (x, rhs, body) ->
    enter_level ();
    let rhs_ty = infer env rhs in
    leave_level ();
    let scheme = generalize rhs_ty in
    let env' = Env.extend env x scheme in
    infer env' body
```

Enter a level before inferring the RHS so that type variables created during RHS
inference get a deeper level number. After leaving the level, generalize: variables
at the deeper level become universally quantified. Extend the environment with the
scheme and infer the body.

The `enter_level` / `leave_level` sandwich is the entire mechanism of
let-polymorphism. Without it, `id` would not get a polymorphic type.

**7.7 — Implement LetRec case**

```ocaml
| Ast.LetRec (x, rhs, body) ->
    enter_level ();
    let self_ty = fresh_var () in
    let env'    = Env.extend env x (Forall ([], self_ty)) in
    let rhs_ty  = infer env' rhs in
    unify self_ty rhs_ty;
    leave_level ();
    let scheme = generalize rhs_ty in
    let env'' = Env.extend env x scheme in
    infer env'' body
```

For `let rec`, create a fresh variable for the recursive name, extend the environment
with it (monomorphically so it cannot be used polymorphically within its own
definition), infer the RHS, unify the fresh variable with the inferred type (this
constrains the recursion), then generalize and proceed.

**7.8 — Implement If case**

```ocaml
| Ast.If (cond, then_, else_) ->
    let cond_ty = infer env cond in
    unify cond_ty (TCon "Bool");
    let then_ty = infer env then_ in
    let else_ty = infer env else_ in
    unify then_ty else_ty;
    then_ty
```

**7.9 — Implement Ann case**

```ocaml
| Ast.Ann (e, ann) ->
    let t = infer env e in
    let ann_ty = elaborate ann in
    unify t ann_ty;
    t
```

`elaborate : Ast.ty_ann -> Types.ty` converts user-written type syntax into the
internal `ty`. A `TAVar` in a user annotation becomes a fresh type variable the
first time it's seen (use a local string table mapping annotation variable names to
fresh `TVar`s, scoped to the annotation).

**7.10 — Implement Record case**

```ocaml
| Ast.Record fields ->
    let field_tys = List.map (fun (l, e) -> (l, infer env e)) fields in
    let row = List.fold_right
      (fun (l, t) r -> RExt (l, t, r))
      field_tys RNil in
    TRec row
```

**7.11 — Implement Select case**

```ocaml
| Ast.Select (e, label) ->
    let e_ty    = infer env e in
    let field_ty = fresh_var () in
    let tail    = fresh_row_var () in
    unify e_ty (TRec (RExt (label, field_ty, tail)));
    field_ty
```

This is the key row polymorphism operation. Assert that the expression's type must be
a record containing `label : field_ty` plus some unknown rest `tail`. The tail
variable ensures the function works on any record that *has* the label, not just
records with *only* that label.

**7.12 — Write infer_top : Env.t -> Ast.expr -> Types.scheme**

```ocaml
let infer_top (env : Env.t) (expr : Ast.expr) : Types.scheme =
  enter_level ();
  let t = infer env expr in
  leave_level ();
  generalize t
```

Entry point for the REPL. Runs inference at a fresh level and generalizes the result.

---

## Phase 8: Type Pretty Printer

**Goal:** Convert an internal type back into human-readable notation, assigning
letters `a`, `b`, `c`, ... to type variables in order of first appearance.

### Steps

**8.1 — Write print.ml**

```ocaml
let fresh_name =
  let counter = ref 0 in
  fun () ->
    let i = !counter in
    incr counter;
    let letter = Char.chr (Char.code 'a' + (i mod 26)) in
    if i < 26 then String.make 1 letter
    else String.make 1 letter ^ string_of_int (i / 26)

let pp_ty (t : Types.ty) : string =
  let names : (int, string) Hashtbl.t = Hashtbl.create 8 in
  let name_of id =
    match Hashtbl.find_opt names id with
    | Some n -> n
    | None ->
        let n = fresh_name () in
        Hashtbl.add names id n;
        n
  in
  let rec go parens = function
    | Types.TVar { contents = Types.Link t } -> go parens t
    | Types.TVar { contents = Types.Unbound (id, _) } -> name_of id
    | Types.TCon s -> s
    | Types.TArr (a, b) ->
        let s = go true a ^ " -> " ^ go false b in
        if parens then "(" ^ s ^ ")" else s
    | Types.TRec row -> "{ " ^ go_row row ^ " }"
  and go_row = function
    | Types.RNil -> ""
    | Types.RExt (l, t, Types.RNil) -> l ^ ": " ^ go false t
    | Types.RExt (l, t, (Types.RExt _ as r)) ->
        l ^ ": " ^ go false t ^ ", " ^ go_row r
    | Types.RExt (l, t, Types.RVar { contents = Types.Unbound (id, _) }) ->
        l ^ ": " ^ go false t ^ " | " ^ name_of id
    | Types.RExt (l, t, Types.RVar { contents = Types.Link (Types.TRec r) }) ->
        go_row (Types.RExt (l, t, r))
    | Types.RVar { contents = Types.Unbound (id, _) } -> "| " ^ name_of id
    | Types.RVar { contents = Types.Link (Types.TRec r) } -> go_row r
    | _ -> "..."
  in
  go false t

let pp_scheme (Types.Forall (ids, t)) : string =
  if ids = [] then pp_ty t
  else
    let s = pp_ty t in
    let vars = String.concat " " (List.map (fun _ -> "") ids) in
    ignore vars; s
```

The `pp_scheme` function does not print explicit `∀` binders in output — that would
be noisy in a REPL. The type variables are already named via the `names` table. Just
print the type.

**8.2 — Test the printer**

- `∀a. a -> a` should print as `a -> a`
- `∀a b. a -> b -> a` should print as `a -> b -> a`
- `{ x: Int, y: Bool }` should print as `{ x: Int, y: Bool }`
- `∀r. { x: Int | r } -> Int` should print as `{ x: Int | a } -> Int`

Consistent variable naming across multiple calls requires resetting the counter.
Reset `fresh_name`'s counter at the start of each `pp_scheme` call, or pass the name
table in from outside.

---

## Phase 9: Native REPL

**Goal:** An interactive read-eval-print loop in the terminal where users type
expressions and see inferred types.

### Steps

**9.1 — Write bin/main.ml**

```ocaml
let () =
  let env = ref Env.base in
  print_endline "Minos type inference engine";
  print_endline "Type an expression. Ctrl-D to exit.\n";
  try while true do
    print_string "> ";
    flush stdout;
    let line = input_line stdin in
    if String.trim line = "" then ()
    else begin
      match
        let tokens = Lexer.tokenize line in
        let expr   = Parser.parse tokens in
        let scheme = Infer.infer_top !env expr in
        Ok scheme
      with
      | Ok scheme ->
          print_endline ("- : " ^ Print.pp_scheme scheme)
      | exception Error.TypeError e ->
          print_endline ("Type error: " ^ Error.pp_error e)
      | exception Failure msg ->
          print_endline ("Error: " ^ msg)
    end
  done
  with End_of_file -> print_newline ()
```

**9.2 — Add let-binding at the REPL top level**

Extend the grammar to allow top-level `let x = expr` without an `in` body (the REPL
case). When parsed, infer the type, extend `env`, and print `x : type`.

```ocaml
| "let" binding without "in" ->
    let scheme = Infer.infer_top !env rhs in
    env := Env.extend !env name scheme;
    print_endline (name ^ " : " ^ Print.pp_scheme scheme)
```

**9.3 — Test the REPL end-to-end**

Run these in sequence and verify output:

```
> let id = fun x -> x
id : a -> a

> id 42
- : Int

> id true
- : Bool

> let const = fun x -> fun y -> x
const : a -> b -> a

> let rec fact = fun n -> if n == 0 then 1 else n * (fact (n - 1))
fact : Int -> Int

> fun x -> x + true
Type error: cannot unify Int with Bool

> let get_x = fun r -> r.x
get_x : { x: a | b } -> a

> get_x { x = 1, y = 2 }
- : Int
```

All of these must produce correct output before proceeding to the web playground.

---

## Phase 10: Test Suite

**Goal:** A comprehensive Alcotest suite covering inference correctness. Run before
every commit.

### Steps

**10.1 — Write test/test_infer.ml structure**

```ocaml
open Alcotest

let infer_string s =
  let tokens = Lexer.tokenize s in
  let expr   = Parser.parse tokens in
  Print.pp_scheme (Infer.infer_top Env.base expr)

let check_infers name input expected =
  test_case name `Quick (fun () ->
    check string name expected (infer_string input))

let check_fails name input =
  test_case name `Quick (fun () ->
    check_raises name (fun _ -> true) (fun () -> ignore (infer_string input)))
```

**10.2 — Write test cases covering:**

Identity and composition:
- `fun x -> x` → `a -> a`
- `fun f -> fun g -> fun x -> f (g x)` → `(b -> c) -> (a -> b) -> a -> c`

Let polymorphism:
- `let id = fun x -> x in id 42` → `Int`
- `let id = fun x -> x in let _ = id 42 in id true` → `Bool`

Recursion:
- `let rec f = fun x -> f x in f` → `a -> b`

Records:
- `{ x = 1, y = true }` → `{ x: Int, y: Bool }`
- `fun r -> r.x` → `{ x: a | b } -> a`
- `fun r -> r.x + r.y` → `{ x: Int, y: Int | a } -> Int`

Errors:
- `fun x -> x + true` → fails UnificationFailure
- `fun x -> x x` → fails OccursCheck
- `fun r -> r.x + r.y` when y is Bool → fails UnificationFailure

**10.3 — Run with `dune test`**

All tests must pass. Any failure is a regression to fix before continuing.

---

## Phase 11: js_of_ocaml Compilation

**Goal:** Compile the OCaml inference engine to JavaScript so it can run in a browser.

### Steps

**11.1 — Write web/main_js.ml**

```ocaml
open Js_of_ocaml

let () =
  Js.export "Minos"
    (object%js
      method infer (s : Js.js_string Js.t) : Js.js_string Js.t =
        let s = Js.to_string s in
        Js.string (
          match
            let tokens = Lexer.tokenize s in
            let expr   = Parser.parse tokens in
            let scheme = Infer.infer_top Env.base expr in
            Ok (Print.pp_scheme scheme)
          with
          | Ok result -> {|{"ok": true, "type": "|} ^ result ^ {|"}|}
          | exception Error.TypeError e ->
              {|{"ok": false, "error": "|} ^ Error.pp_error e ^ {|"}|}
          | exception Failure msg ->
              {|{"ok": false, "error": "|} ^ msg ^ {|"}|}
        )
    end)
```

This exports a single global `Minos.infer(string)` function callable from JavaScript.
It takes a source string, runs the full pipeline, and returns a JSON string with
either `{ok: true, type: "..."}` or `{ok: false, error: "..."}`.

**11.2 — Add js_of_ocaml build rule to dune**

```lisp
(executable
 (name main_js)
 (modules main_js)
 (libraries minos_lib js_of_ocaml)
 (js_of_ocaml
  (flags (:standard --opt 3 --source-map))))
```

Build with `dune build web/main_js.bc.js`.

**11.3 — Test the JS output**

Load `main_js.bc.js` in a browser console or Node.js:

```javascript
const result = JSON.parse(Minos.infer("let id = fun x -> x in id 42"));
console.log(result); // { ok: true, type: "Int" }
```

Verify the JSON output format before building the playground UI.

---

## Phase 12: Playground UI

**Goal:** A split-pane browser playground. Left pane: code editor with syntax
highlighting. Right pane: inferred types displayed inline, updated as you type.

### Design

Dark background (#0b0b0b). Monospace editor font (JetBrains Mono or Berkeley Mono).
Type annotations appear in a muted accent color (#b3ff00 at 60% opacity, matching
Robin Neon). Error messages in a soft red (#ff6b6b). The right pane shows each
expression on its corresponding line with the inferred type beside it.

The playground has no server. Everything runs in the browser via the compiled JS.

### Steps

**12.1 — Write web/index.html**

```html
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <title>Minos — Type Inference Playground</title>
  <link rel="stylesheet" href="style.css">
  <link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/codemirror/5.65.16/codemirror.min.css">
</head>
<body>
  <header>
    <span class="logo">Minos</span>
    <span class="tagline">Hindley-Milner + Row Polymorphism</span>
    <a href="https://github.com/arpjw/minos" class="gh-link">GitHub</a>
  </header>
  <main>
    <div class="pane" id="editor-pane">
      <div id="editor"></div>
    </div>
    <div class="pane" id="output-pane">
      <pre id="output"></pre>
    </div>
  </main>
  <script src="https://cdnjs.cloudflare.com/ajax/libs/codemirror/5.65.16/codemirror.min.js"></script>
  <script src="main_js.bc.js"></script>
  <script src="editor.js"></script>
</body>
</html>
```

**12.2 — Write web/style.css**

Key design tokens:

```css
:root {
  --bg:       #0b0b0b;
  --surface:  #141414;
  --border:   #222;
  --text:     #e8e8e8;
  --muted:    #666;
  --accent:   #b3ff00;
  --error:    #ff6b6b;
  --font-mono: 'JetBrains Mono', 'Fira Code', monospace;
  --font-ui:  'DM Sans', system-ui, sans-serif;
}

* { box-sizing: border-box; margin: 0; padding: 0; }
body { background: var(--bg); color: var(--text); font-family: var(--font-ui); height: 100vh; display: flex; flex-direction: column; }
header { display: flex; align-items: center; gap: 1rem; padding: 0.75rem 1.5rem; border-bottom: 1px solid var(--border); }
.logo { font-family: var(--font-mono); font-size: 1rem; color: var(--accent); }
.tagline { font-size: 0.8rem; color: var(--muted); }
.gh-link { margin-left: auto; font-size: 0.8rem; color: var(--muted); text-decoration: none; }
main { display: flex; flex: 1; overflow: hidden; }
.pane { flex: 1; overflow: auto; border-right: 1px solid var(--border); }
.pane:last-child { border-right: none; }
#output { padding: 1rem 1.5rem; font-family: var(--font-mono); font-size: 0.875rem; line-height: 1.75; white-space: pre-wrap; }
.type-ok  { color: var(--accent); opacity: 0.8; }
.type-err { color: var(--error); }
.CodeMirror { height: 100%; background: var(--surface); color: var(--text); font-family: var(--font-mono); font-size: 0.875rem; line-height: 1.75; }
```

**12.3 — Write web/editor.js**

```javascript
const DEFAULT = `-- Minos Playground
-- Type inference with row polymorphism

let id = fun x -> x

let const = fun x -> fun y -> x

let rec fact = fun n ->
  if n == 0 then 1 else n * (fact (n - 1))

-- Row polymorphism
let get_x = fun r -> r.x
let pair   = { x = 1, y = true }
`;

const editor = CodeMirror(document.getElementById('editor'), {
  value: DEFAULT,
  mode: 'mllike',
  theme: 'minos',
  lineNumbers: true,
  lineWrapping: false,
  indentUnit: 2,
  tabSize: 2,
});

function inferLine(line) {
  const trimmed = line.trim();
  if (!trimmed || trimmed.startsWith('--')) return null;
  try {
    const result = JSON.parse(Minos.infer(trimmed));
    return result;
  } catch (e) {
    return { ok: false, error: e.message };
  }
}

function render() {
  const lines = editor.getValue().split('\n');
  const output = document.getElementById('output');
  const parts = lines.map(line => {
    const trimmed = line.trim();
    if (!trimmed) return '';
    if (trimmed.startsWith('--')) return `<span class="type-ok">${trimmed}</span>`;
    const result = inferLine(line);
    if (!result) return '';
    if (result.ok) {
      return `<span class="type-ok">${line.padEnd(40)} : ${result.type}</span>`;
    } else {
      return `<span class="type-err">${line.padEnd(40)} -- ${result.error}</span>`;
    }
  });
  output.innerHTML = parts.join('\n');
}

let debounce;
editor.on('change', () => {
  clearTimeout(debounce);
  debounce = setTimeout(render, 150);
});

render();
```

150ms debounce prevents inference on every keystroke while keeping the playground
feeling responsive.

**12.4 — Handle multi-line expressions**

The naive approach infers each line independently. This fails for multi-line `let`
expressions. The correct approach: parse the entire buffer as a sequence of top-level
declarations, infer each in order (threading the environment forward), and annotate
the line range each declaration occupies.

Implement `Infer.infer_program : Env.t -> (Ast.decl * span) list -> (string * scheme * span) list`
where `span = { start_line: int; end_line: int }`. The JS side calls this once per
buffer change instead of once per line.

**12.5 — Add example programs to the playground**

Include a dropdown with three example programs:

- "Basics" — id, const, compose, arithmetic
- "Recursion" — factorial, fibonacci, list map (if lists are implemented)
- "Row Polymorphism" — get_x, update_x, point operations showing the row tail variable

---

## Phase 13: Deployment

**Goal:** The playground is live at a public URL.

### Steps

**13.1 — Build the JS bundle**

```
dune build web/main_js.bc.js
cp _build/default/web/main_js.bc.js web/
```

**13.2 — Deploy to GitHub Pages**

Create a `gh-pages` branch containing the contents of `web/`. The compiled
`main_js.bc.js` (typically 1–3MB) ships alongside `index.html`, `style.css`, and
`editor.js`. No server required.

```
git subtree push --prefix web origin gh-pages
```

Configure the repository to serve GitHub Pages from the `gh-pages` branch.

**13.3 — Set up a custom domain (optional)**

Add a `CNAME` file to the `web/` directory. Point a DNS `A` record to GitHub Pages
IPs. The playground is then live at `minos.yourdomain.com`.

---

## Build Order Summary

Phase 0: scaffold — `dune build` succeeds on empty stubs
Phase 1: `ast.ml`, `types.ml` — data types only
Phase 2: `env.ml` — environment and base bindings
Phase 3: `lexer.ml` — tokenizer, test on raw strings
Phase 4: `parser.ml` — recursive descent, test parse → print
Phase 5: `unify.ml`, `error.ml` — unification + occurs check, test in isolation
Phase 6: `generalize.ml` — generalize + instantiate, test level behavior
Phase 7: `infer.ml` — full inference pass, test case by case
Phase 8: `print.ml` — type printer, test naming consistency
Phase 9: `bin/main.ml` — REPL, end-to-end test
Phase 10: `test/test_infer.ml` — full Alcotest suite, all passing
Phase 11: `web/main_js.ml` — js_of_ocaml compilation, test in Node
Phase 12: `web/` — playground HTML/CSS/JS, test in browser
Phase 13: deploy to GitHub Pages

---

## Key Invariants

Never inspect a `TVar` without calling `repr` first.
Never skip the occurs check before setting a `TVar` to `Link`.
Always call `enter_level` before inferring a `let` RHS and `leave_level` after.
Never generalize a type variable whose level is <= `current_level`.
Row unification must handle both open and closed rows in every combination.
The JS API returns JSON strings, never raw OCaml exceptions.

---

## Common Failure Modes

`id 42` infers `a` instead of `Int` — you forgot to call `repr` somewhere in print.ml.
`let id = fun x -> x in id 42; id true` fails — generalization is broken; check level
logic in `Let` case.
Infinite loop on `fun x -> x x` — occurs check is missing or not being called.
Row unification loops — you have a cycle in your `Link` chain; check that row unify
follows links before inspecting vars.
`main_js.bc.js` is 40MB — you forgot `--opt 3`; rebuild with the optimization flag.

---

## References

Damas and Milner, "Principal type-schemes for functional programs" (1982) — the
original Algorithm W paper.
Oleg Kiselyov, "How OCaml type checker works" — the level-based generalization trick.
Didier Rémy, "Type inference for records in natural extension of ML" (1989) — the row
polymorphism paper.
Leijen, "Extensible records with scoped labels" (2005) — cleaner row polymorphism
formulation.
Real World OCaml, Chapter 26 (js_of_ocaml) — deployment reference.
