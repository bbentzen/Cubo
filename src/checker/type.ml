(**
 * (c) Copyright 2019 Bruno Bentzen. All rights reserved.
 * Released under Apache 2.0 license as described in the file LICENSE.
 * Desc: Checks whether an expression is a type
         Allows for placeholders to stand for types
 **)

open Basis
open Ast

let check global ctx lvl ty =
  match ty with
  | Hole _ -> Ok (Hole ("0",[]), ty)
  | _ ->
    let elab = Elab.elaborate global ctx lvl (Hole ("0",[])) 1 0 (Eval.reduce ty) in
    match elab with
    | Ok (ty', tTy) ->
      begin
        match tTy with
        | Type _ ->
          Ok (ty', tTy)
        | Hole _ -> (* Hole _ has been added for tests*)
          Ok (ty', tTy)
        | _ -> 
          Error ("Failed to prove that \n  " ^ Pretty.print (Eval.eval ty) ^ "\nis a type")
      end
    | Error msg -> Error msg