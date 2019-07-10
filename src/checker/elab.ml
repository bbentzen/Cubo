(**
 * (c) Copyright 2019 Bruno Bentzen. All rights reserved.
 * Released under Apache 2.0 license as described in the file LICENSE.
 * Desc: The elaborator performs the endpoint ε-reductions for dependent paths.
         The unifier implements the boundary separation rule
 **)

open Basis
open Context
open Local
open Ast
open Substitution
open Eval 

let goal_msg ctx e ty =
  "when checking that\n  " ^ Pretty.print e ^ "\nhas the expected type\n" ^ Local.print ctx ^ 
  "-------------------------------------------\n ⊢ " ^ Pretty.print ty

(* Checks whether the type of a given expression is the given type *)

let rec elaborate global ctx lvl sl ty ph vars = function
  | Id x ->
    begin match var_type x ctx with
    | Ok ty' ->
      let c = check_var_ty x ty ctx in
      let h = Placeholder.is ty in
      let h' = Placeholder.is ty' in
      let d = is_declared x ctx in
      begin match c, h, h', d with
      | true , _, _ , _ | _ , _, true , _ ->  
        Ok (Id x, ty, sl)
      | _ , true, _ , _ ->  
        Ok (Id x, ty', sl)
      | false , false, false , true ->
        let h1 = Placeholder.generate ty ph [] in
        begin match elaborate global ctx lvl sl h1 ph vars ty' with
        | Ok (_, tTy', sa) ->
          let u = unify global ctx lvl sl ph vars (eval ty', eval ty, tTy') true in
          begin match u with
          | Ok s -> 
            Ok (Id x, s, sl) 
          | Error (_, msg) ->
            Error (sa, "The variable " ^ x ^ " has type\n   " ^ Pretty.print (eval ty') ^ 
                  "\nbut is expected to have type\n  " ^ Pretty.print ty ^ "\n" ^ msg)
          end
        | Error msg -> (* This case is impossible *)
          Error msg
        end
      | false , false, false , false -> 
        begin match Global.unfold x global with
        | Ok (body, ty') ->
          let h1 = Placeholder.generate ty ph [] in
          begin match elaborate global ctx lvl sl h1 ph vars ty' with
          | Ok (_, tTy', sa) ->
            let u = unify global ctx lvl sl ph vars (eval ty', eval ty, tTy') true in
            begin match u with
            | Ok s -> Ok (body, s, sl)
            | _ -> 
              Error (sa, x ^ " has type \n  " ^ Pretty.print ty' ^ "\nbut is expected to have type\n  " ^ Pretty.print ty)
            end
          | Error msg -> (* This case is impossible *)
            Error msg
          end
        | Error msg -> 
          Error (sl, msg)
        end
      end
    | Error _ -> 
      Error (sl, "No declaration for the variable " ^ x)
    end
    
  | I0() ->
    begin match ty with
    | Ast.Int() -> 
      Ok (I0(), Int(), sl)
    | Hole _ -> 
      Ok (I0(), Int(), sl)
    | _ -> Error (sl, "Type mismatch when checking that the term i0 of type I has type " ^ Pretty.print ty)
  end
  
  | I1() ->
    begin match ty with
    | Ast.Int() -> 
      Ok (I1(), Int(), sl)
    | Hole _ -> 
      Ok (I1(), Int(), sl)
    | _ -> Error (sl, "Type mismatch when checking that the term i1 of type I has type " ^ Pretty.print ty)
    end

  | Abs (x, e) -> 
    begin match ty with
    | Pi (y, ty1, ty2) ->
      let s var = (fst sl, Stack.allconcat var ty1 (snd sl)) in
      if has_var x ty then
        let v1 = fresh_var e ty vars in
        let elab = elaborate global ((v1, ty1, true) :: ctx) lvl (s v1) (subst y (Ast.Id v1) ty2) ph vars e in
        begin match elab with
        | Ok (e', ty2', sa) ->
          Ok (Abs (v1, e'), Pi (v1, ty1, ty2'), sa)
        | Error (sa, msg) -> 
          Error (sa, msg)
        end
      else
        let elab = elaborate global ((x, ty1, true) :: ctx) lvl (s x) (subst y (Ast.Id x) ty2) ph vars e in
        begin match elab with
        | Ok (e', ty2', sa) -> 
          Ok (Abs (x, e'), Pi (x, ty1, ty2'), sa)
        | Error (sa, msg) -> 
          Error (sa, msg)
        end
    | Hole _ -> 
      let h1 = Placeholder.generate ty ph [] in
      let h2 = Placeholder.generate ty (ph+1) [] in
      elaborate global ctx lvl sl (Pi(x, h1, h2)) (ph+2) vars (Abs (x, e))
    | _ -> 
      Error (sl, "The term\n  λ " ^ x ^ ", " ^ Pretty.print e ^ 
      "\nhas type\n  " ^ Pretty.print ty ^ "\nbut is expected to have type\n  Π (v? : ?0?) ?1?")
    end

  | App (e1, e2) ->

    if Placeholder.has_underscore e2 then

      (* for performance reasons we typecheck e1 fist if e2 has implicit arguments *)

      let h1 = Placeholder.generate ty ph [] in
      let v1 = fresh_var e1 ty vars in
      let (h2, ph) = Placeholder.preforget (ph+2) ty in
      let elab1 = elaborate global ctx lvl sl (Pi(v1, h1, h2)) (ph+1) (vars+2) e1 in
      begin match elab1 with
      | Ok (e1', Pi(x, ty1, ty2), sa1) ->
        let elab2 = elaborate global ctx lvl sl ty1 (ph+1) (vars+2) e2 in
        begin 
          match elab2 with
          | Ok (e2', _, sa2) ->
            Ok (App (e1', e2'), subst x e2' ty2, Stack.append sa1 sa2)
          | Error (sa2, msg) -> 
            Error (Stack.append sa1 sa2,
              "Failed application\n  " ^ Pretty.print (App (e1, e2)) ^
              "\nThe term\n  " ^ Pretty.print e2 ^ 
              "\nis expected to have type\n  " ^ Pretty.print ty1 ^ "\n" ^ msg)
          end
        
      | Ok (e1', _, sa1) -> 
        Error (sa1,
          "Failed application\n  " ^ Pretty.print (App (e1', e2)) ^
          "\nThe term\n  " ^ Pretty.print e1' ^ 
          "\nis expected to have type\n " ^ Pretty.print h2)
      | Error (sa, msg) -> 
        Error (sa, msg)
      end

    else

      let h1 = Placeholder.generate ty ph [] in
      let v1 = fresh_var (App(e1, e2)) ty vars in
      let elab2 = elaborate global ctx lvl sl h1 (ph+1) (vars+2) e2 in
      begin match elab2 with
      | Ok (e2', ty2', sa2) ->
        let h2 = Placeholder.generate ty (ph+1) [Id v1; e2; e2'] in
        let helper ty1' =
          let elab1 = elaborate global ctx lvl sl ty1' (ph+1) (vars+2) e1 in
          begin match elab1 with
          | Ok (e1', Pi(x, _, ty'), sa1) ->
            Ok (App (e1', e2'), subst x e2 ty', Stack.append sa1 sa2)
          | Ok (e1', _, sa1) -> 
            Error (Stack.append sa1 sa2, 
              "Failed application\n  " ^ Pretty.print (App (e1', e2')) ^
              "\nThe term\n  " ^ Pretty.print e1' ^ 
              "\nis expected to have type\n " ^ Pretty.print ty1')
          | Error (sa1, msg) -> 
            Error (Stack.append sa1 sa2,
              "Failed application\n  " ^ Pretty.print (App (e1, e2')) ^
              "\nThe term\n  " ^ Pretty.print e1 ^ 
              "\nis expected to have type\n  " ^ Pretty.print ty1' ^ "\n" ^ msg)
          end
        in
        if e2 = e2' then
          let ty1' = Pi(v1, fullsubst e2 h2 ty2', fullsubst e2 h2 ty) in
          helper ty1'
        else
          let subs x = hfullsubst e2' h2 (fullsubst e2 h2 x) in
          let ty1' = Pi(v1, subs ty2', subs ty) in
          helper ty1'
      | Error (sa, msg) -> 
        Error (sa, msg)
      end
    
  | Pair (e1, e2) -> 
    begin match ty with
    | Sigma(y, ty1, ty2) ->
      let elab1 = elaborate global ctx lvl sl ty1 ph vars e1 in
      let elab2 = elaborate global ctx lvl sl (subst y e1 ty2) ph vars e2 in
      begin match elab1, elab2 with
      | Ok (e1', ty1', sa1), Ok (e2', ty2', sa2) ->
        begin match ty2 with
        | Hole (n, l) ->
          let ty' = fullsubst e1' (Hole (n, e1 :: e1' :: Id y :: l)) ty2' in
          Ok (Pair (e1', e2'), Sigma(y, ty1', ty'), Stack.append sa2 sa1)
        | _ ->
          let ty' = fullsubst e1' (Id y) ty2' in
          Ok (Pair (e1', e2'), Sigma(y, ty1', ty'), Stack.append sa2 sa1)
        end
      | Error msg, _ | _, Error msg -> 
        Error msg
      end
    | Hole _ -> 
      let v1 = fresh_var (App (e1, e2)) ty vars in
      let h1 = Placeholder.generate ty 0 [] in
      let h2 = Placeholder.generate ty 1 [] in
      elaborate global ctx lvl sl (Sigma(v1, h1, h2)) (ph+2) (vars+1) (Pair (e1, e2))
    | _ ->
      Error (sl, "Type mismatch when checking that the term (" ^ 
      Pretty.print e1 ^ ", " ^ Pretty.print e2 ^ ") of type Σ (v? : ?0?) ?1? has type " ^ Pretty.print ty)
    end
    
  | Ast.Fst e ->
    let h1 = Placeholder.generate ty 0 [] in
    let elab = elaborate global ctx lvl sl h1 (ph+1) (vars+1) e in
    begin match elab with
    | Ok (e', Sigma(_, ty', _), sa) ->
      let elabTy = elaborate global ctx lvl sl h1 ph vars ty in
      begin match elabTy with
      | Ok (_, tTy, _) ->
        let u = unify global ctx lvl sl ph vars (eval ty, eval ty', tTy) false in
        begin match u with
        | Ok _ ->
          Ok (Fst e', ty', sa) 
        | Error (_, msg) ->
          Error (sa, "Don't know how to unify\n  " ^ Pretty.print ty ^ "\nwith\n  " ^ Pretty.print ty' ^ "\n" ^ msg)
        end
      | Error msg -> (* This case is impossible *)
        Error msg
      end
    | Ok (e', ty', sa) -> 
      Error (sa, "The term\n  " ^ Pretty.print e' ^ "\nhas type\n  " ^ Pretty.print ty' ^ "\nbut is expected to have type\n  Σ (v0 : ?0?) ?1?")
    | Error (sa, msg) ->
      Error (sa, "The term\n  " ^ Pretty.print e ^ "\nis expected to have type\n  Σ (v0 : ?0?) ?1?" ^ "\n" ^ msg)
    end

  | Snd e ->
    let h1 = Placeholder.generate ty 0 [] in
    let elab = elaborate global ctx lvl sl h1 (ph+1) (vars+1) e in
    begin match elab with
    | Ok (e', Sigma(x, _, ty2), sa) ->
      let ty' = subst x (Fst e') ty2 in
      let elabTy = elaborate global ctx lvl sl h1 ph vars ty in
      begin match elabTy with
      | Ok (_, tTy, _) ->
        let u = unify global ctx lvl sl ph vars (eval ty, eval ty', tTy) false in
        begin match u with
        | Ok _ ->
          Ok (Snd e', ty', sa)
        | Error (_, msg) ->
          Error (sa, "Don't know how to unify\n  " ^ Pretty.print ty ^ "\nwith\n  " ^ Pretty.print ty' ^ "\n" ^ msg)
        end
      | Error msg -> (* This case is impossible *)
        Error msg
      end
    | Ok (e', ty', sa) -> 
      Error (sa, "The term\n  " ^ Pretty.print e' ^ "\nhas type\n  " ^ Pretty.print ty' ^ "\nbut is expected to have type\n  Σ (v0 : ?0?) ?1?")
    | Error (sa, msg) ->
      Error (sa, "The term\n  " ^ Pretty.print e ^ "\nis expected to have type\n  Σ (v0 : ?0?) ?1?" ^ "\n" ^ msg)
    end
  
  | Ast.Inl e ->
    begin match ty with
    | Ast.Sum (ty1, ty2) ->
      let elab = elaborate global ctx lvl sl ty1 ph vars e in
      begin match elab with
      | Ok (e', ty1', sa) -> 
        Ok (Inl e', Sum(ty1', ty2), sa)
      | Error msg -> 
        Error msg
      end
    | Hole _ ->
      let h1 = Placeholder.generate ty 0 [] in
      let h2 = Placeholder.generate ty 1 [] in
      elaborate global ctx lvl sl (Sum(h1, h2)) (ph+2) vars (Inl e)
    | _ ->
      Error (sl, "Type mismatch when checking that the term inl " ^ Pretty.print e ^ " of type ?0? + ?1? has type " ^ Pretty.print ty)
    end

  | Ast.Inr e -> 
    begin match ty with
    | Ast.Sum (ty1, ty2) ->
      let elab = elaborate global ctx lvl sl ty2 ph vars e in
      begin match elab with
      | Ok (e', ty2', sa) -> 
        Ok (Inr e', Sum(ty1, ty2'), sa)
      | Error msg -> Error msg
      end
    | Hole _ ->
      let h1 = Placeholder.generate ty 0 [] in
      let h2 = Placeholder.generate ty 1 [] in
      elaborate global ctx lvl sl (Sum(h1, h2)) (ph+2) vars (Inr e)
    | _ -> 
      Error (sl, "Type mismatch when checking that the term inr " ^ Pretty.print e ^ " of type ?0? + ?1? has type " ^ Pretty.print ty)
    end
  
  | Case (e, e1, e2) ->
    let h1 = Placeholder.generate ty 0 [] in
    let h2 = Placeholder.generate ty 1 [] in
    let elab = elaborate global ctx lvl sl (Sum (h1, h2)) (ph+2) vars e in
    begin match elab with
    | Ok (e', Sum (ty1, ty2), sa) ->
      begin match ty with
      | Hole (n, l) ->
        let elab1 = elaborate global ctx lvl sl (Hole (n, l)) ph (vars+1) e1 in
        let elab2 = elaborate global ctx lvl sl (Hole (n, l)) ph (vars+1) e2 in
        begin match elab1, elab2 with
        | Ok (e1', Ast.Pi(x, ty1', tyl), sa1), Ok (e2', Ast.Pi(y, ty2', tyr), sa2) ->
          let elabTy = elaborate global ctx lvl sl h1 ph vars (Ast.Pi(x, ty1', tyl)) in
          begin match elabTy with
          | Ok (_, tTy, _) ->
            let u1 = unify global ctx lvl sl ph vars (ty1, ty1', tTy) false in
            let u2 = unify global ctx lvl sl ph vars (ty2, ty2', tTy) false in
            let tyl' = hfullsubst (Ast.Inl(Id x)) h1 tyl in
            let tyr' = hfullsubst (Ast.Inr(Id y)) h1 tyr in
            begin
              match tyl', tyr' with
              | Type n, Type m ->
                if n > m then
                  Ok (Case(e', e1', e2'), Type n, Stack.lappend sa sa1 sa2)
                else
                  Ok (Case(e', e1', e2'), Type m, Stack.lappend sa sa1 sa2)
              | _ ->
                let u = unify global ctx lvl sl ph vars (tyl', tyr', tTy) false in
                begin match u1, u2, u with
                | Ok _, Ok _, Ok st ->
                  let st' = hfullsubst h1 e st in
                  Ok (Case(e', e1', e2'), st', Stack.lappend sa sa1 sa2)
                | Ok _, Ok _, _ ->
                  Error (Stack.lappend sa sa1 sa2, 
                    "Failed to unify\n  " ^ Pretty.print tyl' ^ "\nwith\n  " ^ Pretty.print tyr')
                | Ok _, _, _ ->
                  Error (Stack.lappend sa sa1 sa2, 
                    "The term\n  " ^ Pretty.print e2' ^ "\nhas type\n  " ^ Pretty.print (Ast.Pi(y, ty2', tyr)) ^ 
                    "\nbut is expected to have type\n  Π (" ^ y ^ " : " ^ Pretty.print ty2 ^ ") ?1?")
                | _ ->
                  Error (Stack.lappend sa sa1 sa2, 
                    "The term\n  " ^ Pretty.print e1' ^ "\nhas type\n  " ^ Pretty.print (Ast.Pi(x, ty1', tyl)) ^ 
                    "\nbut is expected to have type\n  Π (" ^ x ^ " : " ^ Pretty.print ty1 ^ ") ?1?")
              end
            end
          | Error msg -> (* This case is impossible *)
            Error msg
          end

        | Ok (e1', ty', sa'), Ok (_, Pi(_,_,_), _) -> 
          Error (sa', "The term\n  " ^ Pretty.print e1' ^ "\nhas type\n  " ^ Pretty.print ty' ^ 
            "\nbut is expected to have type\n  Π (v? : ?0?) ?1?")
        | Ok _, Ok (e2', ty', sa') -> 
          Error (sa', "The term\n  " ^ Pretty.print e2' ^ "\nhas type\n  " ^ Pretty.print ty' ^ 
            "\nbut is expected to have type\n  Π (v? : ?0?) ?1?")
        | Error msg, _ | _, Error msg -> Error msg
        end
      | _ -> 
        let v1 = fresh_var (Sum(ty1, ty2)) ty vars in
        let elab1 = elaborate global ctx lvl sl (Pi(v1, ty1, fullsubst e (Inl (Id v1)) ty)) ph (vars+1) e1 in
        let elab2 = elaborate global ctx lvl sl (Pi(v1, ty2, fullsubst e (Inr (Id v1)) ty)) ph (vars+1) e2 in
        begin match elab1, elab2 with
        | Ok (e1', _, sa1), Ok (e2', _, sa2) ->
          Ok (Case(e', e1', e2'), ty, Stack.lappend sa sa1 sa2)
        | Error msg, _ | _, Error msg -> Error msg
        end
      end
    | Ok (e', ty', sa) -> 
      Error (sa, "Type mismatch when checking that the term " ^ 
        Pretty.print e' ^ " of type " ^ Pretty.print ty' ^ "has type ?0? + ?1?")
    | Error msg -> 
      Error msg
    end

  | Ast.Zero() ->
    begin match ty with
    | Nat() -> 
      Ok (Zero(), Nat(), sl)
    | Hole _ -> 
      Ok (Zero(), Nat(), sl)
    | _ -> 
      Error (sl, "Type mismatch when checking that the term 0 of type nat has type " ^ Pretty.print ty)
     end

  | Ast.Succ e ->
    let elab = elaborate global ctx lvl sl (Ast.Nat()) ph vars e in
    begin match elab, ty with
    | Ok (e', _, sa), Ast.Nat() -> 
      Ok (Succ e', Nat(), sa)
    | Ok (e', _, sa), Hole _ ->
      Ok (Succ e', Nat(), sa)
    | Error msg, _ -> Error msg
    | _, _ -> 
      Error (sl, "Type mismatch when checking that the term succ " ^ Pretty.print e ^ " of type nat has type " ^ Pretty.print ty)
    end

  | Ast.Natrec (e, e1, e2) ->
      let v1 = fresh_var (Natrec(e, e1, e2)) ty vars in
      let v2 = fresh_var (Id v1) (Id v1) (vars+1) in
      let elab = elaborate global ctx lvl sl (Ast.Nat()) ph (vars+2) e in
      begin match elab with
      | Ok (e', _, sa) ->  
        begin match ty with
        | Hole (n, l) ->
          let elab1 = elaborate global ctx lvl sl (Hole (n, l)) ph (vars+1) e1 in
          begin match elab1 with
          | Ok (e1', ty0, sa1) ->
            let h1 = Placeholder.generate (App(ty,ty0)) ph [] in
            let ty' = hfullsubst (Zero()) h1 ty0 in
            let tys = Pi(v1, h1, Ast.Pi(v2, ty', ty')) in
            let elab2 = elaborate global ctx lvl sl tys ph (vars+1) e2 in (* call elab with ty0' *)
            begin match elab2 with
            | Ok (e2', Ast.Pi(_, nat, Ast.Pi(_, _, _)), sa2) ->
              let u = unify global ctx lvl sl ph vars (Nat(), nat, Type (Num 0)) false in
              begin match u with
              | Ok _ ->
                Ok (Natrec(e', e1', e2'), ty', Stack.lappend sa sa1 sa2)
              | Error (_, msg) ->
                Error (Stack.lappend sa sa1 sa2, 
                  "Don't know how to unify\n  " ^ Pretty.print nat ^ "\nwith\n  nat\n" ^ msg)
              end
            | Ok (e2', ty', sa2) -> 
              Error (Stack.lappend sa sa1 sa2, 
                "The term\n  " ^ Pretty.print e2' ^ "\nhas type\n  " ^ Pretty.print ty' ^ 
                "\nbut is expected to have type\n  Π (v? : nat) ?0? → ?1?")  
            | Error msg -> 
              Error msg
            end
          
          | Error msg -> 
            Error msg
          end
        
        | _ -> 
          let elab1 = elaborate global ctx lvl sl (eval (fullsubst e (Ast.Zero()) ty)) ph (vars+2) e1 in
          let tyx = (Pi(v1, Nat(), Pi(v2, fullsubst e (Id v1) ty, fullsubst e (Succ (Id v1)) ty))) in
          let elab2 = elaborate global ctx lvl sl tyx ph (vars+2) e2 in
          begin match elab1, elab2 with
          | Ok (e1', _, sa1), Ok (e2', _, sa2) ->
            Ok (Natrec (e', e1', e2'), ty, Stack.lappend sa sa1 sa2)
          | Error msg, _| _, Error msg -> 
            Error msg
          end
        end
    | Error msg -> 
      Error msg
    end

  | Ast.True() ->
    begin match ty with
    | Ast.Bool() -> 
      Ok (True(), Bool(), sl)
    | Hole _ -> 
      Ok (True(), Bool(), sl) 
    | _ -> 
      Error (sl, "Type mismatch when checking that the term true of type bool has type " ^ Pretty.print ty)
    end
  
    | Ast.False() ->
    begin match ty with
    | Ast.Bool() -> 
      Ok (False(), Bool(), sl)
    | Hole _ -> 
      Ok (False(), Bool(), sl)
    | _ -> 
      Error (sl, "Type mismatch when checking that the term false of type bool has type " ^ Pretty.print ty)
    end
    
  | Ast.If (e, e1, e2) ->
    let elab = elaborate global ctx lvl sl (Ast.Bool()) ph vars e in
    let elab1 = elaborate global ctx lvl sl (fullsubst e (Ast.True()) ty) ph vars e1 in
    let elab2 = elaborate global ctx lvl sl (fullsubst e (Ast.False()) ty) ph vars e2 in
    begin match elab, elab1, elab2 with
    | Ok (e', _, sa), Ok (e1', ty1', sa1), Ok (e2', ty2', sa2) ->
      begin match ty with
      | Hole _ ->
        let h1 = Placeholder.generate ty 0 [] in
        let tyt = hfullsubst (Ast.True()) h1 ty1' in
        let tyf = hfullsubst (Ast.False()) h1 ty2' in
        begin
          match tyt, tyf with
          | Type n, Type m ->
            if Universe.leq (m, n) then
              Ok (If(e', e1', e2'), Type n, Stack.lappend sa sa1 sa2)
            else
            Ok (If(e', e1', e2'), Type m, Stack.lappend sa sa1 sa2)
          | _ ->
            let elabTy = elaborate global ctx lvl sl h1 ph vars ty in
            begin match elabTy with
            | Ok (_, tTy, _) ->
              let u = unify global ctx lvl sl ph vars (tyt, tyf, tTy) false in
              begin match u with 
              | Ok sty ->
                let tyt' = fullsubst h1 (Ast.True()) sty in
                let tyf' = fullsubst h1 (Ast.False()) sty in
                let elabt = elaborate global ctx lvl sl tyt' ph vars e1' in
                let elabf = elaborate global ctx lvl sl tyf' ph vars e2' in
                begin match elabt, elabf with
                | Ok _, Ok _ ->
                  Ok (If (e', e1', e2'), fullsubst h1 e' sty, Stack.lappend sa sa1 sa2)
                | _ -> 
                  Error (Stack.lappend sa sa1 sa2, 
                  "Failed to unify the types\n  " ^ Pretty.print (fullsubst (Ast.True()) h1 ty1') ^ 
                  "\nand\n  " ^ Pretty.print (fullsubst (Ast.False()) h1 ty2'))
                end
              | _ ->
                let tyt' = fullsubst (Ast.False()) h1 ty1' in
                let tyf' = fullsubst (Ast.True()) h1 ty2' in
                let elabt = elaborate global ctx lvl sl tyf' ph vars e1' in
                let elabf = elaborate global ctx lvl sl tyt' ph vars e2' in
                begin match elabt, elabf with
                | Ok (_, _, sa'), _ | _, Ok (_, _, sa') -> 
                  Ok (If (e', e1', e2'), ty, Stack.append sa' (Stack.lappend sa sa1 sa2))
                | _ ->
                  Error (Stack.lappend sa sa1 sa2, 
                    "Failed to unify the types\n  " ^ Pretty.print (fullsubst (Ast.True()) h1 ty1') ^ 
                    "\nand\n  " ^ Pretty.print (fullsubst (Ast.False()) h1 ty2'))
                end
              end
            | Error msg -> (* This case is impossible *)
              Error msg
            end
        end

      | _ ->
        Ok (If (e', e1', e2'), ty, Stack.lappend sa sa1 sa2)
      end
    | Error msg, _, _| _, Error msg, _ | _, _, Error msg -> 
      Error msg
    end

  | Ast.Star() -> 
    begin match ty with
    | Ast.Unit() -> 
      Ok (Star(), Unit(), sl)
    | Hole _ -> 
      Ok (Star(), Unit(), sl)
    | _ -> 
      Error (sl, "Type mismatch when checking that the term () of type unit has type " ^ Pretty.print ty)
    end
  
  | Ast.Let (e1, e2) ->
    let elab1 = elaborate global ctx lvl sl (Ast.Unit()) ph vars e1 in
    begin match elab1 with
    | Ok (e1', _, sa1) ->
      begin match ty with
      | Hole (n, l) ->
        let elab2 = elaborate global ctx lvl sl (Hole (n, l)) ph vars e2 in
        begin match elab2 with
        | Ok (e2', ty2, sa2) ->
          let h1 = Placeholder.generate ty 0 [e1; e1'; Ast.Star()] in
          let ty' = hfullsubst (Ast.Star()) h1 ty2 in
          Ok (Let (e1', e2'), ty', Stack.append sa1 sa2)
        | Error msg ->
          Error msg
        end
      | _ ->
        let elab2 = elaborate global ctx lvl sl (fullsubst e1 (Ast.Star()) ty) ph vars e2 in
        begin match elab2 with
        | Ok (e2', _, sa2) ->
          Ok (Let (e1', e2'), ty, Stack.append sa1 sa2)
        | Error msg -> Error msg
        end
      end
    | Error msg -> Error msg
    end
  
  | Ast.Abort e ->
    let elab = elaborate global ctx lvl sl (Ast.Void()) ph vars e in
    begin
      match elab with
      | Ok (e', _, sa) ->
        Ok (Abort e', ty, sa)
      | Error msg -> Error msg
    end
  
  | Ast.Coe(i, j, ety, e) ->
    begin
      let h0 = Placeholder.generate ty 0 [] in
      let elabi = elaborate global ctx lvl sl (Int()) ph vars i in
      let elabj = elaborate global ctx lvl sl (Int()) ph vars j in
      let elabti = elaborate global ctx lvl sl h0 ph vars (eval (App(ety, i))) in
      let elabtj = elaborate global ctx lvl sl h0 ph vars (eval (App(ety, j))) in
      begin
        match elabi, elabj, elabti, elabtj with
        | Ok (i', _, _), Ok (j', _, _), Ok (tyi, eTy, sat), Ok (tyj, _, _) ->
          let elab = elaborate global ctx lvl sl (eval tyi) ph vars e in
          let elabt = elaborate global ctx lvl sl h0 ph vars ty in
          begin
            match elab, elabt with
            | Ok (e', _, sa), Ok (ty', _, sat') ->
              let u = unify global ctx lvl sl ph vars (eval tyj, ty', eTy) false in
              begin match u with
              | Ok tty ->
                Ok (Coe (i', j', eval ety, e'), tty, Stack.lappend sa sat sat')
              | Error (_, msg) -> 
                Error (Stack.lappend sa sat sat', 
                  "Failed to unify the terms\n  " ^ Pretty.print tyj ^ "\nand\n  " ^ Pretty.print ty' ^ 
                  "\nwhen checking that the coercion\n  " ^ Pretty.print (Coe(i, j, ety, e)) ^ (* Improve error msg *)
                  "\nhas type\n  " ^ Pretty.print (eval ty) ^
                  "\n" ^ msg)
              end
            | Error (sa, msg), _ ->
              Error (sa, "The coercion failed because\n  " ^ Pretty.print e ^ "\ndoes not have type\n  " ^ Pretty.print tyi ^ "\n" ^ msg)
            | _, Error msg ->
              Error msg
          end

        | Error msg, _, _, _ | _, Error msg, _, _ 
        | _, _, Error msg, _ | _, _, _, Error msg ->
          Error msg
      end
    end
  
  | Ast.Hfill(e, e1, e2) ->
    begin
      match ty with
      | Ast.Pi(i, int, Pi(j, int', ty')) ->
        if eval int = Int() && eval int = eval int' then
          begin
            let elab = elaborate global ctx lvl sl (Pi(j, Int(), ty')) ph vars e in
            let elab1 = elaborate global ctx lvl sl (Pi(j, Int(), ty')) ph vars e1 in
            let elab2 = elaborate global ctx lvl sl (Pi(j, Int(), ty')) ph vars e2 in
            match elab, elab1, elab2 with
            | Ok (e', ety, sa), Ok (e1', e1ty, sa1), Ok (e2', e2ty, sa2) ->
              begin
                let jty = Pi(j, Int(), ty') in
                let elabi0 = elaborate global ctx lvl sl jty ph vars (Abs("v?", eval (App(e', I0())))) in
                let elabi1 = elaborate global ctx lvl sl jty ph vars (Abs("v?", eval (App(e', I1())))) in
                let elab1i0 = elaborate global ctx lvl sl jty ph vars (Abs("v?", eval (App(e1', I0())))) in
                let elab2i0 = elaborate global ctx lvl sl jty ph vars (Abs("v?", eval (App(e2', I0())))) in
                begin
                  match elabi0, elabi1, elab1i0, elab2i0 with
                  | Ok (ei0, _, _), Ok (ei1, _, _), Ok (e1i0, _, _), Ok (e2i0, _, _) ->
                    begin
                      let elab1i1 = elaborate global ctx lvl sl jty ph vars (Abs("v?", eval (App(e1, I1())))) in
                      let elab2i1 = elaborate global ctx lvl sl jty ph vars (Abs("v?", eval (App(e2, I1())))) in
                      match elab1i1, elab2i1 with
                      | Ok _, Ok _ ->

                          let u1 = unify global ctx lvl sl ph vars (eval ei0, e1i0, jty) false in
                          let u2 = unify global ctx lvl sl ph vars (eval ei1, e2i0, jty) false in
                          begin
                            match u1, u2 with
                            | Ok _, Ok _ ->
                              let return x = Ok (Hfill(e', e1', e2'), x, Stack.lappend sa sa1 sa2) in
                              if not (Placeholder.has_placeholder ty) then
                                return ty
                              else if not (Placeholder.has_placeholder ety) then
                                return (Pi (i, Int(), ety))
                              else if not (Placeholder.has_placeholder e1ty) then
                                return (Pi (i, Int(), e1ty))
                              else if not (Placeholder.has_placeholder e2ty) then
                                return (Pi (i, Int(), e2ty))
                              else
                                return ty
                            | Error (_, msg), _ ->
                              Error (Stack.lappend sa sa1 sa2,
                                "Error when unifying the terms\n  " ^ 
                                Pretty.print (eval ei0) ^ "\nand\n  " ^ Pretty.print (eval e1i0) ^
                                "\n" ^ msg)
                            | _, Error (_, msg) -> 
                              Error (Stack.lappend sa sa1 sa2, 
                                "Error when unifying the terms\n  " ^ 
                                Pretty.print (eval ei1) ^ "\nand\n  " ^ Pretty.print (eval e2i0) ^
                                "\n" ^ msg)
                          end
                          
                      | Error (sa', msg), _ | _, Error (sa', msg) -> 
                        Error (Stack.append sa' (Stack.lappend sa sa1 sa2), msg)
                    end
                    
                  | Error (sa', msg), _, _, _ ->
                    Error (Stack.append sa' (Stack.lappend sa sa1 sa2), 
                    "Error when checking that the homogeneous filling\n  " ^ Pretty.print (Hfill(e', e1', e2')) ^ 
                    "\nhas type\n  I → I → " ^ Pretty.print ty' ^ 
                    "\nThe i0-face of the lid\n  " ^ Pretty.print (eval (App(e', I0()))) ^ "\ndoes not have the expected type\n  " ^ Pretty.print ty' ^ 
                    "\n" ^ msg)
                  | _, Error (sa', msg), _, _ ->
                    Error (Stack.append sa' (Stack.lappend sa sa1 sa2), 
                    "Error when checking that the homogeneous filling\n  " ^ Pretty.print (Hfill(e', e1', e2')) ^ 
                    "\nhas type\n  I → I → " ^ Pretty.print ty' ^ 
                    "\nThe i1-face of the lid\n  " ^ Pretty.print (eval (App(e', I1()))) ^ "\ndoes not have the expected type\n  " ^ Pretty.print ty' ^ 
                    "\n" ^ msg)
                  | _, _, Error (sa', msg), _ ->
                    Error (Stack.append sa' (Stack.lappend sa sa1 sa2), 
                    "Error when checking that the homogeneous filling\n  " ^ Pretty.print (Hfill(e', e1', e2')) ^ 
                    "\nhas type\n  I → I → " ^ Pretty.print ty' ^ 
                    "\nThe i0-face of the i0-tube\n  " ^ Pretty.print (eval (App(e1', I0()))) ^ "\ndoes not have the expected type\n  " ^ Pretty.print ty' ^ 
                    "\n" ^ msg)
                  | _, _, _, Error (sa', msg) ->
                    Error (Stack.append sa' (Stack.lappend sa sa1 sa2), 
                    "Error when checking that the homogeneous filling\n  " ^ Pretty.print (Hfill(e, e1, e2)) ^ 
                    "\nhas type\n  I → I → " ^ Pretty.print ty' ^ 
                    "\nThe i0-face of the i1-tube\n  " ^ Pretty.print (eval (App(e2', I0()))) ^ "\ndoes not have the expected type\n  " ^ Pretty.print ty' ^ 
                    "\n" ^ msg)
                end

              end
          | Error (sa, msg), _, _ | _, Error (sa, msg), _ | _, _, Error (sa, msg) -> 
            Error (sa, msg)
          end
        else
          Error (sl, "The homogeneous filling\n  " ^ Pretty.print (Hfill(e, e1, e2)) ^ 
            "\nhas type\n  " ^ Pretty.print int ^ "→  " ^ Pretty.print int' ^ "→ " ^ Pretty.print ty' ^
            "\nbut is expected to have type\n  I → I → ?0?")
      
      | Hole (_, _) | Pi(_, _, Hole (_, _)) -> 
        let h0 = Placeholder.generate ty 0 [] in
        let elabi0 = elaborate global ctx lvl sl h0 ph vars (eval (Ast.App(e, Ast.I0()))) in
        begin
          let elab = elaborate global ctx lvl sl (Pi("v1", Int(), h0)) ph vars e in
          let elab1 = elaborate global ctx lvl sl (Pi("v1", Int(), h0)) ph vars e1 in
          let elab2 = elaborate global ctx lvl sl (Pi("v1", Int(), h0)) ph vars e2 in
          match elab, elab1, elab2 with
          | Ok (e', _, _), Ok (e1', _, _), Ok (e2', _, _) ->
            begin
              match elabi0 with
              | Ok (ei0, ty', sa) ->
                let elabi1 = elaborate global ctx lvl sl ty' ph vars (eval (Ast.App(e', Ast.I1()))) in
                let elab1i0 = elaborate global ctx lvl sl ty' ph vars (eval (Ast.App(e1', Ast.I0()))) in
                let elab2i1 = elaborate global ctx lvl sl ty' ph vars (eval (Ast.App(e2', Ast.I0()))) in
                begin
                  match elabi1, elab1i0, elab2i1 with
                  | Ok (ei1, _, _), Ok (e1i0, _, sa1), Ok (e2i0, _, sa2) ->
                    begin
                      let u1 = unify global ctx lvl sl ph vars (eval ei0, e1i0, ty') false in
                      let u2 = unify global ctx lvl sl ph vars (eval ei1, e2i0, ty') false in
                      begin 
                        match u1, u2 with
                        | Ok _, Ok _ ->
                          Ok (Hfill(e', e1', e2'), Ast.Pi("v?", Int(), Pi("v?", Int(), ty')), Stack.lappend sa sa1 sa2)
                        | Error (_, msg), _ | _, Error (_, msg) -> 
                          Error (Stack.lappend sa sa1 sa2, "Failed composition, endpoints do not match:\n" ^ msg)
                      end
                    end

                  | Error (sa', msg), _, _ ->
                    Error (Stack.append sa sa', 
                      "Error when checking that the line\n  " ^ Pretty.print (eval (Ast.App(e', Ast.I1()))) ^ "\nhas type\n  " ^ Pretty.print ty' ^ 
                      "\nin the homogeneous filling\n  hfill (" ^ Pretty.print e' ^ 
                      ")\n    | i0 → " ^ Pretty.print e1' ^
                      "\n    | i1 → " ^ Pretty.print e2' ^ "\n" ^ msg)
                  | _, Error (sa, msg), _ | _, _, Error (sa, msg) ->
                    Error (sa, "Failed composition: " ^ msg)
                end
              | Error msg -> Error msg
            end
        | Error msg, _, _ | _, Error msg, _ | _, _, Error msg -> 
          Error msg
        end
      | ty ->
        Error (sl, "The homogeneous filling\n  " ^ Pretty.print (Hfill(e, e1, e2)) ^ 
        "\nis expected to have type\n  I → I → ?0?\nand not\n  " ^ Pretty.print ty)
      end
  
  | Pabs (i, e) ->
    let h0 = Placeholder.generate ty 0 [] in
    let elabt = elaborate global ctx lvl sl h0 ph vars (eval ty) in
    begin match elabt with
    | Ok (Pathd (Hole (n, l), e1, e2), _, _) ->
      let h0 = Placeholder.generate ty 0 [] in
      let sl' = (fst sl, Stack.allconcat i (Int()) (snd sl)) in
      let elab = elaborate global ((i, Int(), true) :: ctx) lvl sl' (Hole (n, l)) ph vars e in

      begin match elab with
      | Ok (e', _, sa) ->
        let elab1 = elaborate global ((i, Int(), true) :: ctx) lvl sl' h0 ph vars (subst i (I0()) e') in
        let elab2 = elaborate global ((i, Int(), true) :: ctx) lvl sl' h0 ph vars (subst i (I1()) e') in
        begin match elab1, elab2 with
        | Ok (ei0, tyi0, _), Ok (ei1, tyi1, _) ->
        
          let u1 = unify global ctx lvl sl ph vars (eval ei0, eval e1, tyi0) false in
          let u2 = unify global ctx lvl sl ph vars (eval ei1, eval e2, tyi1) false in
          begin match u1, u2 with
          | Ok ui0, Ok ui1 ->
            let v1 = fresh_var (App(tyi0, tyi1)) ty vars in
            let ty' = fullsubst (I0()) (Id v1) tyi0 in
            let ty'' = fullsubst (I1()) (Id v1) tyi1 in
            let elabTy = elaborate global ctx lvl sl h0 ph vars ty in

            begin match elabTy with
            | Ok (_, tTy, _) ->
              let u = unify global ctx lvl sl ph vars (ty', ty'', tTy) false in
              begin match u with
              | Ok st ->
                Ok (Pabs (i, e'), Pathd (Abs(v1,st), ui0, ui1), sa)
              | Error (_, msg) -> Error (sa, msg)
              end

            | Error (sa', msg) -> (* This case is impossible *)
              Error (Stack.append sa sa', msg)
            end
          | _ , Ok _ ->
            Error (sa, "Failed to unify\n  " ^
                    Pretty.print e1 ^ "\nwith\n  " ^ Pretty.print ei0 ^ "≡ " ^ Pretty.print e ^ "[i0/" ^ i ^ "]" ^ "\n" ^
                    goal_msg ctx (Pabs (i, e')) ty) 
          | _ ->
            Error (sa, "Failed to unify\n  " ^ 
                    Pretty.print e2 ^ "\nwith\n  " ^ Pretty.print ei1 ^ "≡ " ^ Pretty.print e ^ "[i1/" ^ i ^ "]" ^ "\n" ^
                    goal_msg ctx (Pabs (i, e')) ty)
          end
        | Error (_, msg), _| _, Error (_, msg) -> 
          Error (sa, msg)
        end
      | Error (sa, msg) -> 
        Error (sa, msg)
      end
    | Ok (Pathd (ty1, e1, e2), _, _) ->
      let elab = 
        elaborate global ((i, Int(), true) :: ctx) lvl 
        (fst sl, Stack.allconcat i (Int()) (snd sl)) 
        (eval (App(ty1, Id i))) ph vars e
      in
      begin match elab with
      | Ok (e', _, saa) ->
        let elab1 = elaborate global ctx lvl sl (eval (App(ty1, I0()))) ph vars (eval (subst i (I0()) e')) in
        let elab2 = elaborate global ctx lvl sl (eval (App(ty1, I1()))) ph vars (eval (subst i (I1()) e')) in
        begin match elab1, elab2 with
        | Ok (ei0, tyi0, _), Ok (ei1, tyi1, _) ->
          let u1 = unify global ctx lvl sl ph vars (eval ei0, eval e1, tyi0) false in
          let u2 = unify global ctx lvl sl ph vars (eval ei1, eval e2, tyi1) false in
          begin match u1, u2 with
          | Ok ui0, Ok ui1 -> 
            Ok (Pabs (i, e'), Pathd (ty1, ui0, ui1), saa)
          | Error ((s,s'), msg) , Ok _ ->
            begin match s, s' with
            | At(s',I0()), s | s, At(s',I0()) ->
              let h1 = Placeholder.generate ty 0 [] in
              let elab0 = elaborate global ctx lvl sl h1 ph vars s' in
              begin match elab0 with
              | Ok (_, Pathd(sty, sa, _), _) ->
                let u = unify global ctx lvl sl ph vars (s, sa, eval (App(sty, I0()))) false in
                begin match u with
                | Ok _ ->
                  Ok (Pabs (i, e'), Pathd (ty1, ei0, ei1), saa)
                | Error (_, msg) ->
                  Error (saa, "Failed to unify\n  " ^ 
                  Pretty.print e1 ^ "\nwith\n  " ^ Pretty.print ei0 ^ "≡ " ^ Pretty.print e' ^ "[i0/" ^ i ^ "]" ^ "\n" ^
                  msg ^ "\n" ^ goal_msg ctx (Pabs (i, e')) ty )
                end
              | _ -> 
                Error (saa, "Failed to unify\n  " ^ 
                        Pretty.print e1 ^ "\nwith\n  " ^ Pretty.print ei0 ^ "≡ " ^ Pretty.print e' ^ "[i0/" ^ i ^ "]" ^ "\n" ^
                        msg ^ "\n" ^ goal_msg ctx (Pabs (i, e')) ty)
              end
            | _ ->
              Error (saa, "Failed to unify\n  " ^ 
                    Pretty.print e1 ^ "\nwith\n  " ^ Pretty.print ei0 ^ "≡ " ^ Pretty.print e' ^ "[i0/" ^ i ^ "]" ^ "\n" ^
                    msg ^ "\n" ^ goal_msg ctx (Pabs (i, e')) ty)
            end
          | _ , Error ((s,s'), msg) ->
            begin match s, s' with
            | At(s',I1()), s | s, At(s',I1()) ->
              let h1 = Placeholder.generate ty 0 [] in
              let elab0 = elaborate global ctx lvl sl h1 ph vars s' in
              begin match elab0 with
              | Ok (_, Pathd(sty,_,sb), _) ->
                let u = unify global ctx lvl sl ph vars (s, sb, eval (App(sty, I1()))) false in
                begin match u with
                | Ok _ -> 
                  Ok (Pabs (i, e'), Pathd (ty1, ei0, ei1), saa)
                | Error (_, msg) ->
                  Error (saa, "Failed to unify\n  " ^ 
                    Pretty.print e2 ^ "\nwith\n  " ^ Pretty.print ei1 ^ "≡ " ^ Pretty.print e' ^ "[i1/" ^ i ^ "]" ^ "\n" ^
                    msg ^ "\n" ^ goal_msg ctx (Pabs (i, e')) ty )
                end

              | _ -> 
                Error (saa, "Failed to unify\n  " ^ 
                        Pretty.print e2 ^ "\nwith\n  " ^ Pretty.print ei1 ^ "≡ " ^ Pretty.print e' ^ "[i1/" ^ i ^ "]" ^ "\n" ^
                        msg ^ "\n" ^ goal_msg ctx (Pabs (i, e')) ty )
              end
            | _ ->
              Error (saa, "Failed to unify\n  " ^
                    Pretty.print e2 ^ "\nwith\n  " ^ Pretty.print ei1 ^ "≡ " ^ Pretty.print e' ^ "[i1/" ^ i ^ "]" ^ "\n" ^
                    msg ^ "\n" ^ goal_msg ctx (Pabs (i, e')) ty )
            end
          end

        | Error (_, msg), _ ->
          Error (saa, "Error when checking that the path abstracted term\n  " ^ 
            Pretty.print (Pabs(i, eval e)) ^ "\nhas type\n  " ^ Pretty.print ty ^ 
            "\nThe i0-endpoint\n  " ^ Pretty.print (eval (subst i (I0()) e')) ^ 
            "\ndoes not have type\n  " ^ Pretty.print (eval (App(ty1, I0()))) ^
            "\n" ^ msg)
        | _, Error (_, msg) -> 
          Error (saa, "Error when checking that the path abstracted term\n  " ^ 
            Pretty.print (Pabs(i, eval e)) ^ "\nhas type\n  " ^ Pretty.print ty ^ 
            "\nThe i1-endpoint\n  " ^ Pretty.print (eval (subst i (I1()) e')) ^ 
            "\ndoes not have type\n  " ^ Pretty.print (eval (App(ty1, I1()))) ^ 
            "\n" ^ msg)
        end
      | Error (sa, msg) -> 
        Error (sa, "Error when checking that the path abstracted term\n  " ^ 
          Pretty.print (Pabs(i, eval e)) ^ "\nhas type\n  " ^ Pretty.print ty ^ "\n" ^ msg)
      end
    | Ok (Hole _, _, _) ->
      let h1 = Placeholder.generate ty 0 [] in
      let ei0 = subst i (I0()) e in
      let ei1 = subst i (I1()) e in
      begin 
        let elab0 = elaborate global ctx lvl sl h1 (ph+1) vars ei0 in
        let elab1 = elaborate global ctx lvl sl h1 (ph+1) vars ei1 in
        match elab0, elab1 with
        | Ok (_, tyi0, _), Ok (_, tyi1, _) ->
          let v1 = fresh_var (App(tyi0, tyi1)) ty vars in
          let ty' = fullsubst (I0()) (Id v1) tyi0 in
          let ty'' = fullsubst (I1()) (Id v1) tyi1 in
          begin 
            match elaborate global ctx lvl sl h1 (ph+1) vars ty' with
            | Ok (ty', tTy', _) ->
              let u = unify global ctx lvl sl ph vars (ty', ty'', tTy') false in
              begin match u with
              | Ok st ->
                elaborate global ctx lvl sl (Pathd(Abs(v1,st), ei0, ei1)) (ph+1) vars (Pabs (i, e))
              | Error (_, msg) ->
                Error (sl, "Failed to unify the types\n  " ^ Pretty.print ty' ^ "\nand\n  " ^ Pretty.print ty'' ^ "\n" ^ msg)
                
              end
            | Error msg -> (* This case never occurs *)
              Error msg
          end
        | Error msg, _ | _, Error msg -> Error msg
      end
    | Ok (ty', _, sa) -> 
      Error (sa, "The expression\n  <" ^ i ^ "> " ^ Pretty.print e ^ "\nis expected to have type\n  pathd ?0? ?1? ?2?\nbut has type\n  " ^ Pretty.print ty')
    | Error (sa, msg) -> 
      Error (sa, "Failed to prove that\n  " ^ Pretty.print (eval ty) ^ "\nis a type\n" ^ msg)
    end
  
  | At (e1, e2) ->
    let h1 = Placeholder.generate ty 0 [] in
    let h2 = Placeholder.generate ty 1 [] in
    let h3 = Placeholder.generate ty 2 [] in
    let elab1 = elaborate global ctx lvl sl (Pathd(h1, h2, h3)) (ph+3) vars e1 in
    let elab2 = elaborate global ctx lvl sl (Int()) ph vars e2 in
    begin match elab1, elab2 with
    | Ok (e1', ty1', sa1), Ok (e2', _, sa2) ->
      begin match ty1' with
      | Pathd (ty', a, b) ->
        if eval e2' = I0() then
          match a, ty' with
          | Hole _, Abs(v, ty') -> (* unify ty' and ty*)
            Ok (At (e1', I0()), subst v (I0()) ty', Stack.append sa1 sa2)
          | Hole _, Hole _ -> 
            Ok (At (e1', I0()), ty, Stack.append sa1 sa2)
          | Hole _, ty' -> 
            Ok (At (e1', I0()), App(ty', I0()), Stack.append sa1 sa2)
          | _ -> 
            elaborate global ctx lvl sl ty ph vars a
        else if eval e2' = I1() then
          match b, ty' with
          | Hole _, Abs(v, ty') -> 
            Ok (At (e1', I1()), subst v (I1()) ty', Stack.append sa1 sa2)
          | Hole _, Hole _ -> 
            Ok (At (e1', I1()), ty, Stack.append sa1 sa2)
          | Hole _, ty' -> 
            Ok (At (e1', I1()), App(ty', I1()), Stack.append sa1 sa2)
          | _ -> 
            elaborate global ctx lvl sl ty ph vars b
        else
          begin match ty' with
          | Abs(i, ty') ->
            let ty2' = subst i e2 ty' in
            let elabTy = elaborate global ctx lvl sl h1 ph vars ty2' in
            begin
              match elabTy with
              | Ok (_, tTy, _) ->
                let u = unify global ctx lvl sl ph vars (ty2', ty, tTy) false in
                begin
                  match u with
                  | Ok tty -> Ok (At (e1', e2'), tty, Stack.append sa1 sa2)
                  | _ -> 
                    Error (Stack.append sa1 sa2, 
                      "Failed to unify\n  " ^ 
                      Pretty.print ty2' ^ "\nwith\n  " ^ Pretty.print ty)
                end
              | Error msg -> (* This case is impossible *)
                Error msg
            end
            
          | _ -> 
            begin match ty with
            | App(ty, i) ->
              let elabTy = elaborate global ctx lvl sl h1 ph vars ty' in
              begin
                match elabTy with
                | Ok (_, tTy, _) ->
                  let u = unify global ctx lvl sl ph vars (ty', ty, tTy) false in
                  begin 
                    match u, e2 = i with 
                    | Ok tty, true -> 
                      Ok (At (e1', e2'), App(tty, i), Stack.append sa1 sa2)
                    | _ -> 
                      Error (Stack.append sa1 sa2, 
                        "Failed to unify\n  " ^ 
                        Pretty.print ty' ^ "\nwith\n  " ^ Pretty.print ty)
                  end
                | Error msg -> (* This case is impossible *)
                  Error msg
              end
            | ty ->
              let elabTy = elaborate global ctx lvl sl h1 ph vars ty' in
              begin
                match elabTy with
                | Ok (_, tTy, _) ->
                  let u = unify global ctx lvl sl ph vars (ty', ty, tTy) false in
                  begin
                    match u with
                    | Ok tty -> 
                      Ok (At (e1', e2'), tty, Stack.append sa1 sa2) 
                    | _ -> 
                      Error (Stack.append sa1 sa2, "Failed to unify\n  " ^ 
                      Pretty.print ty' ^ "\nwith\n  " ^ Pretty.print ty)
                  end
              | Error msg -> (* This case is impossible *)
                Error msg
            end
            end
          end
      | _ -> 
        Error (Stack.append sa1 sa2, 
          "Type mismatch when checking that\n  " ^ Pretty.print e1' ^ 
          "\nof type\n  " ^ Pretty.print ty1' ^ "\nhas type\n  pathd ?0? ?1? ?2? ")
      end
    | Error msg, _ | _, Error msg -> 
      Error msg
    end

  | Pi(x, ty1, ty2) ->
    let h1 = Placeholder.generate ty 0 [] in
    let elab1 = elaborate global ctx lvl sl h1 (ph+1) vars ty1 in
    let elab2 = 
      elaborate global ((x, ty1, true) :: ctx) lvl 
      (fst sl, Stack.allconcat x ty1 (snd sl)) h1 (ph+1) vars ty2 
    in
    begin match elab1, elab2 with
    | Ok (ty1', Type n1, sa1), Ok (ty2', Type n2, sa2) -> 
      begin match ty with
      | Type m -> 
        if Universe.leq (n1, m) && Universe.leq (n2, m) then 
          Ok (Pi(x, ty1', ty2'), Type m, Stack.append sa1 sa2) 
        else 
          Error (Stack.append sa1 sa2, 
            "Type mismatch when checking that \n  Π ( " ^ x ^ " : " ^ Pretty.print ty1 ^ ") " ^ Pretty.print ty2 ^ 
            "\nof type \n  " ^ Pretty.print (eval (Type (Max (n1, n2)))) ^ "\nhas type\n  " ^ Pretty.print (Type m))
      | Hole _ -> 
        Ok (Pi(x, ty1', ty2'), Type (Universe.eval (Max(n1, n2))), Stack.append sa1 sa2)
      | _ ->
        Error (Stack.append sa1 sa2, 
          "Type mismatch when checking that\n  Π ( " ^ x ^ " : " ^ 
          Pretty.print ty1 ^ ") " ^ Pretty.print ty2 ^ "\nhas type\n  " ^ Pretty.print ty)
      end

    | Ok (ty1', Type n, sa), Ok (Hole (k,l), _, _) -> 
      begin match ty with
      | Type m -> 
        if Universe.leq (n, m) then 
          Ok (Pi(x, ty1', Hole (k,l)), Type m, sa) 
        else 
          Error (sa, "Type mismatch when checking that \n  Π ( " ^ x ^ " : " ^ Pretty.print ty1 ^ ") " ^ Pretty.print ty2 ^ 
            "\nof type \n  " ^ Pretty.print (Type n) ^ "\nhas type\n  " ^ Pretty.print (Type m))
      | Hole _ -> 
        Ok (Pi(x, ty1', Hole (k,l)), Type n, sa) (* TODO: hole might have live in a higher universe *)
      | _ ->
        Error (sa, "Type mismatch when checking that\n  Π ( " ^ x ^ " : " ^ Pretty.print ty1 ^ ") " ^ Pretty.print ty2 ^ "\nhas type\n  " ^ Pretty.print ty)
      end
    | Ok (Hole (k,l), _, _), Ok (ty2', Type n, sa) -> 
      begin match ty with
      | Type m -> 
        if Universe.leq (n, m) then 
          Ok (Pi(x, Hole (k,l), ty2'), Type m, sa) 
        else 
          Error (sa, "Type mismatch when checking that \n  Π ( " ^ x ^ " : " ^ Pretty.print ty1 ^ ") " ^ Pretty.print ty2 ^ 
                "\nof type \n  " ^ Pretty.print (Type n) ^ "\n has type\n  " ^ Pretty.print (Type m))
      | Hole _ -> 
        Ok (Pi(x, Hole (k,l), ty2'), Type n, sa) (* TODO: hole might have live in a higher universe *)
      | _ ->
        Error (sa, "Type mismatch when checking that\n  Π ( " ^ x ^ " : " ^ Pretty.print ty1 ^ ") " ^ Pretty.print ty2 ^ "\nhas type\n  " ^ Pretty.print ty)
      end
    | Ok (Hole (k1,l1), _, _), Ok (Hole (k2,l2), _, _) ->
      begin match ty with
      | Type m -> 
          Ok (Pi(x, Hole (k1,l1), Hole (k2,l2)), Type m, sl) 
      | Hole (k, l) -> 
          Ok (Pi(x, Hole (k1,l1), Hole (k2,l2)), Hole(k, l), sl)
      | _ ->
        Error (sl, "Type mismatch when checking that\n  Π ( " ^ x ^ " : " ^ Pretty.print ty1 ^ ") " ^ Pretty.print ty2 ^ "\nhas type\n  " ^ Pretty.print ty)
      end
    
    | Ok (_, Type _, sa), Error (sb, msg) -> 
      Error (Stack.append sa sb, "Failed to check that\n  " ^ Pretty.print (eval ty2) ^ "\nis a type\n" ^ msg)
    | Error (sa, msg), _ -> 
      Error (sa, "Failed to check that\n  " ^ Pretty.print (eval ty1) ^ "\nis a type\n" ^ msg)
    | _ -> 
      Error (sl, "Failed to check that\n  " ^ Pretty.print (eval ty1) ^ "\nis a type")
    end
  
  | Sigma(x, ty1, ty2) ->
    let h1 = Placeholder.generate ty 0 [] in
    let elab1 = elaborate global ctx lvl sl h1 (ph+1) vars ty1 in
    let elab2 = 
      elaborate global ((x, ty1, true) :: ctx) lvl 
      (fst sl, Stack.allconcat x ty1 (snd sl)) h1 (ph+1) vars ty2 
    in
    begin match elab1, elab2 with
    | Ok (ty1', Type n1, sa1), Ok (ty2', Type n2, sa2) -> 
      begin match ty with
      | Type m -> 
        if Universe.leq (n1, m) && Universe.leq (n2, m) then 
          Ok (Sigma(x, ty1', ty2'), Type m, Stack.append sa1 sa2) 
        else 
          Error (Stack.append sa1 sa2, "Type mismatch when checking that \n  Σ ( " ^ x ^ " : " ^ Pretty.print ty1 ^ ") " ^ Pretty.print ty2 ^ 
            "\nof type \n  " ^ Pretty.print (eval (Type (Max(n1, n2)))) ^ "\n has type\n  " ^ Pretty.print (Type m))
      | Hole _ -> 
        Ok (Sigma(x, ty1', ty2'), Type (Universe.eval (Max(n1, n2))), Stack.append sa1 sa2)
      | _ ->
        Error (Stack.append sa1 sa2, "Type mismatch when checking that\n  Σ ( " ^ x ^ " : " ^ 
          Pretty.print ty1 ^ ") " ^ Pretty.print ty2 ^ "\nhas type\n  " ^ Pretty.print ty)
      end
    
    | Ok (ty1', Type n, sa), Ok (Hole (k,l), _, _) -> 
      begin match ty with
      | Type m -> 
        if Universe.leq (n, m) then 
          Ok (Sigma(x, ty1', Hole (k,l)), Type m, sa) 
        else 
          Error (sa, "Type mismatch when checking that \n  Σ ( " ^ x ^ " : " ^ Pretty.print ty1 ^ ") " ^ Pretty.print ty2 ^ 
                "\nof type \n  " ^ Pretty.print (Type n) ^ "\n has type\n  " ^ Pretty.print (Type m))
      | Hole _ -> 
        Ok (Sigma(x, ty1', Hole (k,l)), Type n, sa) (* TODO: hole might have live in a higher universe *)
      | _ ->
        Error (sa, "Type mismatch when checking that\n  Σ ( " ^ x ^ " : " ^ Pretty.print ty1 ^ ") " ^ Pretty.print ty2 ^ "\nhas type\n  " ^ Pretty.print ty)
      end
    | Ok (Hole (k,l), _, _), Ok (ty2', Type n, sa) -> 
      begin match ty with
      | Type m -> 
        if Universe.leq (n, m) then 
          Ok (Sigma(x, Hole (k,l), ty2'), Type m, sa) 
        else 
          Error (sa, "Type mismatch when checking that \n  Σ ( " ^ x ^ " : " ^ Pretty.print ty1 ^ ") " ^ Pretty.print ty2 ^ 
                "\nof type \n  type " ^ Pretty.print (Type n) ^ "))\n has type\n  " ^ Pretty.print (Type m))
      | Hole _ -> 
        Ok (Sigma(x, Hole (k,l), ty2'), Type n, sa) (* TODO: hole might have live in a higher universe *)
      | _ ->
        Error (sa, "Type mismatch when checking that\n  Σ ( " ^ x ^ " : " ^ Pretty.print ty1 ^ ") " ^ Pretty.print ty2 ^ "\nhas type\n  " ^ Pretty.print ty)
      end
    | Ok (Hole (k1,l1), _, _), Ok (Hole (k2,l2), _, _) ->
      begin match ty with
      | Type m -> 
          Ok (Sigma(x, Hole (k1,l1), Hole (k2,l2)), Type m, sl)
      | Hole (k, l) ->
          Ok (Sigma(x, Hole (k1,l1), Hole (k2,l2)), Hole(k, l), sl)
      | _ ->
        Error (sl, 
        "Type mismatch when checking that\n  Σ ( " ^ x ^ " : " ^ Pretty.print ty1 ^ ") " ^ Pretty.print ty2 ^ "\nhas type\n  " ^ Pretty.print ty)
      end
    | Ok (_, Type _, _), Error (sa, msg) -> 
      Error (sa, "Failed to check that\n  " ^ Pretty.print ty2 ^ "\nis a type\n" ^ msg)
    | _ -> Error (sl, "Failed to check that\n  " ^ Pretty.print ty1 ^ "\nis a type")
    end
  
  | Sum(ty1, ty2) ->
    let h1 = Placeholder.generate ty 0 [] in
    let elab1 = elaborate global ctx lvl sl h1 (ph+1) vars ty1 in
    let elab2 = elaborate global ctx lvl sl h1 (ph+1) vars ty2 in
    begin match elab1, elab2 with
    | Ok (ty1', Type n1, sa1), Ok (ty2', Type n2, sa2) -> 
      begin 
        match ty with
        | Type m -> 
          if Universe.leq (n1, m) && Universe.leq (n2, m) then 
            Ok (Sum(ty1', ty2'), Type m, Stack.append sa1 sa2) 
          else 
            Error (Stack.append sa1 sa2, "Type mismatch when checking that \n  " ^ Pretty.print ty1 ^ "+ " ^ Pretty.print ty2 ^ 
              "\nof type \n  " ^ Pretty.print (eval (Type (Max(n1, n2)))) ^ "\n has type\n  " ^ Pretty.print (Type m))
        | Hole _ -> 
          Ok (Sum(ty1', ty2'), Type (Universe.eval (Max(n1, n2))), Stack.append sa1 sa2)
        | _ ->
          Error (Stack.append sa1 sa2, "Type mismatch when checking that\n  " ^ 
            Pretty.print ty1 ^ "+ " ^ Pretty.print ty2 ^ "\nhas type\n  " ^ Pretty.print ty)
      end
    | Ok (ty1', Type n, sa), Ok (Hole (k,l), _, _) -> 
      begin match ty with
      | Type m -> 
        if Universe.leq (n, m) then 
          Ok (Sum(ty1', Hole (k,l)), Type m, sa) 
        else 
          Error (sa, "Type mismatch when checking that \n  " ^ Pretty.print ty1 ^ "+ " ^ Pretty.print ty2 ^ 
            "\nof type \n  " ^ Pretty.print (Type n) ^ "\nhas type\n  " ^ Pretty.print (Type m))
      | Hole _ -> 
        Ok (Sum(ty1', Hole (k,l)), Type n, sa) (* TODO: hole might have live in a higher universe *)
      | _ ->
        Error (sa, "Type mismatch when checking that\n  " ^ Pretty.print ty1 ^ "+ " ^ Pretty.print ty2 ^ "\nhas type\n  " ^ Pretty.print ty)
      end
    | Ok (Hole (k,l), _, _), Ok (ty2', Type n, sa) -> 
      begin match ty with
      | Type m -> 
        if Universe.leq (n, m) then 
          Ok (Sum(Hole (k,l), ty2'), Type m, sa) 
        else 
          Error (sa, "Type mismatch when checking that \n  " ^ Pretty.print ty1 ^ "+ " ^ Pretty.print ty2 ^ 
            "\nof type \n  " ^ Pretty.print (Type n) ^ "\nhas type\n  " ^ Pretty.print (Type m))
      | Hole _ -> 
        Ok (Sum(Hole (k,l), ty2'), Type n, sa) (* TODO: hole might have live in a higher universe *)
      | _ ->
        Error (sa, "Type mismatch when checking that\n  " ^ Pretty.print ty1 ^ "+ " ^ Pretty.print ty2 ^ "\nhas type\n  " ^ Pretty.print ty)
      end
    | Ok (Hole (k1, l1), _, _), Ok (Hole (k2, l2), _, _) ->
      begin match ty with
      | Type m -> 
          Ok (Sum(Hole (k1, l1), Hole (k2, l2)), Type m, sl) 
      | Hole (k, l) -> 
          Ok (Sum(Hole (k1, l1), Hole (k2, l2)), Hole(k, l), sl)
      | _ ->
        Error (sl, "Type mismatch when checking that\n  " ^ 
          Pretty.print ty1 ^ "+ " ^ Pretty.print ty2 ^ "\nhas type\n  " ^ Pretty.print ty)
      end
    | Ok (_, Type _, _), Error (sa, msg) -> 
      Error (sa, "Failed to check that\n  " ^ Pretty.print ty2 ^ "\nis type\n" ^ msg)
    | _ -> 
      Error (sl, "Failed to check that\n  " ^ Pretty.print ty1 ^ "\nis type")
    end
  
  | Int() ->
    begin 
      match ty with
      | Type m -> 
        Ok (Int(), Type m, sl)
      | Hole _ -> 
        Ok (Int(), Type (Num 0), sl)
      | _ -> 
        Error (sl, "Type mismatch when checking that\n  I\nhas type\n  " ^ Pretty.print ty)
    end

  | Nat() ->
    begin 
      match ty with
      | Type m -> 
        Ok (Nat(), Type m, sl)
      | Hole _ -> 
        Ok (Nat(), Type (Num 0), sl) 
      | _ -> 
        Error (sl, "Type mismatch when checking that\n  nat\nhas type\n  " ^ Pretty.print ty)
    end

  | Bool() ->
    begin 
      match ty with
      | Type m -> 
        Ok (Bool(), Type m, sl)
      | Hole _ -> 
        Ok (Bool(), Type (Num 0), sl) 
      | _ -> 
        Error (sl, "Type mismatch when checking that\n  bool\nhas type\n  " ^ Pretty.print ty)
    end

  | Unit() ->
    begin 
      match ty with
      | Type m -> 
        Ok (Unit(), Type m, sl)
      | Hole _ -> 
        Ok (Unit(), Type (Num 0), sl)
      | _ -> 
        Error (sl, "Type mismatch when checking that\n  unit\n has type\n  " ^ Pretty.print ty)
    end

  | Void() ->
    begin 
      match ty with
      | Type m -> Ok (Void(), Type m, sl)
      | Hole _ -> Ok (Void(), Type (Num 0), sl)
      | _ -> Error (sl, "Type mismatch when checking that\n  void\n has type\n  " ^ Pretty.print ty)
    end

  | Pathd(ty1, e1, e2) ->
    let h1 = Placeholder.generate (App(ty,Pathd(ty1, e1, e2))) 0 [] in
    begin match ty1 with
    | Hole (n,l) ->
      begin match e1, e2 with 
      | Hole (n1,l1), Hole (n2,l2) ->
          begin match ty with
          | Type m ->
            Ok (Pathd(Hole (n,l), Hole (n1,l1), Hole (n2,l2)), Type m, sl)
          | Hole (m,k) ->
            Ok (Pathd(Hole (n,l), Hole (n1,l1), Hole (n2,l2)), Hole (m,k), sl)
          | _ -> 
            Error (sl, "Failed to check that\n  " ^ Pretty.print ty ^ "\nis a type")
          end
      | _ ->
        let elab1 = elaborate global ctx lvl sl (Hole (n,l)) (ph+1) vars e1 in
        let elab2 = elaborate global ctx lvl sl (Hole (n,l)) (ph+1) vars e2 in
        begin match elab1, elab2 with
        | Ok (e1', tye1, sa1), Ok (e2', tye2, sa2) ->
          begin match ty with
          | Type m ->
            if eval tye1 = eval tye2 then
              Ok (Pathd(tye1, e1', e2'), Type m, Stack.append sa1 sa2)
            else
              Ok (Pathd(Hole (n,l), e1', e2'), Type m, Stack.append sa1 sa2)
          | Hole (m,k) ->
            if eval tye1 = eval tye2 then
              Ok (Pathd(eval tye1, e1', e2'), Hole (m,k), Stack.append sa1 sa2)
            else 
              Ok (Pathd(Hole (n,l), e1', e2'), Hole (m,k), Stack.append sa1 sa2)
          | _ -> 
            Error (Stack.append sa1 sa2, "Failed to check that\n  " ^ Pretty.print ty ^ "\nis a type")
          end
        | _ -> 
          Error (sl, "Failed to check that\n  " ^ Pretty.print e1 ^ "\nhas type\n ?0?")
        end
      end
    | Abs(x, Hole (n,l)) ->
      begin match e1, e2 with 
      | Hole (n1,l1), Hole (n2,l2) ->
          begin match ty with
          | Type m ->
            Ok (Pathd(Abs(x, Hole (n,l)), Hole (n1,l1), Hole (n2,l2)), Type m, sl)
          | Hole (m,k) ->
            Ok (Pathd(Abs(x, Hole (n,l)), Hole (n1,l1), Hole (n2,l2)), Hole (m,k), sl)
          | _ -> 
            Error (sl, "Failed to check that\n  " ^ Pretty.print ty ^ "\nis a type")
          end
      | _ ->
        let elab1 = elaborate global ctx lvl sl (Hole (n,l)) (ph+1) vars e1 in
        let elab2 = elaborate global ctx lvl sl (Hole (n,l)) (ph+1) vars e2 in
        begin match elab1, elab2 with
        | Ok (e1', _, sa1), Ok (e2', _, sa2) ->
          begin match ty with
          | Type m ->
            Ok (Pathd(Abs(x,Hole (n,l)), e1', e2'), Type m, Stack.append sa1 sa2)
          | Hole (m,k) ->
            Ok (Pathd(Abs(x,Hole (n,l)), e1', e2'), Hole (m,k), Stack.append sa1 sa2)
          | _ -> 
            Error (Stack.append sa1 sa2, "Failed to check that\n  " ^ Pretty.print ty ^ "\nis a type")
            end
        | Ok _, Error (sa, msg) -> 
          Error (sa, "Failed to check that\n  " ^ Pretty.print e2 ^ "\nhas type\n ?0?\n" ^ msg)
        | Error (sa, msg), _ -> 
          Error (sa, "Failed to check that\n  " ^ Pretty.print e1 ^ "\nhas type\n " ^ Pretty.print (Hole (n,l)) ^ "\n" ^ msg)
        end
      end
    | ty1 ->
      let elabi0 = elaborate global ctx lvl sl h1 (ph+1) vars (eval (App (ty1, I0()))) in
      let elabi1 = elaborate global ctx lvl sl h1 (ph+1) vars (eval (App (ty1, I1()))) in
      begin match elabi0, elabi1 with
      | Ok (tyi0, tTyi0, _), Ok (tyi1, _, _) ->
        let elab = elaborate global ctx lvl sl h1 (ph+1) vars (eval ty1) in
        let elab1 = elaborate global ctx lvl sl tyi0 (ph+1) vars (eval e1) in
        let elab2 = elaborate global ctx lvl sl tyi1 (ph+1) vars (eval e2) in
        begin match elab, elab1, elab2 with
        | Ok (ty1', Pi(_, i, ty2), sa), Ok (e1', _, sa1), Ok (e2', _, sa2) ->
          begin match eval i, eval ty2 with
          | Int(), Type n | Hole _, Type n ->
            begin match ty with
            | Type m ->
              if m >= n then 
                Ok (Pathd(ty1', e1', e2'), Type m, Stack.lappend sa sa1 sa2) 
              else 
                Error (Stack.lappend sa sa1 sa2, 
                  "Failed to check that\n  pathd " ^ 
                  Pretty.print ty1' ^ " " ^  Pretty.print e1' ^ " " ^  Pretty.print e2' ^ 
                  "\nhas type\n  " ^ Pretty.print ty)
            | Hole _ -> 
              Ok (Pathd(ty1', e1', e2'), Type n, Stack.lappend sa sa1 sa2)
            | _ -> 
              Error (Stack.lappend sa sa1 sa2, 
              "Failed to check that\n  " ^ Pretty.print ty2 ^ "\nis a type")
            end
          | Int() , Hole _ | Hole _, Hole _ -> 
            Ok (Pathd(ty1', e1', e2'), tTyi0, Stack.lappend sa sa1 sa2)
          | _ -> 
            Error (Stack.lappend sa sa1 sa2, "Failed to unify \n  " ^ Pretty.print i ^ "with\n  I ")
          end
        | Ok (ty1', _, sa), Ok _, Ok _ ->
          Error (sa, "Type mismatch when checking that\n  " ^ Pretty.print ty1' ^ "\nhas type\n  Π (v? : I) ?0?")
        | Error msg, _, _| _, Error msg, _ | _, _, Error msg -> 
          Error msg
        end
      | Error msg, _ | _, Error msg -> 
        Error msg
      end
    end
    
  | Type n ->
    begin
      match Universe.decl lvl n with
      | Ok _ ->
        begin
          match ty with
          | Type m -> 
            if Universe.leq (n, m) then 
              Ok (Type n, Type m, sl) 
            else 
              Error (sl, "Universe inconsistency: the universe level of\n  " ^ Pretty.print (Type n) ^ 
              "\nmust be inferior to the universe level of\n  " ^ Pretty.print (Type m) ^ 
              "\nFailed to prove that" ^ Pretty.print_level n ^ "≤" ^ Pretty.print_level m)
          | Hole _ -> 
            Ok (Type n, Type (Suc n), sl)
          | _ -> 
            Error (sl, "Type mismatch when checking that\n  " ^ Pretty.print (Type n) ^ 
              "\nhas type\n  " ^ Pretty.print ty)
        end
      | Error msg -> 
        Error (sl, msg)
    end
  
  | Hole (n, l) ->
    Ok (Hole (n, l), ty, sl)

  | Wild n ->
    let fails = 
      Error (([], []), 
      "Failed to synthesize placeholder for ?0" ^ string_of_int n ^ "? in the current goal:\n" ^ 
      print ctx ^ "-------------------------------------------\n ⊢ " ^ Pretty.print (eval ty))
    in
    
    (*if Placeholder.is ty then

      let helper x y =
        match Local.find_any_true x with
        | Ok e ->
          let sl' = ((n, e, ty) :: fst sl, y) in
          Ok (Id e, ty, sl')
        | Error _ -> fails
      in
      match Stack.find_index n (snd sl) with
      | Ok l -> 
        helper l (snd sl)
      | Error _ ->
        helper ctx (Stack.make n ctx :: (snd sl))

    else*)

      match Stack.find_index n (snd sl) with
      | Ok l ->
        begin
          match find false global ctx l ty lvl sl ph vars with
          | Ok (e', ty') ->
            if List.mem (n, e', ty') (fst sl) then
              Ok (Id e', ty, sl) 
            else    
              let sl' = ((n, e', ty') :: fst sl, snd sl) in
              Ok (Id e', ty, sl')
          | Error _ -> 
            fails
        end
      | Error _ ->
        begin
          match find true global ctx ctx ty lvl sl ph vars with
          | Ok (e', ty') ->
            if List.mem (n, e', ty') (fst sl) then
              let sl' = (fst sl, Stack.make n ctx :: (snd sl)) in 
              Ok (Id e', ty, sl') (* n, ctx | all true at n *)
            else
              let sl' = ((n, e', ty') :: fst sl, Stack.make n ctx :: (snd sl)) in
              Ok (Id e', ty, sl') (* n, ctx | all true at n *)
          | Error _ ->
            fails
        end

(* Finds a variable in a context for a given type up to unification *)

and find flag global ctx l ty lvl sl ph vars =
  match Local.find_true ty l with
  | Ok id -> Ok (id, ty)
  | Error _ ->
    begin
      let h1 = Placeholder.generate ty ph [] in
      let elab = elaborate global ctx lvl sl h1 ph vars ty in
      match elab with
        | Ok (_, tTy, _) ->
          begin 
            match l with
            | [] -> Error "Can't find match" 
            | (id, ty', b) :: l' ->

              (* When flag=false the search ignores variables set as false *)

              if b || flag then
                let u = unify global ctx lvl sl ph vars (ty, ty', tTy) true in
                begin
                  match u with
                  | Ok uty ->
                    Ok (id, uty)
                  | Error _ ->
                    find flag global ctx l' ty lvl sl ph vars
                end
              else 
                find flag global ctx l' ty lvl sl ph vars
          end
        | Error (_, msg) ->
          Error msg
    end

(* Unifies two expressions at type *)

and unify global ctx lvl sl ph vars x lift =
  match x with
  | e, e', ty ->
    if e = e' then
      Ok e
    else
      match e, e', ty with
      | Hole (n1, l1), Hole (n2, l2), _ ->
        begin match l1, l2 with
        | [], [] -> Ok (Hole (n1, l1))
        | l1, [] -> Ok (Hole (n1, l1))
        | [], l2 -> Ok (Hole (n2, l2))
        | _ ->
          let rec common_el = function
          | [], [] -> Error()
          | _, [] | [], _ -> Error()
          | e :: l1 , e' :: l2 ->
            if List.mem e l2 then
              Ok e
            else if List.mem e' l1 then
              Ok e'
            else
              common_el (l1, l2)
          in
          match common_el (l1,l2) with
          | Ok e -> Ok e
          | Error() ->
            Error ((Hole (n1, l1), Hole (n2, l2)), 
                  "Failed to unify the placeholder\n  ?" ^ 
                  n1 ^ "?\nwhose suitable candidates are\n" ^ 
                  (String.concat " " (List.map Pretty.print l1)) ^
                  "\nwith the placeholder\n  ?" ^ 
                  n2 ^ "?\nwhose suitable candidates are\n" ^ 
                  (String.concat " " (List.map Pretty.print l2))) 
        end

      | e , _, Pathd(_, _, _) ->
        Ok e

      | e , Hole (n, l), _ | Hole (n, l), e, _ ->
        begin match l with
        | [] -> Ok e
        | _ ->
          let rec helper = function
          | [] -> false
          | e' :: l' -> e' = e || helper l' in
          if helper l then 
            Ok e 
          else 
            Error ((e , Hole (n, l)),
                    "Failed to unify the placeholder\n  " ^ 
                    Pretty.print (Ast.Hole (n, l)) ^ "\nwith the suitable candidates\n" ^ 
                    (String.concat " " (List.map Pretty.print l)))
        end
      
      | Pi (x, ty1, ty2), Pi (x', ty1', ty2'), ty -> 
        let v1 = fresh_var ty2 ty2' vars in
        let u1 = unify global ctx lvl sl ph (vars+1) (ty1, ty1', ty) lift in
        begin match u1 with
        | Ok s1 -> 
          let x2 = fullsubst ty1 s1 (subst x (Id v1) ty2) in
          let x2' = fullsubst ty1' s1 (subst x' (Id v1) ty2') in
          let u2 = unify global ((v1, s1, true) :: ctx) lvl sl ph (vars+1) (x2, x2', ty) lift in
          begin match u2 with
          | Ok s2 -> 
            Ok (Pi (v1, s1, s2))
          | Error msg -> 
            Error msg
          end
        | Error msg -> Error msg
        end

      | Sigma (x, ty1, ty2), Sigma (x', ty1', ty2'), ty ->
        let v1 = fresh_var ty2 ty2' vars in
        let u1 = unify global ctx lvl sl ph (vars+1) (ty1, ty1', ty) lift in
        begin match u1 with
        | Ok s1 -> 
          let x2 = fullsubst ty1 s1 (subst x (Id v1) ty2) in
          let x2' = fullsubst ty1' s1 (subst x' (Id v1) ty2') in
          let u2 = unify global ((v1, s1, true) :: ctx) lvl sl ph (vars+1) (x2, x2', ty) lift in
          begin match u2 with
          | Ok s2 -> Ok (Sigma (v1, s1, s2))
          | Error (s, msg) -> Error (s, "Don't know how to unify\n  " ^ Pretty.print ty2 ^ "\nwith\n  " ^ Pretty.print ty2' ^ "\n" ^ msg)
          end
        | Error (s, msg) -> Error (s, "Don't know how to unify\n  " ^ Pretty.print ty1 ^ "\nwith\n  " ^ Pretty.print ty1' ^ "\n" ^ msg)
        end

      | Sum (ty1, ty2) , Sum (ty1', ty2'), ty ->
        let u1 = unify global ctx lvl sl ph vars (ty1, ty1', ty) lift in
        let u2 = unify global ctx lvl sl ph vars (ty2, ty2', ty) lift in
        begin match u1, u2 with
        | Ok s1, Ok s2 -> Ok (Sum (s1, s2))
        | Error msg, _ | _ , Error msg -> 
          Error msg
        end

      | Pathd (e, e1, e2) , Pathd (e', e1', e2'), ty ->
        let u = unify global ctx lvl sl ph vars (e, e', Pi("v?", Int(), ty)) lift in
        let u1 = unify global ctx lvl sl ph vars (e1, e1', eval (App(e, I0()))) lift in
        let u2 = unify global ctx lvl sl ph vars (e2, e2', eval (App(e, I1()))) lift in
        begin match u, u1, u2 with
        | Ok s, Ok s1, Ok s2 -> 
          Ok (Pathd (s, s1, s2))

        | Error msg, _, _ | _ , Error msg, _ | _, _ , Error msg -> 
          Error (fst msg, "Don't know how to unify the pathd types due to the following errors:\n " ^ snd msg)
        end

      | Abs (x, e), Abs (x', e'), Pi(y, ty1 , ty2) ->
        if e = e' then
          Ok (Abs (x, e))
        else if Placeholder.is e' then
          Ok (Abs (x, e))
        else if Placeholder.is e then
          Ok (Abs (x, e'))
        else 
          begin match eval ty1 with
          | Int() | Hole(_,_) ->
            let h1 = Placeholder.generate ty2 ph [] in
            let elabt0 = elaborate global ctx lvl sl h1 ph vars (subst y (I0()) ty2) in
            let elabt1 = elaborate global ctx lvl sl h1 ph vars (subst y (I1()) ty2) in
            begin match elabt0, elabt1 with
            | Ok (tyi0, _, _), Ok (tyi1, _, _) ->
              let elab0 = elaborate global ctx lvl sl tyi0 ph vars (subst x (I0()) e) in
              let elab0' = elaborate global ctx lvl sl tyi0 ph vars (subst x' (I0()) e') in
              let elab1 = elaborate global ctx lvl sl tyi1 ph vars (subst x (I1()) e) in
              let elab1' = elaborate global ctx lvl sl tyi1 ph vars (subst x' (I1()) e') in
              begin match elab0, elab0', elab1, elab1' with
              | Ok (ei0, _, _), Ok (ei0', _, _), Ok (ei1, _, _), Ok (ei1', _, _) -> 
                let u0 = unify global ctx lvl sl ph (vars+1) (ei0, ei0', tyi0) lift in
                let u1 = unify global ctx lvl sl ph (vars+1) (ei1, ei1', tyi1) lift in
                begin match u0, u1 with
                | Ok _, Ok _ -> Ok (Abs (x, e))
                | Error msg, _ | _, Error msg -> Error msg
                end
              | Error (_, msg), _, _, _ | _, Error (_, msg), _, _ | _, _, Error (_, msg), _ | _, _, _, Error (_, msg) -> 
                Error ((Abs (x, e), Abs (x', e')), "Failed endpoint unification of\n  " ^ Pretty.print e ^ 
                  "[" ^ x ^ "/i0]\nwith\n  " ^ Pretty.print e' ^ "[" ^ x' ^ "/i0]\nand\n  " ^ Pretty.print e ^ 
                  "[" ^ x ^ "/i1]\nwith\n  " ^ Pretty.print e' ^ "[" ^ x' ^ "/i1]\n" ^ msg)
              end
            | Error (_, msg), _ | _, Error (_, msg) -> (* This case is impossible *)
              Error ((Abs (x, e), Abs (x', e')), msg)
            end
          | _ ->
            let v1 = fresh_var e e' vars in
            let u = unify global ((v1, ty1, true) :: ctx) lvl sl ph (vars+1) (subst x (Id v1) e, subst x' (Id v1) e', subst y (Id v1) ty2) lift in
            begin match u with
            | Ok s -> Ok (Abs (v1, s))
            | Error msg -> Error msg
            end
          end

      | App (e1, e2), App (e1', e2'), ty ->
        let h1 = Placeholder.generate ty ph [] in
        let elab2 = elaborate global ctx lvl sl h1 ph vars e2 in
        begin 
          match elab2 with
          | Ok (_, ty2, _) ->
            let u2 = unify global ctx lvl sl ph vars (e2, e2', ty2) lift in
            let v1 = fresh_var (App(e1, e1')) ty vars in
            let u1 = unify global ctx lvl sl ph vars (e1, e1', Pi(v1, ty2, fullsubst e2 (Id v1) ty)) lift in
            begin 
              match u1, u2 with
              | Ok s1, Ok s2 -> Ok (App (s1, s2))
              | Error msg, _ | _, Error msg ->
                  
                (* If not unifiable check endpoints *)

                begin
                  let helper x y = 
                    match x, y with
                    | Ok _, Ok _ -> Ok (App (e1, e2))
                    | Error msg, _ | _, Error msg -> Error msg
                  in

                  match eval e2, eval e2', eval ty2 with
                  | Id _, Id _, Int() ->
                    let i0 x = eval (App (x, I0())) in
                    let i1 x = eval (App (x, I1())) in
                    let ui0 = unify global ctx lvl sl ph vars (i0 e1, i0 e1', ty2) lift in
                    let ui1 = unify global ctx lvl sl ph vars (i1 e1, i1 e1', ty2) lift in
                    helper ui0 ui1
                  
                  | _, Id _, Int() ->
                    let i0 x = eval (App (x, I0())) in
                    let i1 x = eval (App (x, I1())) in
                    let ui0 = unify global ctx lvl sl ph vars (App (e1, e2), i0 e1', ty2) lift in
                    let ui1 = unify global ctx lvl sl ph vars (App (e1, e2), i1 e1', ty2) lift in
                    helper ui0 ui1
                  
                  | Id _, _, Int() ->
                    let i0 x = eval (App (x, I0())) in
                    let i1 x = eval (App (x, I1())) in
                    let ui0 = unify global ctx lvl sl ph vars (i0 e1, App (e1', e2'), ty2) lift in
                    let ui1 = unify global ctx lvl sl ph vars (i1 e1, App (e1', e2'), ty2) lift in
                    helper ui0 ui1

                  | _ ->
                    Error msg
              end
          end
        | Error (_, msg) -> (* This case is impossible *)
          Error ((App (e1, e2), App (e1', e2')), msg)
        end
      
      | App (e, i), e', _ | e', App (e, i), _ ->
        begin
          let h1 = Placeholder.generate ty ph [] in
          let elab2 = elaborate global ctx lvl sl h1 ph vars i in
          begin 
            match elab2, i with
            | Ok (_, Int(), _), Id _ ->
              let e0 = eval (App (e, I0())) in
              let e1 = eval (App (e, I1())) in
              let e0' = eval (fullsubst i (I0()) e') in
              let e1' = eval (fullsubst i (I1()) e') in
              let ui0 = unify global ctx lvl sl ph vars (e0, e0', ty) lift in
              let ui1 = unify global ctx lvl sl ph vars (e1, e1', ty) lift in
              begin 
                match ui0, ui1 with
                | Ok _, Ok _ -> Ok (App (e, i))
                | Error msg, _ -> 
                  Error ((e0, e0'), "Don't know how to unify\n  " ^ Pretty.print e0 ^ "\nwith\n  " ^ Pretty.print e0' ^ "\n" ^ Pretty.print (eval e0') ^ "\n" ^ snd msg ) 
                | _, Error msg -> Error ((e1, e1'), "Don't know how to unify\n  " ^ Pretty.print e1 ^ "\nwith\n  " ^ Pretty.print e1' ^ "\n" ^ snd msg)

              end
            | _ ->
              Error ((e, e'), "Don't know how to unify\n  " ^ Pretty.print (App (e, i)) ^ "\nwith\n  " ^ Pretty.print e')
          end
          
        end
      
      | Pair (e1, e2), Pair (e1', e2'), Sigma(y, ty1, ty2) ->
        let u1 = unify global ctx lvl sl ph vars (e1, e1', ty1) lift in
        let u2 = unify global ctx lvl sl ph vars (e2, e2', subst y (Fst e1) ty2) lift in
        begin match u1, u2 with
        | Ok s1, Ok s2 -> Ok (Pair (s1, s2))
        | Error msg, _ | _, Error msg -> Error msg
        end
      
      | Coe (i, j, e1, e2) , Coe (i', j', e1', e2'), ty ->
        let ui = unify global ctx lvl sl ph vars (i, i', Int()) lift in
        let uj = unify global ctx lvl sl ph vars (j, j', Int()) lift in
        let h0 = Placeholder.generate ty ph [] in
        let elab = elaborate global ctx lvl sl h0 ph vars e1 in
        begin
          match elab with
          | Ok (_, eTy, _) ->
            let u1 = unify global ctx lvl sl ph vars (e1, e1', eTy) lift in
            let u2 = unify global ctx lvl sl ph vars (e2, e2', eval (App(e1', i'))) lift in
            begin match ui, uj, u1, u2 with
            | Ok si, Ok sj, Ok s1, Ok s2 -> Ok (Coe (si, sj, s1, s2))
            | Error msg, _, _, _ | _ , Error msg, _, _ | _ , _, Error msg, _ | _ , _, _, Error msg -> 
              Error msg
            end
          | Error (_, msg) -> 
            Error ((Coe (i, j, e1, e2) , Coe (i', j', e1', e2')), msg)
        end
      
      | Hfill (e, e1, e2) , Hfill (e', e1', e2'), ty ->
        let h0 = Placeholder.generate ty ph [] in
        let elab = elaborate global ctx lvl sl h0 ph vars e in
        begin
          match elab with
          | Ok (_, eTy, _) ->
            let u = unify global ctx lvl sl ph vars (e, e', eTy) lift in
            let u1 = unify global ctx lvl sl ph vars (e1, e1', eTy) lift in
            let u2 = unify global ctx lvl sl ph vars (e2, e2', eTy) lift in
            begin match u, u1, u2 with
            | Ok se, Ok se1, Ok se2 -> Ok (Hfill (se, se1, se2))
            | Error msg, _, _ | _ , Error msg, _ | _ , _, Error msg -> 
              Error msg
            end
          | Error (_, msg) -> 
            Error ((Hfill (e, e1, e2) , Hfill (e', e1', e2')), msg)
        end

      | At (Hole _, Hole _), e', _ | e', At (Hole _, Hole _), _ ->
        Ok e'
      
      | At (e1, e2), At (e1', e2'), ty ->
        let u2 = unify global ctx lvl sl ph vars (e2, e2', Int()) lift in
        let h1 = Placeholder.generate ty ph [] in
        let h2 = Placeholder.generate ty (ph+2) [] in
        let i = fresh_var (App(e1, e1')) ty vars in
        let elab1 = elaborate global ctx lvl sl (Pathd (Pi(i, Int(), fullsubst e2 (Id i) ty), h1, h2)) ph vars e1 in
        begin match elab1 with
        | Ok (_, ety, _) ->
          let u1 = unify global ctx lvl sl ph vars (e1, e1', ety) lift in
          begin match u1, u2 with
          | Ok s1, Ok s2 -> Ok (At (s1, s2))
          | Error msg, _ | _, Error msg -> Error msg
          end
        | Error (_, msg) ->
          Error ((At (e1, e2), At (e1', e2')), msg)
        end

      | At (e, i), e', ty | e', At (e, i), ty ->

        (* if i = ε we elaborate and unify e @ ε with e' : ty *)

        if eval i = I0() || eval i = I1() then
        
          let elab = elaborate global ctx lvl sl ty ph vars (At (e, eval i)) in
          begin match elab with
          | Ok (ei, ety, _) ->
            let u1 = unify global ctx lvl sl ph vars (ei, e', ety) lift in
            begin match u1 with
            | Ok se -> Ok se
            | Error msg -> Error msg
            end
          | Error (_, msg) ->
            Error ((At (e, eval i), e'), msg)
          end

        else

        (* if i is a variable, we elaborate and unify e @ ε with e' [ε/i] : ty [ε/i] *)

          begin
            let h1 = Placeholder.generate ty ph [] in
            
            begin 
              match i with
              | Id x ->
                
                let elabt0 = elaborate global ctx lvl sl h1 ph vars (eval (subst x (I0()) ty)) in
                let elabt1 = elaborate global ctx lvl sl h1 ph vars (eval (subst x (I1()) ty)) in
                begin
                  match elabt0, elabt1 with
                  | Ok (ty0, _, _), Ok (ty1, _, _) ->

                    let elab0 = elaborate global ctx lvl sl ty0 ph vars (At (eval (subst x (I0()) e), I0())) in
                    let elab1 = elaborate global ctx lvl sl ty1 ph vars (At (eval (subst x (I1()) e), I1())) in
                    let elab0' = elaborate global ctx lvl sl ty0 ph vars (eval (subst x (I0()) e')) in
                    let elab1' = elaborate global ctx lvl sl ty1 ph vars (eval (subst x (I1()) e')) in

                    begin
                      match elab0, elab1, elab0', elab1' with
                      | Ok (e0, _, _), Ok (e1, _, _), Ok (e0', _, _), Ok (e1', _, _) ->

                        let ui0 = unify global ctx lvl sl ph vars (e0, e0', ty0) lift in
                        let ui1 = unify global ctx lvl sl ph vars (e1, e1', ty1) lift in
                        
                        begin 
                          match ui0, ui1 with
                          | Ok _, Ok _ -> Ok (App (e, i))
                          | Error msg, _ -> 
                            Error ((e0, e0'), "Don't know how to unify\n  " ^ Pretty.print e0 ^ "\nwith\n  " ^ Pretty.print e0' ^ "\n" ^ Pretty.print (eval e0') ^ "\n" ^ snd msg ) 
                          | _, Error msg -> 
                            Error ((e1, e1'), "Don't know how to unify\n  " ^ Pretty.print e1 ^ "\nwith\n  " ^ Pretty.print e1' ^ "\n" ^ snd msg)
                        end
                      | Error (_, msg), _, _, _ | _, Error (_, msg), _, _ | _, _, Error (_, msg), _ |  _, _, _, Error (_, msg) ->
                        Error ((At (e, i), e'), msg)
                    end

                  | Error (_, msg), _ | _, Error (_, msg) -> 
                    Error ((At (e, i), e'), msg) (* This case is impossible *)
                end
              | _ ->
                Error ((e, e'), "Don't know how to unify\n  " ^ Pretty.print (App (e, i)) ^ "\nwith\n  " ^ Pretty.print e')
            end
            
          end

      | Let (e1, e2), Let (e1', e2'), ty ->
        let u1 = unify global ctx lvl sl ph vars (e1, e1', Unit()) lift in
        let u2 = unify global ctx lvl sl ph vars (e2, e2', fullsubst e1 (Star()) ty) lift in
        begin match u1, u2 with
        | Ok s1, Ok s2 -> Ok (Let (s1, s2))
        | Error msg, _ | _, Error msg -> Error msg
        end

      | Fst e, Fst e', ty ->
        let v1 = fresh_var e e' vars in
        let h1 = Placeholder.generate ty ph [] in
        let elab = elaborate global ctx lvl sl (Sigma(v1, ty, h1)) ph vars e in
        begin match elab with
        | Ok (_, ety, _) ->
          let u = unify global ctx lvl sl ph vars (e, e', ety) lift in
          begin match u with
          | Ok s -> Ok (Fst s)
          | Error msg -> Error msg
          end
        | Error (_, msg) -> (* This case is impossible *)
          Error ((Fst e, Fst e'), msg)
        end
        

      | Snd e, Snd e', ty ->
        let v1 = fresh_var e e' vars in
        let h1 = Placeholder.generate ty ph [] in
        let elab = elaborate global ctx lvl sl (Sigma(v1, h1, fullsubst (Fst e) (Id v1) ty)) ph vars e in
        begin match elab with
        | Ok (_, ety, _) ->
          let u = unify global ctx lvl sl ph vars (e, e', ety) lift in
          begin match u with
          | Ok s -> Ok (Snd s)
          | Error msg -> Error msg
          end
        | Error (_, msg) -> (* This case is impossible *)
          Error ((Fst e, Fst e'), msg)
        end

      | Inl e, Inl e', Sum(ty1, _) ->
        let u = unify global ctx lvl sl ph vars (e, e', ty1) lift in
        begin match u with
        | Ok s -> Ok (Inl s)
        | Error msg -> Error msg
        end

      | Inr e, Inr e', Sum(_, ty2) ->
        let u = unify global ctx lvl sl ph vars (e, e', ty2) lift in
        begin match u with
        | Ok s -> Ok (Inr s)
        | Error msg -> Error msg
        end

      | Succ e, Succ e', Nat() ->
        let u = unify global ctx lvl sl ph vars (e, e', Nat()) lift in
        begin match u with
        | Ok s -> Ok (Succ s)
        | Error msg -> Error msg
        end

      | Abort e, Abort e', _ ->
        let u = unify global ctx lvl sl ph vars (e, e', Void()) lift in
        begin match u with
        | Ok s -> Ok (Abort s)
        | Error msg -> Error msg
        end

      | Case (e, e1, e2), Case (e', e1', e2'), ty ->
        let h1 = Placeholder.generate ty ph [] in
        let h2 = Placeholder.generate ty (ph+1) [] in
        let elab = elaborate global ctx lvl sl (Sum(h1, h2)) ph vars e in
        begin match elab with
        | Ok (_, Sum(ty1, ty2), _) ->
          let u = unify global ctx lvl sl ph vars (e, e', Sum(ty1, ty2)) lift in
          let v1 = fresh_var e e' vars in
          let u1 = unify global ctx lvl sl ph vars (e1, e1', Pi(v1, ty1, fullsubst e (Inl (Id v1)) ty)) lift in
          let u2 = unify global ctx lvl sl ph vars (e2, e2', Pi(v1, ty2, fullsubst e (Inr (Id v1)) ty)) lift in
          begin match u, u1, u2 with
          | Ok s, Ok s1, Ok s2 -> Ok (Case (s, s1, s2))
          | Error msg, _, _ | _ , Error msg, _| _ , _, Error msg ->
            Error msg
          end
        | _ -> (* This case never occurs *)
          Error ((Case (e, e1, e2), Case (e', e1', e2')), "Unification error")
        end

      | Natrec (e, e1, e2), Natrec (e', e1', e2'), ty ->
        let u = unify global ctx lvl sl ph vars (e, e', Nat()) lift in
        let u1 = unify global ctx lvl sl ph vars (e1, e1', fullsubst e (Zero()) ty) lift in
        let v1 = fresh_var e e' vars in
        let v2 = fresh_var e e' (vars+1) in
        let tys = (Pi(v1, Nat(), Pi(v2, fullsubst e (Id v1) ty, fullsubst e (Succ (Id v1)) ty))) in
        let u2 = unify global ctx lvl sl ph vars (e2, e2', tys) lift in
        begin match u, u1, u2 with
        | Ok s, Ok s1, Ok s2 -> Ok (Natrec (s, s1, s2))
        | Error msg, _, _ | _ , Error msg, _| _ , _, Error msg ->
          Error msg
        end

      | If (e, e1, e2), If (e', e1', e2'), ty ->
        let u = unify global ctx lvl sl ph vars (e, e', Bool()) lift in
        let u1 = unify global ctx lvl sl ph vars (e1, e1', fullsubst e (True()) ty) lift in
        let u2 = unify global ctx lvl sl ph vars (e2, e2', fullsubst e (False()) ty) lift in
        begin match u, u1, u2 with
        | Ok s, Ok s1, Ok s2 -> Ok (If (s, s1, s2))
        | Error msg, _, _ | _ , Error msg, _| _ , _, Error msg ->
          Error msg
        end

      | Type m, Type n, _ ->
        let msg = (Type m, Type n), "The types\n  " ^ Pretty.print (Type m) ^ "\nand\n  " ^ Pretty.print (Type n) ^ "\nhave incompatible universe levels" in
        if lift then
          if Universe.leq (n, m) then
            Ok (Type n)
          else
            Error msg
        else
          Error msg
      
      | e , e', _ -> 
        if eval e = eval e' then 
          Ok e 
        else 
          Error ((e, e'), "The terms\n  " ^ Pretty.print e ^ "\nand\n  " ^ Pretty.print e' ^ "\nare not equal")
