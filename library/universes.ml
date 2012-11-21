(************************************************************************)
(*  v      *   The Coq Proof Assistant  /  The Coq Development Team     *)
(* <O___,, *   INRIA - CNRS - LIX - LRI - PPS - Copyright 1999-2012     *)
(*   \VV/  **************************************************************)
(*    //   *      This file is distributed under the terms of the       *)
(*         *       GNU Lesser General Public License Version 2.1        *)
(************************************************************************)

open Util
open Pp
open Names
open Term
open Sign
open Environ
open Locus
open Univ

(** Fresh levels *)

let new_univ_level =
  let n = ref 0 in 
    fun dp -> incr n; 
      Univ.make_universe_level (dp, !n)

let fresh_level () = new_univ_level (Global.current_dirpath ())

(* TODO: remove *)
let new_univ dp = Univ.make_universe (new_univ_level dp)
let new_Type dp = mkType (new_univ dp)
let new_Type_sort dp = Type (new_univ dp)

let fresh_universe_instance (ctx, _) =
  List.map (fun _ -> fresh_level ()) ctx

let fresh_instance_from_context (vars, cst as ctx) =
  let inst = fresh_universe_instance ctx in
  let subst = List.combine vars inst in
  let constraints = instantiate_univ_context subst ctx in
    (inst, subst), constraints

let fresh_universe_set_instance (ctx, _) =
  List.fold_left (fun s _ -> UniverseLSet.add (fresh_level ()) s) UniverseLSet.empty ctx

let fresh_instance_from (vars, cst as ctx) =
  let ctx' = fresh_universe_set_instance ctx in
  let inst = UniverseLSet.elements ctx' in
  let subst = List.combine vars inst in
  let constraints = instantiate_univ_context subst ctx in
    (inst, subst), (ctx', constraints)

(** Fresh universe polymorphic construction *)

let fresh_constant_instance env c =
  let cb = lookup_constant c env in
    if cb.Declarations.const_polymorphic then
      let (inst,_), ctx = fresh_instance_from cb.Declarations.const_universes in
	((c, inst), ctx)
    else ((c,[]), Univ.empty_universe_context_set)

let fresh_inductive_instance env ind = 
  let mib, mip = Inductive.lookup_mind_specif env ind in
    if mib.Declarations.mind_polymorphic then
      let (inst,_), ctx = fresh_instance_from mib.Declarations.mind_universes in
	((ind,inst), ctx)
    else ((ind,[]), Univ.empty_universe_context_set)

let fresh_constructor_instance env (ind,i) = 
  let mib, mip = Inductive.lookup_mind_specif env ind in
    if mib.Declarations.mind_polymorphic then
      let (inst,_), ctx = fresh_instance_from mib.Declarations.mind_universes in
	(((ind,i),inst), ctx)
    else (((ind,i),[]), Univ.empty_universe_context_set)

open Globnames
let fresh_global_instance env gr =
  match gr with
  | VarRef id -> mkVar id, Univ.empty_universe_context_set
  | ConstRef sp -> 
     let c, ctx = fresh_constant_instance env sp in
       mkConstU c, ctx
  | ConstructRef sp ->
     let c, ctx = fresh_constructor_instance env sp in
       mkConstructU c, ctx
  | IndRef sp -> 
     let c, ctx = fresh_inductive_instance env sp in
       mkIndU c, ctx

let constr_of_global gr =
  let c, ctx = fresh_global_instance (Global.env ()) gr in
    Global.add_constraints (snd ctx); c

open Declarations

let type_of_reference env r =
  match r with
  | VarRef id -> Environ.named_type id env, Univ.empty_universe_context_set
  | ConstRef c ->
     let cb = Environ.lookup_constant c env in
       if cb.const_polymorphic then
	 let (inst, subst), ctx = fresh_instance_from cb.const_universes in
	   subst_univs_constr subst cb.const_type, ctx
       else cb.const_type, Univ.empty_universe_context_set

  | IndRef ind ->
     let (mib, oib) = Inductive.lookup_mind_specif env ind in
       if mib.mind_polymorphic then
	 let (inst, subst), ctx = fresh_instance_from mib.mind_universes in
	   subst_univs_constr subst oib.mind_arity.mind_user_arity, ctx
       else oib.mind_arity.mind_user_arity, Univ.empty_universe_context_set
  | ConstructRef cstr ->
     let (mib,oib as specif) = Inductive.lookup_mind_specif env (inductive_of_constructor cstr) in
       if mib.mind_polymorphic then
	 let (inst, subst), ctx = fresh_instance_from mib.mind_universes in
	   Inductive.type_of_constructor (cstr,inst) specif, ctx
       else Inductive.type_of_constructor (cstr,[]) specif, Univ.empty_universe_context_set

let type_of_global t = type_of_reference (Global.env ()) t

let fresh_sort_in_family env = function
  | InProp -> prop_sort, Univ.empty_universe_context_set
  | InSet -> set_sort, Univ.empty_universe_context_set
  | InType -> 
    let u = fresh_level () in
      Type (Univ.make_universe u), Univ.singleton_universe_context_set u

let new_sort_in_family sf =
  fst (fresh_sort_in_family (Global.env ()) sf)

let extend_context (a, ctx) (ctx') =
  (a, Univ.union_universe_context_set ctx ctx')

let new_global_univ () =
  let u = fresh_level () in
    (Univ.make_universe u, Univ.singleton_universe_context_set u)

(** Simplification *)

module LevelUnionFind = Unionfind.Make (Univ.UniverseLSet) (Univ.UniverseLMap)

let remove_trivial_constraints cst =
  Constraint.fold (fun (l,d,r as cstr) nontriv ->
    if d <> Lt && eq_levels l r then nontriv
    else if d = Le && is_type0_univ (Univ.make_universe l) then nontriv
    else Constraint.add cstr nontriv)
    cst empty_constraint

let add_list_map u t map = 
  let l, d, r = UniverseLMap.split u map in
  let d' = match d with None -> [t] | Some l -> t :: l in
  let lr = 
    UniverseLMap.merge (fun k lm rm -> 
      match lm with Some t -> lm | None ->
      match rm with Some t -> rm | None -> None) l r
  in UniverseLMap.add u d' lr

let find_list_map u map =
  try UniverseLMap.find u map with Not_found -> []

module UF = LevelUnionFind
type universe_full_subst = (universe_level * universe) list

let instantiate_univ_variables uf ucstrsl ucstrsr u (subst, cstrs) =
  try 
    (** The universe variable is already at a fixed level.
	Simply produce the instantiated constraints. *)
    let canon = UF.find u uf in
    let cstrs = 
      let l = find_list_map u ucstrsl in
	List.fold_left (fun cstrs (d, r) -> Constraint.add (canon, d, r) cstrs)
	cstrs l
    in
    let cstrs = 
      let l = find_list_map u ucstrsr in
	List.fold_left (fun cstrs (d, l) -> Constraint.add (l, d, canon) cstrs)
	cstrs l
    in (subst, cstrs)
  with Not_found ->
    (** The universe variable was not fixed yet.
	Compute its level using its lower bound and generate
	the upper bound constraints *)
    let lbound = 
      try
        let r = UniverseLMap.find u ucstrsr in
	let lbound = List.fold_left (fun lbound (d, l) -> 
	    if d = Le (* l <= ?u *) then (sup (make_universe l) lbound)
	    else (* l < ?u *) (assert (d = Lt); (sup (super (make_universe l)) lbound)))
	    type0m_univ r
	in Some lbound
      with Not_found ->
         (** No lower bound, choose the minimal level according to the
	     upper bounds (greatest lower bound), if any.
	 *)
         None
    in
    let uinst, cstrs =
      try 
        let l = UniverseLMap.find u ucstrsl in
	let lbound =
	  match lbound with
	  | None -> make_universe u (** No lower bounds but some upper bounds, u has to stay *)
	  | Some lbound -> lbound
	in
	let cstrs =
	  List.fold_left (fun cstr (d,r) -> 
	    if d = Le (* ?u <= r *) then enforce_leq lbound (make_universe r) cstr
	    else (* ?u < r *) enforce_leq (super lbound) (make_universe r) cstr)
	    cstrs l
	in Some lbound, cstrs
      with Not_found -> lbound, cstrs
    in 
    let subst' = 
      match uinst with
      | None -> subst 
      | Some uinst -> ((u, uinst) :: subst)
    in (subst', cstrs)
  
(** Precondition: flexible <= ctx *)
let choose_canonical ctx flexible s =
  let global = UniverseLSet.diff s ctx in
  let flexible, rigid = UniverseLSet.partition (fun x -> UniverseLSet.mem x flexible) s in
    (** If there is a global universe in the set, choose it *)
    if not (UniverseLSet.is_empty global) then
      let canon = UniverseLSet.choose global in
	canon, (UniverseLSet.remove canon global, rigid, flexible)
    else (** No global in the equivalence class, choose a rigid one *)
	if not (UniverseLSet.is_empty rigid) then
	  let canon = UniverseLSet.choose rigid in
	    canon, (global, UniverseLSet.remove canon rigid, flexible)
	else (** There are only flexible universes in the equivalence
		 class, choose an arbitrary one. *)
	  let canon = UniverseLSet.choose s in
	    canon, (global, rigid, UniverseLSet.remove canon flexible)

let normalize_context_set (ctx, csts) us algs = 
  let uf = UF.create () in
  let noneqs, ucstrsl, ucstrsr = 
    Constraint.fold (fun (l,d,r as cstr) (noneq, ucstrsl, ucstrsr) -> 
      if d = Eq then (UF.union l r uf; (noneq, ucstrsl, ucstrsr)) else
	let lus = UniverseLSet.mem l us 
	and rus = UniverseLSet.mem r us
	in
	let ucstrsl' = 
	  if lus then add_list_map l (d, r) ucstrsl
	  else ucstrsl
	and ucstrsr' = 
	  if rus then add_list_map r (d, l) ucstrsr
	  else ucstrsr
	in 
	let noneqs = 
	  if lus || rus then noneq 
	  else Constraint.add cstr noneq
	in (noneqs, ucstrsl', ucstrsr'))
    csts (empty_constraint, UniverseLMap.empty, UniverseLMap.empty)
  in
  let partition = UF.partition uf in
  let subst, eqs = List.fold_left (fun (subst, cstrs) s -> 
    let canon, (global, rigid, flexible) = choose_canonical ctx us s in
    let cstrs = UniverseLSet.fold (fun g cst -> 
      Constraint.add (canon, Univ.Eq, g) cst) global cstrs 
    in
    (** Should this really happen? *)
    (* let cstrs = UniverseLMap.fold (fun g cst ->  *)
    (*   Constraint.add (canon, Univ.Eq, g) cst) rigid cstrs  *)
    (* in *)
    let subst = List.map (fun f -> (f, canon)) (UniverseLSet.elements (UniverseLSet.union rigid flexible)) @ subst in
      (subst, cstrs))
    ([], Constraint.empty) partition
  in
  (* let subst = List.concat (List.rev_map (fun (c, (global, rigid, flex)) ->  *)
  (*   List.rev_map (fun r -> (r, c)) rs) pcanons) in *)
  let ussubst, noneqs = 
    UniverseLSet.fold (instantiate_univ_variables uf ucstrsl ucstrsr)
      us ([], noneqs)
  in
  let subst, ussubst = 
    let rec aux subst ussubst =
      List.fold_left (fun (subst', usubst') (u, us) -> 
        let us' = subst_univs_universe subst' us in
	  match universe_level us' with
	  | Some l -> ((u, l) :: subst', usubst')
	  | None -> (** Couldn't find a level, keep the universe? *)
	    (subst', (u, us') :: usubst'))
      (subst, []) ussubst
    in 
    (** Normalize the substitution w.r.t. itself so we get only
	fully-substituted, normalized universes as the range of the substitution.
	We don't need to do it for the initial substitution which is canonical
	already. If a canonical universe is equated to a new one by ussubst,
	the 
    *)
    let rec fixpoint subst ussubst = 
      let (subst', ussubst') = aux subst ussubst in
	if ussubst' = [] then subst', ussubst'
	else 
	  let ussubst' = List.rev ussubst' in
	    if ussubst' = ussubst then subst', ussubst'
	    else fixpoint subst' ussubst'
    in fixpoint subst ussubst
  in
  let constraints = remove_trivial_constraints 
    (Constraint.union eqs (subst_univs_constraints subst noneqs))
  in
  let usalg, usnonalg = 
    List.partition (fun (u, _) -> UniverseLSet.mem u algs) ussubst
  in
  let subst = 
    usalg @
    CList.map_filter (fun (u, v) ->
      if eq_levels u v then None
      else Some (u, make_universe v))
      subst
  in
  let ctx' = List.fold_left (fun ctx' (u, _) -> UniverseLSet.remove u ctx') ctx subst in
  let constraints' =
    (** Residual constraints that can't be normalized further. *)
    List.fold_left (fun csts (u, v) -> enforce_leq v (make_universe u) csts)
      constraints usnonalg
  in
    (subst, (ctx', constraints'))
