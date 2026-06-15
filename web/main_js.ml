open Js_of_ocaml

let infer_string s =
  match
    (try
      let tokens = Lexer.tokenize s in
      let expr   = Parser.parse tokens in
      let scheme = Infer.infer_top Env.base expr in
      `Ok (Print.pp_scheme scheme)
    with
    | Error.TypeError e  -> `Err (Error.pp_error e)
    | Failure msg        -> `Err msg
    | Lexer.LexError msg -> `Err ("Lex error: " ^ msg))
  with
  | `Ok result ->
      {|{"ok":true,"type":"|} ^ String.escaped result ^ {|"|}  ^ "}"
  | `Err msg ->
      {|{"ok":false,"error":"|} ^ String.escaped msg ^ {|"|}  ^ "}"

let () =
  Js.export "Minos"
    (object%js
      method infer (s : Js.js_string Js.t) : Js.js_string Js.t =
        Js.string (infer_string (Js.to_string s))
    end)
