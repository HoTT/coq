(************************************************************************)
(*  v      *   The Coq Proof Assistant  /  The Coq Development Team     *)
(* <O___,, *   INRIA - CNRS - LIX - LRI - PPS - Copyright 1999-2012     *)
(*   \VV/  **************************************************************)
(*    //   *      This file is distributed under the terms of the       *)
(*         *       GNU Lesser General Public License Version 2.1        *)
(************************************************************************)

open Pp
open Errors
open Util
open Names
open Term
open Declarations
open Libobject
open Environ
open Pattern
open Printer
open Libnames
open Globnames
open Nametab

type filter_function = global_reference -> env -> constr -> bool
type display_function = global_reference -> env -> constr -> unit

type glob_search_about_item =
  | GlobSearchSubPattern of constr_pattern
  | GlobSearchString of string

module SearchBlacklist =
  Goptions.MakeStringTable
    (struct
      let key = ["Search";"Blacklist"]
      let title = "Current search blacklist : "
      let member_message s b =
	str ("Search blacklist does "^(if b then "" else "not ")^"include "^s)
      let synchronous = true
     end)

(* The functions iter_constructors and iter_declarations implement the behavior
   needed for the Coq searching commands.
   These functions take as first argument the procedure
   that will be called to treat each entry.  This procedure receives the name
   of the object, the assumptions that will make it possible to print its type,
   and the constr term that represent its type. *)

let iter_constructors indsp fn env nconstr =
  for i = 1 to nconstr do
    let typ, _ = Inductiveops.type_of_constructor_in_ctx env (indsp, i) in
    fn (ConstructRef (indsp, i)) env typ
  done

let rec head_const c = match kind_of_term c with
  | Prod (_,_,d) -> head_const d
  | LetIn (_,_,_,d) -> head_const d
  | App (f,_)   -> head_const f
  | Cast (d,_,_)   -> head_const d
  | _            -> c

(* General search over declarations *)
let iter_declarations (fn : global_reference -> env -> constr -> unit) =
  let env = Global.env () in
  let iter_obj (sp, kn) lobj = match object_tag lobj with
  | "VARIABLE" ->
    begin try
      let (id, _, typ) = Global.lookup_named (basename sp) in
      fn (VarRef id) env typ
    with Not_found -> (* we are in a section *) () end
  | "CONSTANT" ->
    let cst = Global.constant_of_delta_kn kn in
    let typ, _ = Environ.constant_type_in_ctx env cst in
    fn (ConstRef cst) env typ
  | "INDUCTIVE" ->
    let mind = Global.mind_of_delta_kn kn in
    let mib = Global.lookup_mind mind in
    let iter_packet i mip =
      let ind = (mind, i) in
      let i = (ind, Univ.Context.instance mib.mind_universes) in
      let typ = Inductiveops.type_of_inductive env i in
      let () = fn (IndRef ind) env typ in
      let len = Array.length mip.mind_user_lc in
      iter_constructors ind fn env len
    in
    Array.iteri iter_packet mib.mind_packets
  | _ -> ()
  in
  try Declaremods.iter_all_segments iter_obj
  with Not_found -> ()

let generic_search = iter_declarations

(* Fine Search. By Yves Bertot. *)

let rec head c =
  let c = strip_outer_cast c in
  match kind_of_term c with
  | Prod (_,_,c) -> head c
  | LetIn (_,_,_,c) -> head c
  | _              -> c

let xor a b = (a || b) && (not (a && b))

(** Standard display *)

let plain_display accu ref a c =
  let pc = pr_lconstr_env a c in
  let pr = pr_global ref in
  accu := hov 2 (pr ++ str":" ++ spc () ++ pc) :: !accu

let format_display l = prlist_with_sep fnl (fun x -> x) (List.rev l)

(** Filters *)

(** This function tries to see whether the conclusion matches a pattern. *)
(** FIXME: this is quite dummy, we may find a more efficient algorithm. *)
let rec pattern_filter pat ref env typ =
  let typ = strip_outer_cast typ in
  if Matching.is_matching pat typ then true
  else match kind_of_term typ with
  | Prod (_, _, typ)
  | LetIn (_, _, _, typ) -> pattern_filter pat ref env typ
  | _ -> false

let full_name_of_reference ref =
  let (dir,id) = repr_path (path_of_global ref) in
  DirPath.to_string dir ^ "." ^ Id.to_string id

(** Whether a reference is blacklisted *)
let blacklist_filter ref env typ =
  let name = full_name_of_reference ref in
  let l = SearchBlacklist.elements () in
  let is_not_bl str = not (String.string_contains ~where:name ~what:str) in
  List.for_all is_not_bl l

let module_filter (mods, outside) ref env typ =
  let sp = path_of_global ref in
  let sl = dirpath sp in
  let is_outside md = not (is_dirpath_prefix_of md sl) in
  let is_inside md = is_dirpath_prefix_of md sl in
  if outside then List.for_all is_outside mods
  else List.is_empty mods || List.exists is_inside mods

let name_of_reference ref = Id.to_string (basename_of_global ref)

let search_about_filter query gr env typ = match query with
| GlobSearchSubPattern pat ->
  Matching.is_matching_appsubterm ~closed:false pat typ
| GlobSearchString s ->
  String.string_contains ~where:(name_of_reference gr) ~what:s


(** SearchPattern *)

let search_pattern pat mods =
  let ans = ref [] in
  let filter ref env typ =
    let f_module = module_filter mods ref env typ in
    let f_blacklist = blacklist_filter ref env typ in
    let f_pattern () = pattern_filter pat ref env typ in
    f_module && f_pattern () && f_blacklist
  in
  let iter ref env typ =
    if filter ref env typ then plain_display ans ref env typ
  in
  let () = generic_search iter in
  format_display !ans

(** SearchRewrite *)

let eq = Coqlib.glob_eq

let rewrite_pat1 pat =
  PApp (PRef eq, [| PMeta None; pat; PMeta None |])

let rewrite_pat2 pat =
  PApp (PRef eq, [| PMeta None; PMeta None; pat |])

let search_rewrite pat mods =
  let pat1 = rewrite_pat1 pat in
  let pat2 = rewrite_pat2 pat in
  let ans = ref [] in
  let filter ref env typ =
    let f_module = module_filter mods ref env typ in
    let f_blacklist = blacklist_filter ref env typ in
    let f_pattern () =
      pattern_filter pat1 ref env typ ||
      pattern_filter pat2 ref env typ
    in
    f_module && f_pattern () && f_blacklist
  in
  let iter ref env typ =
    if filter ref env typ then plain_display ans ref env typ
  in
  let () = generic_search iter in
  format_display !ans

(** Search *)

let search_by_head = search_pattern
(** Now search_by_head is the same as search_pattern... *)

(** SearchAbout *)

let search_about items mods =
  let ans = ref [] in
  let filter ref env typ =
    let eqb b1 b2 = if b1 then b2 else not b2 in
    let f_module = module_filter mods ref env typ in
    let f_about (b, i) = eqb b (search_about_filter i ref env typ) in
    let f_blacklist = blacklist_filter ref env typ in
    f_module && List.for_all f_about items && f_blacklist
  in
  let iter ref env typ =
    if filter ref env typ then plain_display ans ref env typ
  in
  let () = generic_search iter in
  format_display !ans

let interface_search flags =
  let env = Global.env () in
  let rec extract_flags name tpe subtpe mods blacklist = function
  | [] -> (name, tpe, subtpe, mods, blacklist)
  | (Interface.Name_Pattern s, b) :: l ->
    let regexp =
      try Str.regexp s
      with e when Errors.noncritical e ->
        Errors.error ("Invalid regexp: " ^ s)
    in
    extract_flags ((regexp, b) :: name) tpe subtpe mods blacklist l
  | (Interface.Type_Pattern s, b) :: l ->
    let constr = Pcoq.parse_string Pcoq.Constr.lconstr_pattern s in
    let (_, pat) = Constrintern.intern_constr_pattern Evd.empty env constr in
    extract_flags name ((pat, b) :: tpe) subtpe mods blacklist l
  | (Interface.SubType_Pattern s, b) :: l ->
    let constr = Pcoq.parse_string Pcoq.Constr.lconstr_pattern s in
    let (_, pat) = Constrintern.intern_constr_pattern Evd.empty env constr in
    extract_flags name tpe ((pat, b) :: subtpe) mods blacklist l
  | (Interface.In_Module m, b) :: l ->
    let path = String.concat "." m in
    let m = Pcoq.parse_string Pcoq.Constr.global path in
    let (_, qid) = Libnames.qualid_of_reference m in
    let id =
      try Nametab.full_name_module qid
      with Not_found ->
        Errors.error ("Module " ^ path ^ " not found.")
    in
    extract_flags name tpe subtpe ((id, b) :: mods) blacklist l
  | (Interface.Include_Blacklist, b) :: l ->
    extract_flags name tpe subtpe mods b l
  in
  let (name, tpe, subtpe, mods, blacklist) =
    extract_flags [] [] [] [] false flags
  in
  let filter_function ref env constr =
    let id = Names.Id.to_string (Nametab.basename_of_global ref) in
    let path = Libnames.dirpath (Nametab.path_of_global ref) in
    let toggle x b = if x then b else not b in
    let match_name (regexp, flag) =
      toggle (Str.string_match regexp id 0) flag
    in
    let match_type (pat, flag) =
      toggle (Matching.is_matching pat constr) flag
    in
    let match_subtype (pat, flag) =
      toggle (Matching.is_matching_appsubterm ~closed:false pat constr) flag
    in
    let match_module (mdl, flag) =
      toggle (Libnames.is_dirpath_prefix_of mdl path) flag
    in
    let in_blacklist =
      blacklist || (blacklist_filter ref env constr)
    in
    List.for_all match_name name &&
    List.for_all match_type tpe &&
    List.for_all match_subtype subtpe &&
    List.for_all match_module mods && in_blacklist
  in
  let ans = ref [] in
  let print_function ref env constr =
    let fullpath = DirPath.repr (Nametab.dirpath_of_global ref) in
    let qualid = Nametab.shortest_qualid_of_global Id.Set.empty ref in
    let (shortpath, basename) = Libnames.repr_qualid qualid in
    let shortpath = DirPath.repr shortpath in
    (* [shortpath] is a suffix of [fullpath] and we're looking for the missing
       prefix *)
    let rec prefix full short accu = match full, short with
    | _, [] ->
      let full = List.rev_map Id.to_string full in
      (full, accu)
    | _ :: full, m :: short ->
      prefix full short (Id.to_string m :: accu)
    | _ -> assert false
    in
    let (prefix, qualid) = prefix fullpath shortpath [Id.to_string basename] in
    let answer = {
      Interface.coq_object_prefix = prefix;
      Interface.coq_object_qualid = qualid;
      Interface.coq_object_object = string_of_ppcmds (pr_lconstr_env env constr);
    } in
    ans := answer :: !ans;
  in
  let iter ref env typ =
    if filter_function ref env typ then print_function ref env typ
  in
  let () = generic_search iter in
  !ans
