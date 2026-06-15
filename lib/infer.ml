open Types
open Generalize
open Unify
open Error

let elaborate (ann : Ast.ty_ann) : ty =
  let tbl : (string, ty) Hashtbl.t = Hashtbl.create 4 in
  let rec go = function
    | Ast.TAVar x ->
        (match Hashtbl.find_opt tbl x with
         | Some t -> t
         | None ->
             let t = fresh_var () in
             Hashtbl.add tbl x t;
             t)
    | Ast.TACon s -> TCon s
    | Ast.TAArr (a, b) -> TArr (go a, go b)
    | Ast.TARec fields ->
        let row = List.fold_right
          (fun (l, t) r -> RExt (l, go t, r))
          fields RNil in
        TRec row
  in
  go ann

let rec infer (env : Env.t) (expr : Ast.expr) : ty =
  match expr with
  | Ast.Lit (Ast.LInt _)  -> TCon "Int"
  | Ast.Lit (Ast.LBool _) -> TCon "Bool"
  | Ast.Lit Ast.LUnit     -> TCon "Unit"

  | Ast.Var x ->
      (match Env.lookup env x with
       | Some scheme -> instantiate scheme
       | None -> raise_unbound x)

  | Ast.Lam (x, body) ->
      let param_ty = fresh_var () in
      let env' = Env.extend env x (Forall ([], param_ty)) in
      let body_ty = infer env' body in
      TArr (param_ty, body_ty)

  | Ast.App (f, arg) ->
      let f_ty   = infer env f in
      let arg_ty = infer env arg in
      let res_ty = fresh_var () in
      unify f_ty (TArr (arg_ty, res_ty));
      res_ty

  | Ast.Let (x, rhs, body) ->
      enter_level ();
      (match infer env rhs with
       | rhs_ty ->
           leave_level ();
           let scheme = generalize rhs_ty in
           let env' = Env.extend env x scheme in
           infer env' body
       | exception e ->
           leave_level ();
           raise e)

  | Ast.LetRec (x, rhs, body) ->
      enter_level ();
      let self_ty = fresh_var () in
      let env'    = Env.extend env x (Forall ([], self_ty)) in
      (match infer env' rhs with
       | rhs_ty ->
           unify self_ty rhs_ty;
           leave_level ();
           let scheme = generalize rhs_ty in
           let env'' = Env.extend env x scheme in
           infer env'' body
       | exception e ->
           leave_level ();
           raise e)

  | Ast.If (cond, then_, else_) ->
      let cond_ty = infer env cond in
      unify cond_ty (TCon "Bool");
      let then_ty = infer env then_ in
      let else_ty = infer env else_ in
      unify then_ty else_ty;
      then_ty

  | Ast.Ann (e, ann) ->
      let t = infer env e in
      let ann_ty = elaborate ann in
      unify t ann_ty;
      t

  | Ast.Record fields ->
      let field_tys = List.map (fun (l, e) -> (l, infer env e)) fields in
      let row = List.fold_right
        (fun (l, t) r -> RExt (l, t, r))
        field_tys RNil in
      TRec row

  | Ast.Select (e, label) ->
      let e_ty     = infer env e in
      let field_ty = fresh_var () in
      let tail     = fresh_row_var () in
      unify e_ty (TRec (RExt (label, field_ty, tail)));
      field_ty

let infer_top (env : Env.t) (expr : Ast.expr) : Types.scheme =
  enter_level ();
  match infer env expr with
  | t ->
      leave_level ();
      generalize t
  | exception e ->
      leave_level ();
      raise e
