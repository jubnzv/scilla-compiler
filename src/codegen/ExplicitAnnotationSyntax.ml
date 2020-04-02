(*
  This file is part of scilla.

  Copyright (c) 2019 - present Zilliqa Research Pvt. Ltd.

  scilla is free software: you can redistribute it and/or modify it under the
  terms of the GNU General Public License as published by the Free Software
  Foundation, either version 3 of the License, or (at your option) any later
  version.

  scilla is distributed in the hope that it will be useful, but WITHOUT ANY
  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
  A PARTICULAR PURPOSE.  See the GNU General Public License for more details.

  You should have received a copy of the GNU General Public License along with
*)

open Core_kernel
open! Int.Replace_polymorphic_compare
open Syntax
open ErrorUtils

(* Explicit annotation. *)
type eannot = { ea_tp : typ option; ea_loc : loc } [@@deriving sexp]

let empty_annot = { ea_tp = None; ea_loc = ErrorUtils.dummy_loc }

(* Scilla AST with explicit annotations. While having functors is useful
 * when the AST remains same but we expect different annotations, here we have
 * different ASTs at each stage of compilation, making functors harder to work
 * with. So just translate the AST to a simple non-parameterized definition.
 * (The actual coversion is performed by the [AnnotationExplicitizer] pass. *)
module EASyntax = struct
  type payload = MLit of literal | MVar of eannot ident [@@deriving sexp]

  type pattern =
    | Wildcard
    | Binder of eannot ident
    | Constructor of string * pattern list
  [@@deriving sexp]

  type expr_annot = expr * eannot

  and expr =
    | Literal of literal
    | Var of eannot ident
    | Let of eannot ident * typ option * expr_annot * expr_annot
    | Message of (string * payload) list
    | Fun of eannot ident * typ * expr_annot
    | App of eannot ident * eannot ident list
    | Constr of string * typ list * eannot ident list
    | MatchExpr of eannot ident * (pattern * expr_annot) list
    | Builtin of eannot builtin_annot * eannot ident list
    (* Advanced features: to be added in Scilla 0.2 *)
    | TFun of eannot ident * expr_annot
    | TApp of eannot ident * typ list
    (* Fixpoint combinator: used to implement recursion principles *)
    | Fixpoint of eannot ident * typ * expr_annot
  [@@deriving sexp]

  (***************************************************************)
  (* All definions below are identical to the ones in Syntax.ml. *)
  (***************************************************************)

  type stmt_annot = stmt * eannot

  and stmt =
    | Load of eannot ident * eannot ident
    | Store of eannot ident * eannot ident
    | Bind of eannot ident * expr_annot
    (* m[k1][k2][..] := v OR delete m[k1][k2][...] *)
    | MapUpdate of eannot ident * eannot ident list * eannot ident option
    (* v <- m[k1][k2][...] OR b <- exists m[k1][k2][...] *)
    (* If the bool is set, then we interpret this as value retrieve,
         otherwise as an "exists" query. *)
    | MapGet of eannot ident * eannot ident * eannot ident list * bool
    | MatchStmt of eannot ident * (pattern * stmt_annot list) list
    | ReadFromBC of eannot ident * string
    | AcceptPayment
    | SendMsgs of eannot ident
    | CreateEvnt of eannot ident
    | CallProc of eannot ident * eannot ident list
    | Iterate of eannot ident * eannot ident
    | Throw of eannot ident option

  type component = {
    comp_type : component_type;
    comp_name : eannot ident;
    comp_params : (eannot ident * typ) list;
    comp_body : stmt_annot list;
  }

  type ctr_def = { cname : eannot ident; c_arg_types : typ list }

  type lib_entry =
    | LibVar of eannot ident * typ option * expr_annot
    | LibTyp of eannot ident * ctr_def list

  type library = { lname : eannot ident; lentries : lib_entry list }

  type contract = {
    cname : eannot ident;
    cparams : (eannot ident * typ) list;
    cfields : (eannot ident * typ * expr_annot) list;
    ccomps : component list;
  }

  (* Contract module: libary + contract definiton *)
  type cmodule = {
    smver : int;
    (* Scilla major version of the contract. *)
    cname : eannot ident;
    libs : library option;
    (* lib functions defined in the module *)
    (* List of imports / external libs with an optional namespace. *)
    elibs : (eannot ident * eannot ident option) list;
    contr : contract;
  }

  (* Library module *)
  type lmodule = {
    (* List of imports / external libs with an optional namespace. *)
    elibs : (eannot ident * eannot ident option) list;
    libs : library; (* lib functions defined in the module *)
  }

  (* A tree of libraries linked to their dependents *)
  type libtree = {
    libn : library;
    (* The library this node represents *)
    deps : libtree list; (* List of dependent libraries *)
  }

  (* get variables that get bound in pattern. *)
  let get_pattern_bounds p =
    let rec accfunc p acc =
      match p with
      | Wildcard -> acc
      | Binder i -> i :: acc
      | Constructor (_, plist) ->
          List.fold plist ~init:acc ~f:(fun acc p' -> accfunc p' acc)
    in
    accfunc p []

  let rec subst_type_in_expr tvar tp (e, rep') =
    (* Function to substitute in a rep. *)
    let subst_rep r =
      let t' = Option.map r.ea_tp ~f:(subst_type_in_type' tvar tp) in
      { r with ea_tp = t' }
    in
    (* Function to substitute in an id. *)
    let subst_id id = Ident (get_id id, subst_rep (get_rep id)) in
    (* Substitute in rep of the expression itself. *)
    let rep = subst_rep rep' in
    (* Substitute in the expression: *)
    match e with
    | Literal l -> (Literal (subst_type_in_literal tvar tp l), rep)
    | Var i -> (Var (subst_id i), rep)
    | Fun (f, t, body) ->
        let t_subst = subst_type_in_type' tvar tp t in
        let body_subst = subst_type_in_expr tvar tp body in
        (Fun (subst_id f, t_subst, body_subst), rep)
    | TFun (tv, body) as tf ->
        if equal_id tv tvar then (tf, rep)
        else
          let body_subst = subst_type_in_expr tvar tp body in
          (TFun (tv, body_subst), rep)
    | Constr (n, ts, es) ->
        let ts' = List.map ts ~f:(fun t -> subst_type_in_type' tvar tp t) in
        let es' = List.map es ~f:subst_id in
        (Constr (n, ts', es'), rep)
    | App (f, args) ->
        let args' = List.map args ~f:subst_id in
        (App (subst_id f, args'), rep)
    | Builtin (b, args) ->
        let args' = List.map args ~f:subst_id in
        (Builtin (b, args'), rep)
    | Let (i, tann, lhs, rhs) ->
        let tann' =
          Option.map tann ~f:(fun t -> subst_type_in_type' tvar tp t)
        in
        let lhs' = subst_type_in_expr tvar tp lhs in
        let rhs' = subst_type_in_expr tvar tp rhs in
        (Let (subst_id i, tann', lhs', rhs'), rep)
    | Message splist ->
        let m' =
          List.map splist ~f:(fun (s, p) ->
              let p' =
                match p with
                | MLit l -> MLit (subst_type_in_literal tvar tp l)
                | MVar v -> MVar (subst_id v)
              in
              (s, p'))
        in
        (Message m', rep)
    | MatchExpr (e, cs) ->
        let rec subst_pattern p =
          match p with
          | Wildcard -> Wildcard
          | Binder v -> Binder (subst_id v)
          | Constructor (s, pl) -> Constructor (s, List.map pl ~f:subst_pattern)
        in
        let cs' =
          List.map cs ~f:(fun (p, b) ->
              (subst_pattern p, subst_type_in_expr tvar tp b))
        in
        (MatchExpr (subst_id e, cs'), rep)
    | TApp (tf, tl) ->
        let tl' = List.map tl ~f:(fun t -> subst_type_in_type' tvar tp t) in
        (TApp (subst_id tf, tl'), rep)
    | Fixpoint (f, t, body) ->
        let t' = subst_type_in_type' tvar tp t in
        let body' = subst_type_in_expr tvar tp body in
        (Fixpoint (subst_id f, t', body'), rep)
end
