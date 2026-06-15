let infer_and_extend_env env name is_rec rhs =
  match
    (try
      Generalize.enter_level ();
      let rhs_ty =
        if is_rec then begin
          let self_ty = Generalize.fresh_var () in
          let env' = Env.extend env name (Types.Forall ([], self_ty)) in
          let rhs_ty = Infer.infer env' rhs in
          Unify.unify self_ty rhs_ty;
          rhs_ty
        end else
          Infer.infer env rhs
      in
      Generalize.leave_level ();
      let scheme = Generalize.generalize rhs_ty in
      `Ok scheme
    with
    | Error.TypeError e -> `Err (Error.pp_error e)
    | Failure msg       -> `Err msg)
  with
  | `Ok scheme ->
      let env' = Env.extend env name scheme in
      print_endline (name ^ " : " ^ Print.pp_scheme scheme);
      env'
  | `Err msg ->
      print_endline ("Type error: " ^ msg);
      env

let () =
  let env = ref Env.base in
  print_endline "Minos type inference engine";
  print_endline "Type an expression. Ctrl-D to exit.\n";
  try while true do
    print_string "> ";
    flush stdout;
    let line = input_line stdin in
    let line = String.trim line in
    if line = "" then ()
    else begin
      match
        (try
          let tokens = Lexer.tokenize line in
          `Decls (Parser.parse_top tokens)
        with
        | Lexer.LexError msg -> `Err ("Lex error: " ^ msg)
        | Failure msg        -> `Err ("Parse error: " ^ msg))
      with
      | `Err msg -> print_endline msg
      | `Decls decls ->
          List.iter (fun decl ->
            match decl with
            | Parser.DLet (name, is_rec, rhs) ->
                env := infer_and_extend_env !env name is_rec rhs
            | Parser.DExpr expr ->
                (match
                  (try
                    `Ok (Infer.infer_top !env expr)
                  with
                  | Error.TypeError e -> `Err (Error.pp_error e)
                  | Failure msg       -> `Err msg)
                with
                | `Ok scheme ->
                    print_endline ("- : " ^ Print.pp_scheme scheme)
                | `Err msg ->
                    print_endline ("Type error: " ^ msg))
          ) decls
    end
  done
  with End_of_file -> print_newline ()
