open Bap.Std
open Core_kernel.Std


(** [with_ida ~ida_path ~is_headless testbin] evaluates the IDA on the
    binary [testbin], and returns the function start address sequence *)
val with_ida:
  ida_path:string -> is_headless:bool -> string -> addr seq Or_error.t

(** [with_byteweight testbin] evaluates bap-byteweight on the binary
    [testbin], and returns the function start address sequence *)
val with_byteweight: string -> addr seq Or_error.t
