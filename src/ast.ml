(**
 * (c) Copyright 2019 Bruno Bentzen. All rights reserved.
 * Released under Apache 2.0 license as described in the file LICENSE.
 * Desc: The abstract syntax of terms and types
 **)

type level = 
  | Num of int
  | Var of string
  | Suc of level
  | Max of level * level

type expr = 
  | Id of string
  | Int of unit
  | I1 of unit
  | I0 of unit
  | Coe of expr * expr * expr * expr
  | Hfill of expr * expr * expr
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
  | Type of level
  | Hole of string * (expr list)
  | Wild of int

type proof = 
  | Prf of string * (((string list * expr) * bool) list) * expr * expr

type command = 
    | Import of command * string
    | Thm of command * proof
    | Print of command * string
    | Infer of command * expr
    | Level of command * string list
    | Eof of unit
