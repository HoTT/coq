(************************************************************************)
(*  v      *   The Coq Proof Assistant  /  The Coq Development Team     *)
(* <O___,, *   INRIA - CNRS - LIX - LRI - PPS - Copyright 1999-2012     *)
(*   \VV/  **************************************************************)
(*    //   *      This file is distributed under the terms of the       *)
(*         *       GNU Lesser General Public License Version 2.1        *)
(************************************************************************)

(* File created by Vincent Siles, Oct 2007, extended into a generic
   support for generation of inductive schemes by Hugo Herbelin, Nov 2009 *)

(* This file provides support for registering inductive scheme builders,
   declaring schemes and generating schemes on demand *)

open Names
open Mod_subst
open Libobject
open Nameops
open Declarations
open Term
open Errors
open Util
open Declare
open Entries
open Decl_kinds

(**********************************************************************)
(* Registering schemes in the environment *)

type mutual_scheme_object_function = mutual_inductive -> constr array Univ.in_universe_context
type individual_scheme_object_function = inductive -> constr Univ.in_universe_context

type 'a scheme_kind = string

let scheme_map = ref Indmap.empty

let cache_one_scheme kind (ind,const) =
  let map = try Indmap.find ind !scheme_map with Not_found -> String.Map.empty in
  scheme_map := Indmap.add ind (String.Map.add kind const map) !scheme_map

let cache_scheme (_,(kind,l)) =
  Array.iter (cache_one_scheme kind) l

let subst_one_scheme subst (ind,const) =
  (* Remark: const is a def: the result of substitution is a constant *)
  (subst_ind subst ind,subst_constant subst const)

let subst_scheme (subst,(kind,l)) =
  (kind,Array.map (subst_one_scheme subst) l)

let discharge_scheme (_,(kind,l)) =
  Some (kind,Array.map (fun (ind,const) ->
    (Lib.discharge_inductive ind,Lib.discharge_con const)) l)

let inScheme : string * (inductive * constant) array -> obj =
  declare_object {(default_object "SCHEME") with
                    cache_function = cache_scheme;
                    load_function = (fun _ -> cache_scheme);
                    subst_function = subst_scheme;
		    classify_function = (fun obj -> Substitute obj);
		    discharge_function = discharge_scheme}

(**********************************************************************)
(* Saving/restoring the table of scheme *)

let freeze_schemes () = !scheme_map
let unfreeze_schemes sch = scheme_map := sch
let init_schemes () = scheme_map := Indmap.empty

let _ =
  Summary.declare_summary "Schemes"
    { Summary.freeze_function = freeze_schemes;
      Summary.unfreeze_function = unfreeze_schemes;
      Summary.init_function = init_schemes }

(**********************************************************************)
(* The table of scheme building functions *)

type individual
type mutual

type scheme_object_function =
  | MutualSchemeFunction of mutual_scheme_object_function
  | IndividualSchemeFunction of individual_scheme_object_function

let scheme_object_table =
  (Hashtbl.create 17 : (string, string * scheme_object_function) Hashtbl.t)

let declare_scheme_object s aux f =
  (try Id.check ("ind"^s) with _ ->
    error ("Illegal induction scheme suffix: "^s));
  let key = if String.is_empty aux then s else aux in
  try
    let _ = Hashtbl.find scheme_object_table key in
(*    let aux_msg = if aux="" then "" else " (with key "^aux^")" in*)
    error ("Scheme object "^key^" already declared.")
  with Not_found ->
    Hashtbl.add scheme_object_table key (s,f);
    key

let declare_mutual_scheme_object s ?(aux="") f =
  declare_scheme_object s aux (MutualSchemeFunction f)

let declare_individual_scheme_object s ?(aux="") f =
  declare_scheme_object s aux (IndividualSchemeFunction f)

(**********************************************************************)
(* Defining/retrieving schemes *)

let declare_scheme kind indcl =
  Lib.add_anonymous_leaf (inScheme (kind,indcl))

let is_visible_name id =
  try ignore (Nametab.locate (Libnames.qualid_of_ident id)); true
  with Not_found -> false

let compute_name internal id =
  match internal with
  | KernelVerbose | UserVerbose -> id
  | KernelSilent ->
      Namegen.next_ident_away_from (add_prefix "internal_" id) is_visible_name

let define internal id c p univs =
  let fd = declare_constant ~internal in
  let id = compute_name internal id in
  let kn = fd id
    (DefinitionEntry
      { const_entry_body = c;
        const_entry_secctx = None;
        const_entry_type = None;
	const_entry_polymorphic = p;
	const_entry_universes = univs;
        const_entry_opaque = false },
      Decl_kinds.IsDefinition Scheme) in
  (match internal with
  | KernelSilent -> ()
  | _-> definition_message id);
  kn

let define_individual_scheme_base kind suff f internal idopt (mind,i as ind) =
  let c, ctx = f ind in
  let mib = Global.lookup_mind mind in
  let id = match idopt with
    | Some id -> id
    | None -> add_suffix mib.mind_packets.(i).mind_typename suff in
  let const = define internal id c (Flags.is_universe_polymorphism ()) ctx in
  declare_scheme kind [|ind,const|];
  const

let define_individual_scheme kind internal names (mind,i as ind) =
  match Hashtbl.find scheme_object_table kind with
  | _,MutualSchemeFunction f -> assert false
  | s,IndividualSchemeFunction f ->
      define_individual_scheme_base kind s f internal names ind

let define_mutual_scheme_base kind suff f internal names mind =
  let cl, ctx = f mind in
  let mib = Global.lookup_mind mind in
  let ids = Array.init (Array.length mib.mind_packets) (fun i ->
      try List.assoc i names
      with Not_found -> add_suffix mib.mind_packets.(i).mind_typename suff) in
  let consts = Array.map2 (fun id cl -> 
     define internal id cl (Flags.is_universe_polymorphism ()) ctx) ids cl in
  declare_scheme kind (Array.mapi (fun i cst -> ((mind,i),cst)) consts);
  consts

let define_mutual_scheme kind internal names mind =
  match Hashtbl.find scheme_object_table kind with
  | _,IndividualSchemeFunction _ -> assert false
  | s,MutualSchemeFunction f ->
      define_mutual_scheme_base kind s f internal names mind

let find_scheme kind (mind,i as ind) =
  try String.Map.find kind (Indmap.find ind !scheme_map)
  with Not_found ->
  match Hashtbl.find scheme_object_table kind with
  | s,IndividualSchemeFunction f ->
      define_individual_scheme_base kind s f KernelSilent None ind
  | s,MutualSchemeFunction f ->
      (define_mutual_scheme_base kind s f KernelSilent [] mind).(i)

let check_scheme kind ind =
  try let _ = String.Map.find kind (Indmap.find ind !scheme_map) in true
  with Not_found -> false

let poly_scheme f dep env ind k =
  let sigma, indu = Evarutil.fresh_inductive_instance env (Evd.from_env env) ind in
    f dep env indu k, Evd.universe_context sigma

let poly_evd_scheme f dep env ind k =
  let sigma, indu = Evarutil.fresh_inductive_instance env (Evd.from_env env) ind in
    f dep env sigma indu k, Evd.universe_context sigma
