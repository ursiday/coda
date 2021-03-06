open Core
open Fold_lib
open Tuple_lib
open Snark_params.Tick

type t [@@deriving bin_io, sexp, eq, compare, hash]

include Hashable_binable with type t := t

type var

val typ : (var, t) Typ.t

val var_to_triples : var -> (Boolean.var Triple.t list, _) Checked.t

val length_in_triples : int

val fold : t -> bool Triple.t Fold.t

module Stable : sig
  module V1 : sig
    type nonrec t = t [@@deriving bin_io, sexp, eq, compare, hash]

    include Hashable_binable with type t := t
  end
end

val dummy : t

module Aux_hash : sig
  type t

  module Stable : sig
    module V1 : sig
      type nonrec t = t [@@deriving bin_io, sexp, eq, compare, hash]
    end
  end

  val of_bytes : string -> t

  val to_bytes : t -> string

  val dummy : t
end

val ledger_hash : t -> Ledger_hash.t

val aux_hash : t -> Aux_hash.t

val of_aux_and_ledger_hash : Aux_hash.t -> Ledger_hash.t -> t

val to_string : t -> string
