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

open Core
open Syntax

let newname_prefix_char = "$"

(* Create a closure for creating new variable names.
  * The closure maintains a state for incremental numbering.
  * This seems much simpler than carrying around an integer
  * everywhere in functional style. Since this isn't critical,
  * I choose readability over immutability.
  *)
let newname_creator () =
  let name_counter = ref 0 in
  (fun base rep ->
    (* system generated names will begin with "$" for uniqueness. *)
    let n = newname_prefix_char ^ base ^ "_" ^ (Int.to_string !name_counter) in
    name_counter := (!name_counter+1);
    asIdL n rep)

let global_name_counter = ref 0
let global_newnamer =
  (* Cannot just call newname_creator() because of OCaml's weak type limitation. *)
  (fun base rep ->
    (* system generated names will begin with "$" for uniqueness. *)
    let n = newname_prefix_char ^ base ^ "_" ^ (Int.to_string !global_name_counter) in
    global_name_counter := (!global_name_counter+1);
    asIdL n rep)