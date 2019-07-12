(**
 * (c) Copyright 2019 Bruno Bentzen. All rights reserved.
 * Released under Apache 2.0 license as described in the file LICENSE.
 * Desc: Typechecked definitions are appended to a list containing
 *       their identifiers, the whole term, and their type.
 *       This file handles operations on this 'global environment' list
 **)

open Basis
open Ast

(* Determines whether a variable has been declared in the global context *)

let is_declared x global =
  let rec helper x = function
    | [] -> false
    | (id, (_, _)) :: global -> 
      if x = id then 
        true
      else 
        helper x global
  in
  helper x (List.rev global)

(* Generates a triple id * term * type from a successfully elaborated triple id * ctx * elab *)

let function_of_def id ctx (e, ty) hole =
  let rec helper h' = function
    | [] -> e, ty
    | (x, ty, true) :: ctx ->  
      Abs (x, fst (helper h' ctx )), 
      Pi (x, ty, snd (helper h' ctx))
    | (x, _, false) :: ctx ->  
      let h = Placeholder.generate (fst (helper (h'+1) ctx)) h' [] in
      Substitution.subst x h (fst (helper (h'+1) ctx)), 
      Substitution.subst x h (snd (helper (h'+1) ctx )) 
  in
  id, helper hole ctx

let rec check_def_id id = function
  | [] -> 
    Error ("No definition or theorem found for the identifier '" ^ id ^ "'") 
  | (id', body) :: global -> 
    if id = id'
    then Ok body
    else check_def_id id global

(* Appends a triple id * term * type to the global context *)

let add_to_global_env global id ctx elab =
  match check_def_id id global with
  | Ok _ -> global
  | Error _ -> function_of_def id ctx elab 0 :: global

(* Returns the body of a definition when given a declared global constant *)

let rec unfold id = function
  | [] -> 
    Error ("No declaration found for identifier '" ^ id ^ "'")
  | (id', (body , ty)) :: global -> 
    if id = id' then 
      Ok (body, ty)
    else 
      unfold id global

(* Uniformly lifts all indices of implicit arguments in a global variable *)

let rec lift n = function
  | Wild m ->
    Wild (m+n)
  | Id y -> Id y
  | Coe (i, j, e1, e2) -> 
    Coe (lift n i, lift n j, 
    lift n e1, lift n e2)
  | Hfill (e, e1, e2) -> 
    Hfill (lift n e, lift n e1, lift n e2)
  | Abs (y, e) -> 
    Abs (y, lift n e)
  | App (e1, e2) -> App (lift n e1, lift n e2)
  | Pi (y, e1, e2) -> 
    Pi (y, lift n e1, lift n e2)
  | Pair (e1, e2) -> 
    Pair (lift n e1, lift n e2)
  | Fst e -> Fst (lift n e)
  | Snd e -> Snd (lift n e)
  | Sigma (y, e1, e2) ->
    Sigma (y, lift n e1, lift n e2)
  | Inl e -> Inl (lift n e)
  | Inr e -> Inr (lift n e)
  | Case (e, e1, e2) -> 
    Case (lift n e, lift n e1, lift n e2)
  | Sum (e1, e2) -> 
    Sum (lift n e1, lift n e2)
  | Succ e -> Succ (lift n e)
  | Natrec (e, e1, e2) -> 
    Natrec (lift n e, lift n e1, lift n e2)
  | If (e, e1, e2) -> 
    If (lift n e, lift n e1, lift n e2)
  | Let (e, e1) -> Let (lift n e, lift n e1)
  | Abort e -> Abort (lift n e)
  | Pabs (y, e) -> 
    Pabs (y, lift n e)
  | At (e1, e2) -> 
    At (lift n e1, lift n e2)
  | Pathd (e, e1, e2) -> 
    Pathd (lift n e, lift n e1, lift n e2)
  | e -> 
    e

(* Unfolds all declared global constants and checks for naming conflicts *)

let rec unfold_all global vars = function
  | Id x -> 
    begin 
      match unfold x global with
      | Ok (body, _) -> Ok body
      | _ -> Ok (Id x)
    end

  | Abs (x, e) ->
    if is_declared x global then
      Error ("Naming conflict with the name '" ^ x ^ 
        "'\nIt occurs as definition/theorem identifier but is used as a variable name ")
    else
      begin match unfold_all global vars e with
      | Ok e' -> 
        Ok (Abs (x, e'))
      | Error msg -> Error msg
      end

  | Pabs (x, e) -> 
    if is_declared x global then
      Error ("Naming conflict with the name '" ^ x ^ 
        "'\nIt occurs as definition/theorem identifier but is used as a variable name ")
    else
      begin match unfold_all global vars e with
      | Ok e' -> 
        Ok (Pabs (x, e'))
      | Error msg -> Error msg
      end

  | App (e1, e2) ->
    let u1 = unfold_all global vars e1 in
    let u2 = unfold_all global vars e2 in
    begin match u1, u2 with
      | Ok e1', Ok e2' -> Ok (App (e1', e2'))
      | Error msg, _ | _, Error msg -> Error msg
    end
    
  | Pair (e1, e2) ->
    let u1 = unfold_all global vars e1 in
    let u2 = unfold_all global vars e2 in
    begin match u1, u2 with
      | Ok e1', Ok e2' -> Ok (Pair (e1', e2'))
      | Error msg, _ | _, Error msg -> Error msg
    end

  | At (e1, e2) ->
    let u1 = unfold_all global vars e1 in
    let u2 = unfold_all global vars e2 in
    begin match u1, u2 with
      | Ok e1', Ok e2' -> Ok (At (e1', e2'))
      | Error msg, _ | _, Error msg -> Error msg
    end

  | Let (e1, e2) ->
    let u1 = unfold_all global vars e1 in
    let u2 = unfold_all global vars e2 in
    begin match u1, u2 with
      | Ok e1', Ok e2' -> Ok (Let (e1', e2'))
      | Error msg, _ | _, Error msg -> Error msg
    end

  | Fst e ->
    begin match unfold_all global vars e with
    | Ok e' -> 
      Ok (Fst e')
    | Error msg -> Error msg
    end

  | Snd e ->
    begin match unfold_all global vars e with
    | Ok e' -> 
      Ok (Snd e')
    | Error msg -> Error msg
    end

  | Inl e ->
    begin match unfold_all global vars e with
    | Ok e' -> 
      Ok (Inl e')
    | Error msg -> Error msg
    end

  | Inr e ->
    begin match unfold_all global vars e with
    | Ok e' -> 
      Ok (Inr e')
    | Error msg -> Error msg
    end

  | Succ e ->
    begin match unfold_all global vars e with
    | Ok e' -> 
      Ok (Succ e')
    | Error msg -> Error msg
    end

  | Abort e -> 
    begin match unfold_all global vars e with
    | Ok e' -> 
      Ok (Abort e')
    | Error msg -> Error msg
    end

  | Case (e, e1, e2) ->
    let u = unfold_all global vars e in
    let u1 = unfold_all global vars e1 in
    let u2 = unfold_all global vars e2 in
    begin match u, u1, u2 with
      | Ok e', Ok e1', Ok e2' -> Ok (Case (e', e1', e2'))
      | Error msg, _, _ | _, Error msg , _ | _, _, Error msg -> Error msg
    end

  | Natrec (e, e1, e2) ->
    let u = unfold_all global vars e in
    let u1 = unfold_all global vars e1 in
    let u2 = unfold_all global vars e2 in
    begin match u, u1, u2 with
      | Ok e', Ok e1', Ok e2' -> Ok (Natrec (e', e1', e2'))
      | Error msg, _, _ | _, Error msg , _ | _, _, Error msg -> Error msg
    end

  | If (e, e1, e2) ->
    let u = unfold_all global vars e in
    let u1 = unfold_all global vars e1 in
    let u2 = unfold_all global vars e2 in
    begin match u, u1, u2 with
      | Ok e', Ok e1', Ok e2' -> Ok (If (e', e1', e2'))
      | Error msg, _, _ | _, Error msg , _ | _, _, Error msg -> Error msg
    end

  | Pi (x, e1, e2) -> 
    if is_declared x global then
      Error ("Naming conflict with the name '" ^ x ^ "'\nIt occurs as definition/theorem identifier but is used as a variable name ")
    else
      let u1 = unfold_all global vars e1 in
      let u2 = unfold_all global vars e2 in
      begin match u1, u2 with
      | Ok e1', Ok e2' -> Ok (Pi (x, e1', e2'))
      | Error msg, _ | _, Error msg -> Error msg
      end

  | Sigma (x, e1, e2) -> 
    if is_declared x global then
      Error ("Naming conflict with the name '" ^ x ^ "'\nIt occurs as definition/theorem identifier but is used as a variable name ")
    else
      let u1 = unfold_all global vars e1 in
      let u2 = unfold_all global vars e2 in
      begin match u1, u2 with
      | Ok e1', Ok e2' -> Ok (Sigma (x, e1', e2'))
      | Error msg, _ | _, Error msg -> Error msg
      end

  | Sum (e1, e2) ->
    let u1 = unfold_all global vars e1 in
    let u2 = unfold_all global vars e2 in
    begin match u1, u2 with
      | Ok e1', Ok e2' -> Ok (Sum (e1', e2'))
      | Error msg, _ | _, Error msg -> Error msg
    end

  | Pathd (e, e1, e2) -> 
    let u = unfold_all global vars e in
    let u1 = unfold_all global vars e1 in
    let u2 = unfold_all global vars e2 in
    begin match u, u1, u2 with
      | Ok e', Ok e1', Ok e2' -> Ok (Pathd (e', e1', e2'))
      | Error msg, _, _ | _, Error msg , _ | _, _, Error msg -> Error msg
    end
  
  | Coe (i, j, e1, e2) ->
    let ui = unfold_all global vars i in
    let uj = unfold_all global vars j in
    let u1 = unfold_all global vars e1 in
    let u2 = unfold_all global vars e2 in
    begin match ui, uj, u1, u2 with
      | Ok i', Ok j', Ok e1', Ok e2' -> Ok (Coe (i', j', e1', e2'))
      | Error msg, _, _, _ | _, Error msg , _, _ | _, _, Error msg, _ | _, _, _, Error msg -> 
        Error msg
    end
  
  | Hfill (e, e1, e2) -> 
    let u = unfold_all global vars e in
    let u1 = unfold_all global vars e1 in
    let u2 = unfold_all global vars e2 in
    begin match u, u1, u2 with
      | Ok e', Ok e1', Ok e2' -> Ok (Hfill (e', e1', e2'))
      | Error msg, _, _ | _, Error msg , _ | _, _, Error msg -> Error msg
    end 

  | e -> Ok e 