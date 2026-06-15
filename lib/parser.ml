type state = {
  tokens : Lexer.token array;
  mutable pos : int;
}

let make_state tokens =
  { tokens = Array.of_list tokens; pos = 0 }

let peek s =
  if s.pos < Array.length s.tokens
  then s.tokens.(s.pos)
  else Lexer.TEOF

let advance s =
  let t = peek s in
  s.pos <- s.pos + 1;
  t

let expect s tok =
  let t = advance s in
  if t <> tok then
    failwith (Printf.sprintf "Expected %s but got %s" (Lexer.show_token tok) (Lexer.show_token t))

let expect_ident s =
  match advance s with
  | Lexer.TIdent x -> x
  | t -> failwith (Printf.sprintf "Expected identifier but got %s" (Lexer.show_token t))

let operators = ["+"; "-"; "*"; "/"; "=="; "<"; ">"]
let is_operator s = List.mem s operators

let op_prec = function
  | "==" | "<" | ">" -> Some 1
  | "+" | "-"        -> Some 2
  | "*" | "/"        -> Some 3
  | _                -> None

let can_start_atom = function
  | Lexer.TInt _ | Lexer.TBool _ | Lexer.TUnit
  | Lexer.TTrue | Lexer.TFalse
  | Lexer.TLParen | Lexer.TLBrace -> true
  | Lexer.TIdent x when not (is_operator x) -> true
  | _ -> false

let rec parse_type s =
  let t = parse_type_atom s in
  match peek s with
  | Lexer.TArrow ->
      ignore (advance s);
      let t2 = parse_type s in
      Ast.TAArr (t, t2)
  | _ -> t

and parse_type_atom s =
  match peek s with
  | Lexer.TIdent x ->
      ignore (advance s);
      if x = String.lowercase_ascii x && String.length x = 1 then Ast.TAVar x
      else Ast.TACon x
  | Lexer.TLParen ->
      ignore (advance s);
      let t = parse_type s in
      expect s Lexer.TRParen;
      t
  | Lexer.TLBrace ->
      ignore (advance s);
      let fields = parse_type_fields s in
      expect s Lexer.TRBrace;
      Ast.TARec fields
  | t -> failwith (Printf.sprintf "Expected type but got %s" (Lexer.show_token t))

and parse_type_fields s =
  let label = expect_ident s in
  expect s Lexer.TColon;
  let ty = parse_type s in
  let rest = match peek s with
    | Lexer.TComma -> ignore (advance s); parse_type_fields s
    | _ -> []
  in
  (label, ty) :: rest

let rec parse_expr s =
  match peek s with
  | Lexer.TLet -> parse_let s
  | Lexer.TFun -> parse_fun s
  | Lexer.TIf  -> parse_if s
  | _          -> parse_ann s

and parse_ann s =
  let e = parse_binop 1 s in
  match peek s with
  | Lexer.TColon ->
      ignore (advance s);
      let ann = parse_type s in
      Ast.Ann (e, ann)
  | _ -> e

and parse_binop min_prec s =
  let left = ref (parse_app s) in
  let continue_loop = ref true in
  while !continue_loop do
    match peek s with
    | Lexer.TIdent op ->
        (match op_prec op with
         | Some p when p >= min_prec ->
             ignore (advance s);
             let right = parse_binop (p + 1) s in
             left := Ast.App (Ast.App (Ast.Var op, !left), right)
         | _ -> continue_loop := false)
    | _ -> continue_loop := false
  done;
  !left

and parse_app s =
  let head = parse_atom s in
  let rec loop acc =
    if can_start_atom (peek s) then
      let arg = parse_atom s in
      loop (Ast.App (acc, arg))
    else acc
  in
  loop head

