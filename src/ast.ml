(**
 * (c) Copyright 2019 Bruno Bentzen. All rights reserved.
 * Released under Apache 2.0 license as described in the file LICENSE.
 * Desc: The abstract syntax of terms and types
 **)

(* TODO: universe lvls: id, num, max lvl lvl *)

type expr = 
  | Id of string
  | Int of unit
  | I1 of unit
  | I0 of unit
  | Abs of string * expr
  | App of expr * expr
  | Pi of string * expr * expr  
  | Pair of expr * expr
  | Fst of expr
  | Snd of expr
  | Sigma of string * expr * expr
  | Inl of expr
  | Inr of expr
  | Case of expr * expr * expr
  | Sum of expr * expr
  | Star of unit
  | Let of expr * expr
  | Unit of unit
  | True of unit
  | False of unit
  | If of expr * expr * expr
  | Bool of unit
  | Zero of unit
  | Succ of expr
  | Natrec of expr * expr * expr
  | Nat of unit
  | Abort of expr
  | Void of unit
  | Pabs of string * expr
  | At of expr * expr
  | Pathd of expr * expr * expr
  | Type of int
  | Hole of string
  | Wild of unit

type command = 
    | Def of string * ((string list * expr) list) * expr * expr * command
    | Eof of unit

type binstr = 
  | Print of expr
  | Assign of string * expr

(* Unparse function *)

let rec unparse = function
	| Id y -> y ^ " "
	| I0() -> "i0 "
	| I1() -> "i1 "
	| Int() -> "I " 
	| Abs (y, e) ->  String.concat "" ["λ "; y; ", "; unparse e; " "]
	| App (e1, e2) -> String.concat "" ["( "; unparse e1; ") "; unparse e2; " "]
	| Pi (y, e1, e2) -> String.concat "" ["Π ( "; y; " : "; unparse e1; ") "; unparse e2; " "]
	| Pair (e1, e2) -> String.concat "" ["("; unparse e1; ", "; unparse e2; ") "]
	| Fst e -> String.concat "" ["fst "; unparse e; " "]
	| Snd e -> String.concat "" ["snd "; unparse e; " "]
	| Sigma (y, e1, e2) -> String.concat "" ["Σ ( "; y; " : "; unparse e1; ") "; unparse e2; " "]
	| Inl e -> String.concat "" ["inl "; unparse e; " "]
	| Inr e -> String.concat "" ["inr "; unparse e; " "]
	| Case (e, e1, e2) -> String.concat "" ["case "; unparse e; " "; unparse e1; " "; unparse e2; ") "]
	| Sum (e1, e2) -> String.concat "" ["( "; unparse e1; "+ "; unparse e2; ") "]
	| Zero() -> "0 "
	| Succ e -> String.concat "" ["succ "; unparse e; " "]
	| Natrec (e, e1, e2) -> String.concat "" ["natrec "; unparse e; " "; unparse e1; " "; unparse e2; ") "]
	| Nat() -> "nat "
	| True() -> "true "
	| False() -> "false "
	| If (e, e1, e2) -> String.concat "" ["if "; unparse e; " "; unparse e1; " "; unparse e2; ") "]
	| Bool() -> "bool "
	| Star() -> "() "
	| Let (e1, e2) -> String.concat "" ["let "; unparse e1; " "; unparse e2; ") "]
	| Unit() -> "unit "
	| Abort e -> String.concat "" ["abort "; unparse e; " "]
	| Void() -> "void "
	| Pabs (y, e) -> String.concat "" ["<"; y; "> "; unparse e; " "]
	| At (e1, e2) -> String.concat "" ["( "; unparse e1; "@ "; unparse e2; ") "]
	| Pathd (e, e1, e2) -> String.concat "" ["pathd ( "; unparse e; ") "; unparse e1; " "; unparse e2; " "]
	| Type n -> String.concat "" ["type "; string_of_int n; " "]
  | Hole n -> String.concat "" ["?"; n; "? "]
  | Wild() -> "_ "
