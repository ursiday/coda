open Core_kernel
open Async_kernel
open Protocols.Coda_pow
open Protocols.Coda_transition_frontier
open Coda_base
open Signature_lib

module type Inputs_intf = sig
  module Staged_ledger_aux_hash : Staged_ledger_aux_hash_intf

  module Ledger_proof_statement :
    Ledger_proof_statement_intf with type ledger_hash := Frozen_ledger_hash.t

  module Ledger_proof : sig
    include
      Ledger_proof_intf
      with type statement := Ledger_proof_statement.t
       and type ledger_hash := Frozen_ledger_hash.t
       and type proof := Proof.t
       and type sok_digest := Sok_message.Digest.t

    include Binable.S with type t := t

    include Sexpable.S with type t := t
  end

  module Transaction_snark_work :
    Transaction_snark_work_intf
    with type proof := Ledger_proof.t
     and type statement := Ledger_proof_statement.t
     and type public_key := Public_key.Compressed.t

  module Staged_ledger_diff :
    Staged_ledger_diff_intf
    with type user_command := User_command.t
     and type user_command_with_valid_signature :=
                User_command.With_valid_signature.t
     and type staged_ledger_hash := Staged_ledger_hash.t
     and type public_key := Public_key.Compressed.t
     and type completed_work := Transaction_snark_work.t
     and type completed_work_checked := Transaction_snark_work.Checked.t
     and type fee_transfer_single := Fee_transfer.single

  module External_transition :
    External_transition.S
    with module Protocol_state = Consensus.Mechanism.Protocol_state
     and module Staged_ledger_diff := Staged_ledger_diff

  module Staged_ledger :
    Staged_ledger_intf
    with type diff := Staged_ledger_diff.t
     and type valid_diff :=
                Staged_ledger_diff.With_valid_signatures_and_proofs.t
     and type staged_ledger_hash := Staged_ledger_hash.t
     and type staged_ledger_aux_hash := Staged_ledger_aux_hash.t
     and type ledger_hash := Ledger_hash.t
     and type frozen_ledger_hash := Frozen_ledger_hash.t
     and type public_key := Public_key.Compressed.t
     and type ledger := Ledger.t
     and type ledger_proof := Ledger_proof.t
     and type user_command_with_valid_signature :=
                User_command.With_valid_signature.t
     and type statement := Transaction_snark_work.Statement.t
     and type completed_work_checked := Transaction_snark_work.Checked.t
     and type sparse_ledger := Sparse_ledger.t
     and type ledger_proof_statement := Ledger_proof_statement.t
     and type ledger_proof_statement_set := Ledger_proof_statement.Set.t
     and type transaction := Transaction.t
     and type user_command := User_command.t
end

module Make (Inputs : Inputs_intf) :
  Transition_frontier_intf
  with type state_hash := State_hash.t
   and type external_transition_verified :=
              Inputs.External_transition.Verified.t
   and type ledger_database := Ledger.Db.t
   and type staged_ledger_diff := Inputs.Staged_ledger_diff.t
   and type staged_ledger := Inputs.Staged_ledger.t
   and type masked_ledger := Ledger.Mask.Attached.t
   and type transaction_snark_scan_state := Inputs.Staged_ledger.Scan_state.t =