and parse_atom s =
  let base = match peek s with
    | Lexer.TInt n  -> ignore (advance s); Ast.Lit (Ast.LInt n)
    | Lexer.TTrue   -> ignore (advance s); Ast.Lit (Ast.LBool true)
    | Lexer.TFalse  -> ignore (advance s); Ast.Lit (Ast.LBool false)
    | Lexer.TBool b -> ignore (advance s); Ast.Lit (Ast.LBool b)
    | Lexer.TUnit   -> ignore (advance s); Ast.Lit Ast.LUnit
    | Lexer.TIdent x -> ignore (advance s); Ast.Var x
    | Lexer.TLParen ->
        ignore (advance s);
        let e = parse_expr s in
        expect s Lexer.TRParen;
        e
    | Lexer.TLBrace -> parse_record s
    | t -> failwith (Printf.sprintf "Expected expression but got %s" (Lexer.show_token t))
  in
  (* handle dot-selection chains *)
  let rec loop acc =
    match peek s with
    | Lexer.TDot ->
        ignore (advance s);
        let label = expect_ident s in
        loop (Ast.Select (acc, label))
    | _ -> acc
  in
  loop base

and parse_record s =
  expect s Lexer.TLBrace;
  let fields = parse_record_fields s in
  expect s Lexer.TRBrace;
  Ast.Record fields

and parse_record_fields s =
  match peek s with
  | Lexer.TRBrace -> []
  | _ ->
      let label = expect_ident s in
      expect s Lexer.TEquals;
      let e = parse_expr s in
      let rest = match peek s with
        | Lexer.TComma -> ignore (advance s); parse_record_fields s
        | _ -> []
      in
      (label, e) :: rest

and parse_let s =
  expect s Lexer.TLet;
  let is_rec = match peek s with
    | Lexer.TRec -> ignore (advance s); true
    | _ -> false
  in
  let name = expect_ident s in
  expect s Lexer.TEquals;
  let rhs = parse_expr s in
  match peek s with
  | Lexer.TIn ->
      ignore (advance s);
      let body = parse_expr s in
      if is_rec then Ast.LetRec (name, rhs, body)
      else Ast.Let (name, rhs, body)
  | _ ->
      (* top-level let without 'in' - wrap in a sentinel *)
      if is_rec then Ast.LetRec (name, rhs, Ast.Var name)
      else Ast.Let (name, rhs, Ast.Var name)

and parse_fun s =
  expect s Lexer.TFun;
  let params = ref [] in
  while (match peek s with Lexer.TIdent _ -> true | _ -> false) do
    params := expect_ident s :: !params
  done;
  if !params = [] then failwith "fun requires at least one parameter";
  expect s Lexer.TArrow;
  let body = parse_expr s in
  List.fold_right (fun p acc -> Ast.Lam (p, acc)) (List.rev !params) body

and parse_if s =
  expect s Lexer.TIf;
  let cond = parse_expr s in
  expect s Lexer.TThen;
  let then_ = parse_expr s in
  expect s Lexer.TElse;
  let else_ = parse_expr s in
  Ast.If (cond, then_, else_)

let parse (tokens : Lexer.token list) : Ast.expr =
  let s = make_state tokens in
  let e = parse_expr s in
  (match peek s with
   | Lexer.TEOF -> ()
   | t -> failwith (Printf.sprintf "Unexpected token after expression: %s" (Lexer.show_token t)));
  e

(* Parse a sequence of top-level declarations *)
type top_decl =
  | DLet    of string * bool * Ast.expr  (* name, is_rec, rhs *)
  | DExpr   of Ast.expr

let parse_top (tokens : Lexer.token list) : top_decl list =
  let s = make_state tokens in
  let decls = ref [] in
  while peek s <> Lexer.TEOF do
    let d = match peek s with
      | Lexer.TLet ->
          ignore (advance s);
          let is_rec = match peek s with
            | Lexer.TRec -> ignore (advance s); true
            | _ -> false
          in
          let name = expect_ident s in
          expect s Lexer.TEquals;
          let rhs = parse_expr s in
          (* consume optional 'in' for compat *)
          (match peek s with Lexer.TIn -> ignore (advance s) | _ -> ());
          DLet (name, is_rec, rhs)
      | _ ->
          let e = parse_expr s in
          DExpr e
    in
    decls := d :: !decls;
    (* skip optional semicolons between decls *)
    while peek s = Lexer.TSemicolon do ignore (advance s) done
  done;
  List.rev !decls
