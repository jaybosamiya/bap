open Bap.Std
open Core_kernel.Std

type truth_format = [
  | `unstripped_bin
  | `symbol_file ]


let format_of_filename f =
  if Filename.check_suffix f ".scm" then `symbol_file
  else `unstripped_bin

let of_truth truth ~testbin : addr seq Or_error.t =
  match format_of_filename truth with
  | `unstripped_bin -> Ground_truth.from_unstripped_bin truth
  | `symbol_file -> Ground_truth.from_symbol_file truth ~testbin

type tool = BW | Ida of string*bool
let tool_name tool = match tool with
  | BW -> "bap-byteweight"
  | Ida _ -> "ida" (* TODO Check this again *)

let of_tool tool ~testbin : addr seq Or_error.t =
  match tool with
  | BW ->
    Find_starts.with_byteweight testbin
  | Ida (ida_path, is_headless) ->
    Find_starts.with_ida ~ida_path ~is_headless testbin
