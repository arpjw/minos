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
  | TArrow
  | TFatArrow
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

let show_token = function
  | TInt n    -> Printf.sprintf "TInt(%d)" n
  | TBool b   -> Printf.sprintf "TBool(%b)" b
  | TIdent s  -> Printf.sprintf "TIdent(%s)" s
  | TLet      -> "let"
  | TRec      -> "rec"
  | TIn       -> "in"
  | TFun      -> "fun"
  | TIf       -> "if"
  | TThen     -> "then"
  | TElse     -> "else"
  | TTrue     -> "true"
  | TFalse    -> "false"
  | TUnit     -> "()"
  | TArrow    -> "->"
  | TFatArrow -> "=>"
  | TEquals   -> "="
  | TColon    -> ":"
  | TDot      -> "."
  | TPipe     -> "|"
  | TLParen   -> "("
  | TRParen   -> ")"
  | TLBrace   -> "{"
  | TRBrace   -> "}"
  | TComma    -> ","
  | TSemicolon -> ";"
  | TEOF      -> "EOF"

let keywords = [
  "let", TLet; "rec", TRec; "in", TIn; "fun", TFun;
  "if", TIf; "then", TThen; "else", TElse;
  "true", TTrue; "false", TFalse;
]

exception LexError of string

let tokenize (src : string) : token list =
  let len = String.length src in
  let pos = ref 0 in
  let peek () = if !pos < len then Some src.[!pos] else None in
  let advance () =
    let c = src.[!pos] in
    incr pos; c
  in
  let skip_while f =
    while (match peek () with Some c -> f c | None -> false) do
      ignore (advance ())
    done
  in
  let read_while f =
    let buf = Buffer.create 8 in
    while (match peek () with Some c -> f c | None -> false) do
      Buffer.add_char buf (advance ())
    done;
    Buffer.contents buf
  in
  let tokens = ref [] in
  let emit t = tokens := t :: !tokens in
  let rec lex () =
    skip_while (fun c -> c = ' ' || c = '\t' || c = '\n' || c = '\r');
    (* skip -- line comments *)
    (match peek () with
     | Some '-' when !pos + 1 < len && src.[!pos + 1] = '-' ->
         skip_while (fun c -> c <> '\n');
         lex ()
     | None -> emit TEOF
     | Some c ->
         (match c with
          | '0'..'9' ->
              let s = read_while (fun c -> c >= '0' && c <= '9') in
              emit (TInt (int_of_string s))
          | 'a'..'z' | 'A'..'Z' | '_' ->
              let s = read_while (fun c ->
                (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
                (c >= '0' && c <= '9') || c = '_' || c = '\'') in
              let tok = match List.assoc_opt s keywords with
                | Some kw -> kw
                | None    -> TIdent s
              in
              emit tok
          | '(' ->
              ignore (advance ());
              (match peek () with
               | Some ')' -> ignore (advance ()); emit TUnit
               | _        -> emit TLParen)
          | ')' -> ignore (advance ()); emit TRParen
          | '{' -> ignore (advance ()); emit TLBrace
          | '}' -> ignore (advance ()); emit TRBrace
          | ',' -> ignore (advance ()); emit TComma
          | ';' -> ignore (advance ()); emit TSemicolon
          | ':' -> ignore (advance ()); emit TColon
          | '|' -> ignore (advance ()); emit TPipe
          | '.' -> ignore (advance ()); emit TDot
          | '-' ->
              ignore (advance ());
              (match peek () with
               | Some '>' -> ignore (advance ()); emit TArrow
               | _ ->
                   (* treat standalone - as an operator: emit as TIdent "-" *)
                   emit (TIdent "-"))
          | '=' ->
              ignore (advance ());
              (match peek () with
               | Some '>' -> ignore (advance ()); emit TFatArrow
               | Some '=' -> ignore (advance ()); emit (TIdent "==")
               | _        -> emit TEquals)
          | '<' ->
              ignore (advance ());
              emit (TIdent "<")
          | '>' ->
              ignore (advance ());
              emit (TIdent ">")
          | '+' -> ignore (advance ()); emit (TIdent "+")
          | '*' -> ignore (advance ()); emit (TIdent "*")
          | '/' -> ignore (advance ()); emit (TIdent "/")
          | _ ->
              raise (LexError (Printf.sprintf "unexpected char '%c' at pos %d" c !pos)));
         if (match List.hd !tokens with TEOF -> false | _ -> true) then lex ())
  in
  lex ();
  List.rev !tokens
