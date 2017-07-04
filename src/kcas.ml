(*
########
Copyright (c) 2017, Nicolas ASSOUAD <nicolas.assouad@ens.fr>
########
*)

open Printf;;

module type Backoff = Kcas_backoff.S;;
module Backoff = Kcas_backoff.M;;

type 'a state =
  |WORD : 'a -> 'a state
  |RDCSS_DESC : 'a rdcss_t -> 'a state
  |CASN_DESC : casn_t -> 'a state
and 'a ref = 'a state Pervasives.ref
and t = CAS : 'a ref * 'a state * 'a state -> t
and status = |UNDECIDED |FAILED |SUCCEEDED
and 'a rdcss_t = {
  a1 : status ref;
  o1 : status state;
  a2 : 'a ref;
  o2 : 'a state;
  n2 : 'a state;
  id_rdcss : int;
}
and casn_t = {
  st : status ref;
  c_l : t list;
  id_casn : int;
}
and 'a cas_result =
  |Aborted
  |Failed
  |Success of 'a
;;

let compare_and_swap r x y =
  Obj.compare_and_swap_field (Obj.repr r) 0 (Obj.repr x) (Obj.repr y)
;;

let ref a = Pervasives.ref (WORD(a));;

let equal r1 r2 = (Obj.repr r1) == (Obj.repr r2);;

let is_on_ref (CAS(r1, _, _)) r2 = equal r1 r2;;

let mk_cas a o n = CAS(a, WORD(o), WORD(n));;

let mk_rdcss a1 o1 a2 o2 n2 = {
  a1 = a1;
  o1 = o1;
  a2 = a2;
  o2 = o2;
  n2 = n2;
  id_rdcss = Oo.id (object end);
};;

let mk_casn st c_l = {
  st = st;
  c_l = c_l;
  id_casn = Oo.id (object end);
};;

let rec st_eq s s' =
  match s, s' with
  |WORD(x), WORD(x') -> x == x'
  |RDCSS_DESC(r), RDCSS_DESC(r') -> r.id_rdcss == r'.id_rdcss
  |CASN_DESC(c), CASN_DESC(c') -> c.id_casn == c'.id_casn
  |_ -> false
;;

let commit (CAS (r, expect, update)) =
  let s = !r in
  st_eq s expect && compare_and_swap r s update
;;

let cas r e u = commit (mk_cas r e u);;

let set r n = r := WORD(n);;

let rec rdcss rd =
  if commit (CAS(rd.a2, rd.o2, RDCSS_DESC(rd))) then begin
    ignore @@ complete rd; rd.o2
  end else
    let r = !(rd.a2) in
    match r with
    |RDCSS_DESC(rd') -> ignore @@ complete rd'; rdcss rd
    |_ -> if st_eq r rd.o2 then
            rdcss rd
          else
            r
and complete rd =
  if st_eq !(rd.a1) rd.o1 then
    commit (CAS(rd.a2, RDCSS_DESC(rd), rd.n2))
  else
    commit (CAS(rd.a2, RDCSS_DESC(rd), rd.o2))
;;

let rec rdcss_read a =
  let r = !a in
  match r with
  |RDCSS_DESC(rd) -> ignore @@ complete rd; rdcss_read a
  |_ -> r
;;

let rec casn_proceed c =
  let rec phase1 curr_c_l curr_st out =
    match curr_c_l with
    |(CAS(a, o, n))::curr_c_t_tail when curr_st = SUCCEEDED -> begin
      let s = rdcss (mk_rdcss c.st (WORD(UNDECIDED)) a o (CASN_DESC(c))) in
      match s with
      |CASN_DESC(c') ->
        if c.id_casn != c'.id_casn then begin
          ignore @@ casn_proceed c'; phase1 curr_c_l curr_st out
        end else
          phase1 curr_c_t_tail curr_st (CAS(a, o, n)::out)
      |_ ->
        if st_eq s o then
          phase1 curr_c_t_tail curr_st (CAS(a, o, n)::out)
        else
          phase1 curr_c_t_tail FAILED (CAS(a, o, n)::out)
    end
    |_ -> ignore @@ commit (CAS(c.st, (WORD(UNDECIDED)), (WORD(curr_st)))); out
  in
  let rec phase2 curr_c_l succ =
    match curr_c_l with
    |(CAS(a, o, n))::curr_c_l_tail -> begin
       match !succ with
       |WORD(SUCCEEDED) -> ignore @@ commit (CAS(a, CASN_DESC(c), n)); phase2 curr_c_l_tail succ
       |_ -> ignore @@ commit (CAS(a, CASN_DESC(c), o)); phase2 curr_c_l_tail succ
    end
    |_ -> !succ = WORD(SUCCEEDED)
  in
  match !(c.st) with
  |WORD(UNDECIDED) -> phase2 (phase1 c.c_l SUCCEEDED []) c.st
  |_ -> phase2 c.c_l c.st
;;

let rec get a =
  let r = rdcss_read a in
  match r with
  |CASN_DESC(c) -> ignore @@ casn_proceed c; get a
  |WORD(out) -> out
  |_ -> assert false
;;

let bad_kcas_value = -16;;

let rec kcas_with_tsx l =
  match l with
  |(CAS(r, o, n))::t -> begin
    match !r with
    |WORD(_) as v ->
      if st_eq v o then begin
        r := n;
        kcas_with_tsx t
      end else
        fallback bad_kcas_value
    |_ -> fallback 0
  end
  |[] -> ()
;;

let kcas_without_tsx c_l =
  match c_l with
  |[] -> true
  |[CAS(r, o, n) as c] -> ignore @@ get r; commit c
  |_ -> casn_proceed (mk_casn (ref UNDECIDED) c_l)
;;

let kCAS l =
  atomically
    (fun () -> kcas_with_tsx l)
    (fun s -> if s <> bad_kcas_value then kcas_without_tsx l)
;;

let try_map r f =
  let c = get r in
  match f c with
  |None -> Aborted
  |Some(v) -> if kCAS [mk_cas r c v] then Success(c) else Failed
;;

let map r f =
  let b = Backoff.create () in
  let rec loop () =
    match try_map r f with
    |Failed -> Backoff.once b; loop ()
    |out -> out
  in loop ()
;;

let incr r = ignore @@ map r (fun i -> Some(i+1));;

let decr r = ignore @@ map r (fun i -> Some(i-1));;


module type W1 = sig
  type 'a ref;;
  val ref : 'a -> 'a ref;;
  val get : 'a ref -> 'a;;
  val set : 'a ref -> 'a -> unit;;
  val cas : 'a ref -> 'a -> 'a -> bool;;
  val try_map : 'a ref -> ('a -> 'a option) -> 'a cas_result;;
  val map : 'a ref -> ('a -> 'a option) -> 'a cas_result;;
  val incr : int ref -> unit;;
  val decr : int ref -> unit;;
end

module W1 : W1 = struct
  type 'a ref = 'a Pervasives.ref;;
  let ref = Pervasives.ref;;
  let get = Pervasives.(!);;
  let set r n = r := n;;
  let cas = compare_and_swap;;

  let try_map r f =
    let s = get r in
    match f s with
    |None -> Aborted
    |Some v -> if cas r s v then Success(s) else Failed
  ;;

  let map r f =
    let b = Backoff.create () in
    let rec loop () =
      match try_map r f with
      | Failed -> Backoff.once b; loop ()
      | v -> v
    in loop ()
  ;;

  let incr r = ignore @@ map r (fun x -> Some(x+1));;
  let decr r = ignore @@ map r (fun x -> Some(x-1));;
end
