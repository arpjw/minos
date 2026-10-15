open Alcotest

let infer_string s =
  (* Reset id counter for reproducibility *)
  let tokens = Lexer.tokenize s in
  let expr   = Parser.parse tokens in
  Print.pp_scheme (Infer.infer_top Env.base expr)

let check_infers name input expected =
  test_case name `Quick (fun () ->
    check string name expected (infer_string input))

let check_fails name input =
  test_case name `Quick (fun () ->
    match (try ignore (infer_string input); false
           with Error.TypeError _ -> true) with
    | true -> ()
    | false -> fail (name ^ ": expected type error but succeeded"))

let level_tests = [
  test_case "failed recursive unification restores level" `Quick (fun () ->
    let before = !(Generalize.current_level) in
    let expr = Parser.parse (Lexer.tokenize "let rec f = f 1 in f") in
    (match (try ignore (Infer.infer_top Env.base expr); false
            with Error.TypeError _ -> true) with
     | true -> ()
     | false -> fail "expected recursive type error");
    check int "level after failure" before !(Generalize.current_level));
]

let identity_tests = [
  check_infers "identity" "fun x -> x" "a -> a";
  check_infers "const" "fun x -> fun y -> x" "a -> b -> a";
  check_infers "compose"
    "fun f -> fun g -> fun x -> f (g x)"
    "(a -> b) -> (c -> a) -> c -> b";
  check_infers "apply" "fun f -> fun x -> f x" "(a -> b) -> a -> b";
]

let let_poly_tests = [
  check_infers "let id int" "let id = fun x -> x in id 42" "Int";
  check_infers "let id bool" "let id = fun x -> x in let _ = id 42 in id true" "Bool";
  check_infers "let id poly"
    "let id = fun x -> x in id"
    "a -> a";
  check_infers "let const"
    "let const = fun x -> fun y -> x in const"
    "a -> b -> a";
]

let literal_tests = [
  check_infers "int lit" "42" "Int";
  check_infers "bool lit" "true" "Bool";
  check_infers "unit lit" "()" "Unit";
  check_infers "arithmetic" "1 + 2" "Int";
  check_infers "comparison" "1 < 2" "Bool";
]

let if_tests = [
  check_infers "if" "if true then 1 else 0" "Int";
  check_infers "if bool" "if true then false else true" "Bool";
]

let rec_tests = [
  check_infers "let rec diverge" "let rec f = fun x -> f x in f" "a -> b";
]

let record_tests = [
  check_infers "record lit" "{ x = 1, y = true }" "{ x: Int, y: Bool }";
  check_infers "select" "fun r -> r.x" "{ x: a | b } -> a";
  check_infers "select int" "fun r -> r.x + r.y" "{ x: Int, y: Int | a } -> Int";
  check_infers "select applied"
    "let get_x = fun r -> r.x in get_x { x = 1, y = 2 }"
    "Int";
]

let error_tests = [
  check_fails "unify int bool" "fun x -> x + true";
  check_fails "occurs check" "fun x -> x x";
]

let () =
  run "Minos" [
    "literals",   literal_tests;
    "identity",   identity_tests;
    "let-poly",   let_poly_tests;
    "if",         if_tests;
    "recursion",  rec_tests;
    "records",    record_tests;
    "errors",     error_tests;
    "levels",     level_tests;
  ]
