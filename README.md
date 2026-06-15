# Minos

A from-scratch Hindley-Milner type inference engine written in OCaml, extended with row polymorphism for structural records. Compiled to JavaScript via js_of_ocaml and served as an interactive browser playground.

```
fun r -> r.x + r.y   :   { x: Int, y: Int | a } -> Int
let id = fun x -> x  :   a -> a
fun x -> x x         --  occurs check failed
```

## Build

```bash
opam switch create . ocaml.5.1.0
eval $(opam env)
opam install dune alcotest js_of_ocaml js_of_ocaml-ppx

dune build
dune test

# build the JS bundle and open the playground
dune build && cp _build/default/web/main_js.bc.js web/
open web/index.html
```

## Architecture

```
lib/
  ast.ml          surface syntax (Lit, Lam, App, Let, LetRec, Record, Select, Ann)
  types.ml        internal types: TVar, TCon, TArr, TRec; rows: RNil, RExt, RVar
  env.ml          typing environment and base bindings (+, -, *, /, <, >, ==, not)
  lexer.ml        hand-rolled scanner; infix operators emitted as TIdent
  parser.ml       recursive descent; Pratt-style precedence for binary operators
  infer.ml        constraint generation and the HM inference pass
  unify.ml        unification with occurs check and level compression
  generalize.ml   level-based let-generalization and instantiation
  print.ml        type pretty-printer; assigns a, b, c, ... in order of appearance
  error.ml        error types and error-raising helpers
bin/
  main.ml         native REPL; supports top-level let bindings without `in`
web/
  main_js.ml      js_of_ocaml entry point; exports Minos.infer(string) → JSON
  index.html      playground shell
  editor.js       CodeMirror setup, debounce, type annotation rendering
  style.css       dark-theme styles
test/
  test_infer.ml   22 Alcotest tests covering literals, identity, let-poly,
                  recursion, records, and expected type errors
```

## Language

```
expr  ::= let (rec)? x = expr in expr
        | fun x+ -> expr
        | if expr then expr else expr
        | expr (op expr)*          -- infix +, -, *, /, ==, <, >
        | expr expr+               -- application (tightest)
        | expr.label               -- field selection
        | { label = expr, ... }    -- record literal
        | ( expr )
        | expr : type              -- type annotation

type  ::= type -> type
        | { label: type, ... }
        | { label: type, ... | a } -- open row
        | Con | a
```

The base environment provides `+`, `-`, `*`, `/` (`Int → Int → Int`) and `<`, `>`, `==` (`Int → Int → Bool`).

## Deviations from the original spec

The CLAUDE.md spec describes the algorithm correctly at the level of prose and invariants, but contains four bugs in the reference code. Each one is non-obvious — they only surface once the system is end-to-end and producing output you can reason about.

---

### 1. OCaml evaluates function arguments right-to-left

The type printer assigns names `a`, `b`, `c`, … to type variables in order of first appearance. The spec writes:

```ocaml
let s = go true a ^ " -> " ^ go false b in
```

OCaml's evaluation order for function arguments is unspecified; in practice it is right-to-left. `(^)` is just a two-argument function, so `go false b` is called *before* `go true a`. This means the right-hand side of every arrow gets named first.

For `fun f -> fun x -> f x`, the correct type is `(a -> b) -> a -> b`. With right-to-left evaluation, `b` (the result type) is named "a" and `a` (the argument type) is named "b", producing `(b -> a) -> b -> a` instead.

The fix is to force evaluation order with explicit bindings:

```ocaml
let sa = go true a in
let sb = go false b in
let s = sa ^ " -> " ^ sb in
```

The same issue affects `go_row` for record fields.

---

### 2. Row unification has `l1` and `l2` swapped

After flattening both rows and partitioning fields into `only_in1` (labels in r1 not in r2) and `only_in2` (labels in r2 not in r1), the algorithm must wire up each row's tail to contain the other side's leftovers, so that both rows end up structurally equal after unification.

The correct assignment:
- **r1's tail** ← labels from `only_in2` + fresh shared tail
- **r2's tail** ← labels from `only_in1` + fresh shared tail

The spec code does the opposite — `r1`'s tail gets `only_in1` (fields r1 *already has*) and `r2`'s tail gets `only_in2` (fields r2 *already has*). This creates rows with duplicate labels.

Concretely, unifying `{ x: Int | r1 }` with `{ y: Bool | r2 }` produced `{ x: Int, x: Int | a }` instead of `{ x: Int, y: Bool | a }`.

The fix in the general case:

```ocaml
r1_tail := Link(TRec(make_row only_in2 (Some fresh)));
r2_tail := Link(TRec(make_row only_in1 (Some fresh)))
```

---

### 3. Unifying a type variable with itself triggers the occurs check

The occurs check scans a type for a given variable ID before linking. When `unify(t, t)` is called with the *same* type variable on both sides (which happens during `LetRec` inference when `unify self_ty rhs_ty` resolves to the same `TVar`), the occurs check finds the ID inside itself and raises `OccursCheck`.

This is conceptually wrong — unifying something with itself is always safe and is a no-op. The fix is to bail out with a physical equality check before anything else:

```ocaml
let rec unify t1 t2 =
  let t1 = Types.repr t1 in
  let t2 = Types.repr t2 in
  if t1 == t2 then ()        (* same ref — nothing to do *)
  else match t1, t2 with
  ...
```

Without this, `let rec f = fun x -> f x in f` raises `OccursCheck` instead of inferring `a -> b`.

---

### 4. `current_level` leaks when inference raises an exception

`current_level` is a global integer that tracks how many `let`-binders deep the inferencer currently is. `enter_level` increments it before inferring a `let` RHS; `leave_level` decrements it after. Variables created at a deeper level than `current_level` at generalization time are safe to universally quantify.

The spec's `infer_top` does not protect against exceptions:

```ocaml
let infer_top env expr =
  enter_level ();
  let t = infer env expr in   (* if this raises, leave_level is never called *)
  leave_level ();
  generalize t
```

If any expression fails to type-check, `current_level` is left one higher than it should be. Every subsequent inference call then enters at a level one too high, generalizes at a level one too high, and so on. In a test suite that runs many cases sequentially this accumulates silently — the types still come out *correct*, but the variable IDs used for level checks are off in ways that are hard to diagnose.

The fix is to restore the level even on failure:

```ocaml
let infer_top env expr =
  enter_level ();
  match infer env expr with
  | t           -> leave_level (); generalize t
  | exception e -> leave_level (); raise e
```

The same pattern applies to the `Let` and `LetRec` inference cases.

---

## References

- Damas and Milner, "Principal type-schemes for functional programs" (1982)
- Oleg Kiselyov, "How the OCaml type checker works" — the level-based generalization trick
- Didier Rémy, "Type inference for records in natural extension of ML" (1989)
- Leijen, "Extensible records with scoped labels" (2005)
