open Bap.Std
open Core_kernel.Std
open Cmdliner

(** [of_truth truth ~testbin] given the test binary [testbin], returns
    the function start address sequence from ground truth [truth] *)
val of_truth: string -> testbin:string -> addr seq Or_error.t

type tool = BW | Ida of string*bool
val tool_name : tool -> string

(** [of_tool tool] returns the function start address sequence from
    [tool] *)
val of_tool: tool -> testbin:string -> addr seq Or_error.t