struct
  (* NOTE: is Consensus_mechanism.select preferable over distance? *)
  exception
    Parent_not_found of ([`Parent of State_hash.t] * [`Target of State_hash.t])

  exception Already_exists of State_hash.t

  module Breadcrumb = struct
    (* TODO: external_transition should be type : External_transition.With_valid_protocol_state.t #1344 *)
    type t =
      { transition_with_hash:
          (Inputs.External_transition.Verified.t, State_hash.t) With_hash.t
      ; staged_ledger: Inputs.Staged_ledger.t sexp_opaque }
    [@@deriving sexp, fields]

    let create transition_with_hash staged_ledger =
      {transition_with_hash; staged_ledger}

    let build ~logger ~parent ~transition_with_hash =
      O1trace.measure "Breadcrumb.build" (fun () ->
          let open Deferred.Result.Let_syntax in
          let logger = Logger.child logger __MODULE__ in
          let staged_ledger = parent.staged_ledger in
          let transition = With_hash.data transition_with_hash in
          let transition_protocol_state =
            Inputs.External_transition.Verified.protocol_state transition
          in
          let ledger_hash_from_proof p =
            Inputs.Ledger_proof.statement_target
              (Inputs.Ledger_proof.statement p)
          in
          let blockchain_state_ledger_hash, blockchain_staged_ledger_hash =
            let blockchain_state =
              Consensus.Mechanism.Protocol_state.blockchain_state
                transition_protocol_state
            in
            ( Consensus.Mechanism.Blockchain_state.ledger_hash blockchain_state
            , Consensus.Mechanism.Blockchain_state.staged_ledger_hash
                blockchain_state )
          in
          let%bind ( `Hash_after_applying staged_ledger_hash
                   , `Ledger_proof proof_opt
                   , `Staged_ledger transitioned_staged_ledger ) =
            let open Deferred.Let_syntax in
            match%map
              Inputs.Staged_ledger.apply ~logger staged_ledger
                (Inputs.External_transition.Verified.staged_ledger_diff
                   transition)
            with
            | Ok x -> Ok x
            | Error (Inputs.Staged_ledger.Staged_ledger_error.Unexpected e) ->
                Error (`Fatal_error (Error.to_exn e))
            | Error e ->
                Error
                  (`Validation_error
                    (Error.of_string
                       (Inputs.Staged_ledger.Staged_ledger_error.to_string e)))
          in
          let target_ledger_hash =
            match proof_opt with
            | None ->
                Option.value_map
                  (Inputs.Staged_ledger.current_ledger_proof
                     transitioned_staged_ledger)
                  ~f:ledger_hash_from_proof
                  ~default:
                    (Frozen_ledger_hash.of_ledger_hash
                       (Ledger.merkle_root Genesis_ledger.t))
            | Some proof -> ledger_hash_from_proof proof
          in
          let%map transitioned_staged_ledger =
            if
              Frozen_ledger_hash.equal target_ledger_hash
                blockchain_state_ledger_hash
              && Staged_ledger_hash.equal staged_ledger_hash
                   blockchain_staged_ledger_hash
            then return transitioned_staged_ledger
            else
              Deferred.return
                (Error
                   (`Validation_error
                     (Error.of_string
                        "Snarked ledger hash and Staged ledger hash after \
                         applying the diff does not match blockchain state's \
                         ledger hash and staged ledger hash resp.\n")))
          in
          {transition_with_hash; staged_ledger= transitioned_staged_ledger} )

    let hash {transition_with_hash; _} = With_hash.hash transition_with_hash

    let parent_hash {transition_with_hash; _} =
      Consensus.Mechanism.Protocol_state.previous_state_hash
        (Inputs.External_transition.Verified.protocol_state
           (With_hash.data transition_with_hash))
  end

  type node =
    {breadcrumb: Breadcrumb.t; successor_hashes: State_hash.t list; length: int}
  [@@deriving sexp]

  (* Invariant: The path from the root to the tip inclusively, will be max_length + 1 *)
  (* TODO: Make a test of this invariant *)
  type t =
    { root_snarked_ledger: Ledger.Db.t
    ; mutable root: State_hash.t
    ; mutable best_tip: State_hash.t
    ; logger: Logger.t
    ; table: node State_hash.Table.t
    ; max_length: int }

  let logger t = t.logger

  (* TODO: load from and write to disk *)
  let create ~logger
      ~(root_transition :
         (Inputs.External_transition.Verified.t, State_hash.t) With_hash.t)
      ~root_snarked_ledger ~root_transaction_snark_scan_state
      ~root_staged_ledger_diff ~max_length =
    let open Consensus.Mechanism in
    let open Deferred.Let_syntax in
    let logger = Logger.child logger __MODULE__ in
    let root_hash = With_hash.hash root_transition in
    let root_protocol_state =
      Inputs.External_transition.Verified.protocol_state
        (With_hash.data root_transition)
    in
    let root_blockchain_state =
      Protocol_state.blockchain_state root_protocol_state
    in
    let root_blockchain_state_ledger_hash, root_blockchain_staged_ledger_hash =
      ( Protocol_state.Blockchain_state.ledger_hash root_blockchain_state
      , Protocol_state.Blockchain_state.staged_ledger_hash
          root_blockchain_state )
    in
    assert (
      Ledger_hash.equal
        (Ledger.Db.merkle_root root_snarked_ledger)
        (Frozen_ledger_hash.to_ledger_hash root_blockchain_state_ledger_hash)
    ) ;
    let root_masked_ledger = Ledger.of_database root_snarked_ledger in
    let root_snarked_ledger_hash =
      Frozen_ledger_hash.of_ledger_hash
      @@ Ledger.merkle_root (Ledger.of_database root_snarked_ledger)
    in
    (* Only check this case after the genesis block *)
    if not @@ State_hash.equal genesis_protocol_state.hash root_hash then
      [%test_result: Ledger_hash.t]
        ~message:
          "Staged-ledger's ledger hash different from implied merkle root of \
           this masked ledger"
        ~expect:
          (Staged_ledger_hash.ledger_hash
             (Protocol_state.Blockchain_state.staged_ledger_hash
                root_blockchain_state))
        (Ledger.Mask.Attached.merkle_root root_masked_ledger) ;
    match%bind
      Inputs.Staged_ledger.of_scan_state_and_ledger
        ~scan_state:root_transaction_snark_scan_state
        ~ledger:root_masked_ledger
        ~snarked_ledger_hash:root_snarked_ledger_hash
    with
    | Error e -> failwith (Error.to_string_hum e)
    | Ok pre_root_staged_ledger ->
        let open Deferred.Let_syntax in
        let%map root_staged_ledger =
          match root_staged_ledger_diff with
          | None -> return pre_root_staged_ledger
          | Some diff -> (
              match%map
                Inputs.Staged_ledger.apply pre_root_staged_ledger diff ~logger
              with
              | Error e ->
                  failwith
                    (Inputs.Staged_ledger.Staged_ledger_error.to_string e)
              | Ok
                  ( `Hash_after_applying staged_ledger_hash
                  , `Ledger_proof None
                  , `Staged_ledger transitioned_staged_ledger ) ->
                  assert (
                    Staged_ledger_hash.equal root_blockchain_staged_ledger_hash
                      staged_ledger_hash ) ;
                  transitioned_staged_ledger
              | Ok (_, `Ledger_proof (Some _), _) ->
                  failwith
                    "Did not expect a ledger proof after applying the first \
                     diff" )
        in
        let root_breadcrumb =
          { Breadcrumb.transition_with_hash= root_transition
          ; staged_ledger= root_staged_ledger }
        in
        let root_node =
          {breadcrumb= root_breadcrumb; successor_hashes= []; length= 0}
        in
        let table = State_hash.Table.of_alist_exn [(root_hash, root_node)] in
        { logger
        ; root_snarked_ledger
        ; root= root_hash
        ; best_tip= root_hash
        ; table
        ; max_length }

  let max_length {max_length; _} = max_length

  let all_breadcrumbs t =
    List.map (Hashtbl.data t.table) ~f:(fun {breadcrumb; _} -> breadcrumb)

  let find t hash =
    let open Option.Let_syntax in
    let%map node = Hashtbl.find t.table hash in
    node.breadcrumb

  let find_exn t hash =
    let node = Hashtbl.find_exn t.table hash in
    node.breadcrumb

  let path_map t breadcrumb ~f =
    let rec find_path b =
      let elem = f b in
      let parent_hash = Breadcrumb.parent_hash b in
      if State_hash.equal parent_hash t.root then [elem]
      else elem :: find_path (find_exn t parent_hash)
    in
    List.rev (find_path breadcrumb)

  let hash_path t breadcrumb = path_map t breadcrumb ~f:Breadcrumb.hash

  let iter t ~f = Hashtbl.iter t.table ~f:(fun n -> f n.breadcrumb)

  let root t = find_exn t t.root

  let best_tip t = find_exn t t.best_tip

  let successor_hashes t hash =
    let node = Hashtbl.find_exn t.table hash in
    node.successor_hashes

  let rec successor_hashes_rec t hash =
    List.bind (successor_hashes t hash) ~f:(fun succ_hash ->
        succ_hash :: successor_hashes_rec t succ_hash )

  let successors t breadcrumb =
    List.map (successor_hashes t (Breadcrumb.hash breadcrumb)) ~f:(find_exn t)

  let rec successors_rec t breadcrumb =
    List.bind (successors t breadcrumb) ~f:(fun succ ->
        succ :: successors_rec t succ )

  let attach_node_to t ~parent_node ~node =
    let hash = Breadcrumb.hash node.breadcrumb in
    if
      not
        (State_hash.equal
           (Breadcrumb.hash parent_node.breadcrumb)
           (Breadcrumb.parent_hash node.breadcrumb))
    then
      failwith
        "invalid call to attach_to: hash parent_node <> parent_hash node" ;
    if Hashtbl.add t.table ~key:hash ~data:node <> `Ok then
      Logger.warn t.logger
        !"attach_node_to with breadcrumb for state %{sexp:State_hash.t} \
          already present; catchup scheduler bug?"
        hash
    else
      Hashtbl.set t.table
        ~key:(Breadcrumb.hash parent_node.breadcrumb)
        ~data:
          { parent_node with
            successor_hashes= hash :: parent_node.successor_hashes }

  let attach_breadcrumb_exn t breadcrumb =
    let hash = Breadcrumb.hash breadcrumb in
    let parent_hash = Breadcrumb.parent_hash breadcrumb in
    let parent_node =
      Option.value_exn
        (Hashtbl.find t.table parent_hash)
        ~error:
          (Error.of_exn (Parent_not_found (`Parent parent_hash, `Target hash)))
    in
    let node =
      {breadcrumb; successor_hashes= []; length= parent_node.length + 1}
    in
    attach_node_to t ~parent_node ~node

  (* Adding a breadcrumb to the transition frontier is broken into the following steps:
   *   1) attach the breadcrumb to the transition frontier
   *   2) move the root if the path to the new node is longer than the max length
   *     a) calculate the distance from the new node to the parent
   *     b) if the distance is greater than the max length:
   *       I  ) find the immediate successor of the old root in the path to the
   *            longest node and make it the new root
   *       II ) find all successors of the other immediate successors of the old root
   *       III) remove the old root and all of the nodes found in (II) from the table
   *       IV ) merge the old root's merkle mask into the root ledger
   *   3) set the new node as the best tip if the new node has a greater length than
   *      the current best tip
   *)
  let add_breadcrumb_exn t breadcrumb =
    O1trace.measure "add_breadcrumb" (fun () ->
        let hash =
          With_hash.hash (Breadcrumb.transition_with_hash breadcrumb)
        in
        let root_node = Hashtbl.find_exn t.table t.root in
        let best_tip_node = Hashtbl.find_exn t.table t.best_tip in
        (* 1 *)
        attach_breadcrumb_exn t breadcrumb ;
        let node = Hashtbl.find_exn t.table hash in
        (* 2.a *)
        let distance_to_parent = node.length - root_node.length in
        (* 2.b *)
        if distance_to_parent > max_length t then (
          (* 2.b.I *)
          let new_root_hash = List.hd_exn (hash_path t node.breadcrumb) in
          (* 2.b.II *)
          let garbage_immediate_successors =
            List.filter root_node.successor_hashes ~f:(fun succ_hash ->
                not (State_hash.equal succ_hash new_root_hash) )
          in
          (* 2.b.III *)
          let garbage =
            t.root
            :: List.bind garbage_immediate_successors
                 ~f:(successor_hashes_rec t)
          in
          t.root <- new_root_hash ;
          List.iter garbage ~f:(Hashtbl.remove t.table) ;
          (* 2.b.IV *)
          Ledger.Mask.Attached.commit
            (Inputs.Staged_ledger.ledger
               (Breadcrumb.staged_ledger root_node.breadcrumb)) ) ;
        (* 3 *)
        if node.length > best_tip_node.length then t.best_tip <- hash )

  let clear_paths t = Hashtbl.clear t.table

  let best_tip_path_length_exn {table; root; best_tip; _} =
    let open Option.Let_syntax in
    let result =
      let%bind best_tip_node = Hashtbl.find table best_tip in
      let%map root_node = Hashtbl.find table root in
      best_tip_node.length - root_node.length
    in
    result |> Option.value_exn

  module For_tests = struct
    let root_snarked_ledger {root_snarked_ledger; _} = root_snarked_ledger
  end
end

let%test_module "Transition_frontier tests" =
  ( module struct
    (*
  let%test "transitions can be added and interface will work at any point" =

    let module Frontier = Make (struct
      module State_hash = Test_mocks.Hash.Int_unchecked
      module External_transition = Test_mocks.External_transition.T
      module Max_length = struct
        let length = 5
      end
    end) in
    let open Frontier in
    let t = create ~log:(Logger.create ()) in

    (* test that functions that shouldn't throw exceptions don't *)
    let interface_works () =
      let r = root t in
      ignore (best_tip t);
      ignore (successor_hashes_rec r);
      ignore (successors_rec r);
      iter t ~f:(fun b ->
          let h = Breadcrumb.hash b in
          find_exn t h;
          ignore (successor_hashes t h)
          ignore (successors t b))
    in

    (* add a single random transition based off a random node *)
    let add_transition () =
      let base_hash = List.head_exn (List.shuffle (hashes t)) in
      let trans = Quickcheck.random_value (External_transition.gen base_hash) in
      add_exn t trans
    in

    interface_works ();
    for i = 1 to 200 do
      add_transition ();
      interface_works ()
    done
     *)
  
  end )
