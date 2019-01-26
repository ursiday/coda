(* masking_merkle_tree_intf.ml *)
(* the type of a Merkle tree mask associated with a parent Merkle tree *)
module type S = sig
  type t [@@deriving bin_io]

  type unattached = t

  type parent

  type account

  type location

  type hash

  type key

  type key_set

  module Location : Merkle_ledger.Location_intf.S

  module Addr = Location.Addr

  val create : unit -> t
  (** create a mask with no parent *)

  module Attached : sig
    include
      Base_merkle_tree_intf.S
      with module Addr = Addr
      with module Location = Location
      with type account := account
       and type root_hash := hash
       and type hash := hash
       and type key := key
       and type key_set := key_set

    val get_hash : t -> Addr.t -> hash option
    (** get hash from mask, if present, else from its parent *)

    val commit : t -> unit
    (** commit all state to the parent, flush state locally *)

    val unset_parent : t -> unattached
    (** remove parent *)

    val get_parent : t -> parent
    (** get mask parent *)

    val parent_set_notify : t -> location -> account -> unit
    (** called when parent sets an account; update local state *)

    val copy : t -> t
    (* makes new mask instance with copied tables, re-use parent *)

    (** already have module For_testing from include above *)
    module For_testing : sig
      val location_in_mask : t -> location -> bool

      val address_in_mask : t -> Addr.t -> bool

      val current_location : t -> Location.t option
    end
  end

  val set_parent : unattached -> parent -> Attached.t
  (** tell mask about parent *)
end
