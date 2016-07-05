open Core_kernel.Std
open Bap_bundle.Std
open Bap_future.Std
open Bap_plugins.Std
open Format
open Cmdliner

module Event = Bap_event

module CmdlineGrammar : sig
  (** [plugin_help name info g] takes a grammar [g] and returns a new
      grammar that accepts help for [name] and creates a manpage using
      [info]. *)
  val plugin_help : string -> Term.info -> unit Term.t -> unit Term.t

  (** [add grammar] adds a grammar to the global grammar which will
      be used by the front end. *)
  val add : unit Term.t -> unit
end = struct

  let global = ref Term.(const ())

  let plugin_help plugin_name terminfo grammar : unit Term.t =
    let formats = List.map ~f:(fun x -> x,x) ["pager"; "plain"; "groff"] in
    let name = plugin_name ^ "-help" in
    let doc = "Show help for " ^
              plugin_name ^
              " plugin in format $(docv), (pager, plain or groff)" in
    let help = Arg.(value @@
                    opt ~vopt:(Some "pager") (some (enum formats)) None @@
                    info [name] ~doc ~docv:"FMT") in
    Term.(const (fun h () ->
        match h with
        | None -> ()
        | Some v ->
          match eval ~argv:[|plugin_name;
                             "--help";
                             v
                           |] (grammar, terminfo) with
          | `Error _ -> exit 1
          | `Ok _ -> assert false
          | `Version -> assert false
          | `Help -> exit 0
      ) $ help $ grammar)

  let add g =
    let combine = Term.const (fun () () -> ()) in
    global := Term.(combine $ g $ (!global))

end

module Create() = struct
  let bundle = main_bundle ()

  let main =
    let base = Filename.basename Sys.executable_name in
    try Filename.chop_extension base with _ -> base


  let manifest =
    try Bundle.manifest bundle
    with exn -> Manifest.create main

  let name = Manifest.name manifest
  let version = Manifest.version manifest
  let doc = Manifest.desc manifest

  let is_plugin =
    name <> main

  let has_verbose =
    Array.exists ~f:(function "--verbose" | _ -> false)

  let filter_args name =
    let prefix = "--" ^ name ^ "-" in
    let is_key = String.is_prefix ~prefix:"-" in
    Array.fold Sys.argv ~init:([],`drop) ~f:(fun (args,act) arg ->
        let take arg = (prefix ^ arg) :: args in
        if arg = Sys.argv.(0) then (name::args,`drop)
        else match String.chop_prefix arg ~prefix, act with
          | None,`take when is_key arg -> args,`drop
          | None,`take -> arg::args,`drop
          | None,`drop -> args,`drop
          | Some arg,_ when String.mem arg '=' -> take arg,`drop
          | Some arg,_ -> take arg,`take) |>
    fst |> List.rev |> Array.of_list

  let argv =
    if name = main then Sys.argv
    else filter_args name

  let has_var v = match Sys.getenv ("BAP_" ^ String.uppercase v) with
    | exception Not_found -> false
    | "false" | "0" -> false
    | _ -> true

  let is_verbose = has_verbose argv ||
                   has_var ("DEBUG_"^name) ||
                   has_var ("DEBUG")

  open Event.Log

  let debug = (); match is_verbose with
    | false -> fun fmt -> ifprintf std_formatter fmt
    | true ->  fun fmt -> message Debug ~section:name fmt

  let info f = message Info ~section:name f
  let warning f = message Warning ~section:name f
  let error f = message Error ~section:name f

  module Config = struct
    let plugin_name = name
    let executable_name = main
    include Bap_config

    (* Discourage access to directories of other plugins *)
    let confdir =
      if is_plugin then
        let (/) = Filename.concat in
        confdir / plugin_name
      else confdir

    type 'a param = 'a future
    type 'a parser = string -> [ `Ok of 'a | `Error of string ]
    type 'a printer = Format.formatter -> 'a -> unit

    module Converter = struct
      type 'a t = {
        parser : 'a parser;
        printer : 'a printer;
        default : 'a;
      }

      let t parser printer default : 'a t = {parser; printer; default}
      let to_arg conv : 'a Arg.converter = conv.parser, conv.printer
      let default conv = conv.default

      let deprecation_wrap ~converter ?deprecated ~name =
        let warn_if_deprecated () =
          match deprecated with
          | Some msg ->
            if is_plugin then
              eprintf "WARNING: %S option of plugin %S is deprecated. %s\n"
                name plugin_name msg
            else eprintf "WARNING: %S option is deprecated. %s\n"
                name msg
          | None -> () in
        {converter with parser=(fun s -> warn_if_deprecated ();
                                 converter.parser s)}

      let of_arg (conv:'a Arg.converter) (default:'a) : 'a t =
        let parser, printer = conv in
        t parser printer default
    end

    type 'a converter = 'a Converter.t
    let converter = Converter.t

    let deprecated =
      if is_plugin then "Please refer to --" ^ plugin_name ^ "-help"
      else "Please refer to --help."

    let main = ref Term.(const ())

    let conf_file_options : (string, string) List.Assoc.t =
      let conf_filename =
        let (/) = Filename.concat in
        Bap_config.confdir / "config" in
      let string_splitter str =
        let str = String.strip str in
        match String.split str ~on:'=' with
        | k :: _ when String.prefix k 1 = "#" -> None
        | [""] | [] -> None
        | [k] -> invalid_argf
                   "Maybe comment out %S using # in config file?" k ()
        | k :: vs -> Some (String.strip k,
                           String.strip (String.concat ~sep:"=" vs)) in
      let split_filter = List.filter_map ~f:string_splitter in
      try
        In_channel.with_file
          conf_filename ~f:(fun ch -> In_channel.input_lines ch
                                      |> split_filter)
      with Sys_error _ -> []

    let get_from_conf_file name =
      List.Assoc.find conf_file_options ~equal:String.Caseless.equal name

    let get_from_env name =
      let name = if is_plugin then plugin_name ^ "_" ^ name else name in
      let name = String.uppercase (executable_name ^ "_" ^ name) in
      try
        Some (Sys.getenv name)
      with Not_found -> None

    let get_param ~(converter) ~default ~name =
      let value = default in
      let str = get_from_conf_file name in
      let str = match get_from_env name with
        | Some _ as v -> v
        | None -> str in
      let parse str =
        let parse, _ = converter in
        match parse str with
        | `Error err ->
          invalid_argf "Could not parse %S for parameter %S: %s"
            str name err ()
        | `Ok v -> v in
      let value = match str with
        | Some v -> parse v
        | None -> value in
      value

    let check_deprecated doc deprecated =
      match deprecated with
      | Some _ -> "DEPRECATED. " ^ doc
      | None -> doc

    let complete_param name =
      if is_plugin then plugin_name ^ "-" ^ name
      else name

    let param converter ?deprecated ?default ?as_flag ?(docv="VAL")
        ?(doc="Undocumented") ?(synonyms=[]) name =
      let name = complete_param name in
      let converter = Converter.deprecation_wrap
          ~converter ?deprecated ~name in
      let doc = check_deprecated doc deprecated in
      let future, promise = Future.create () in
      let default =
        match default with
        | Some x -> x
        | None -> Converter.default converter in
      let converter = Converter.to_arg converter in
      let param = get_param ~converter ~default ~name in
      let t =
        Arg.(value
             @@ opt ?vopt:as_flag converter param
             @@ info (name::synonyms) ~doc ~docv) in
      main := Term.(const (fun x () ->
          Promise.fulfill promise x) $ t $ (!main));
      future

    let param_all (converter:'a converter) ?deprecated ?(default=[]) ?as_flag
        ?(docv="VAL") ?(doc="Uncodumented") ?(synonyms=[]) name : 'a list param =
      let name = complete_param name in
      let converter = Converter.deprecation_wrap
          ~converter ?deprecated ~name in
      let doc = check_deprecated doc deprecated in
      let future, promise = Future.create () in
      let converter = Converter.to_arg converter in
      let param = get_param ~converter:(Arg.list converter) ~default ~name in
      let t =
        Arg.(value
             @@ opt_all ?vopt:as_flag converter param
             @@ info (name::synonyms) ~doc ~docv) in
      main := Term.(const (fun x () ->
          Promise.fulfill promise x) $ t $ (!main));
      future

    let flag ?deprecated ?(docv="VAL") ?(doc="Undocumented")
        ?(synonyms=[]) name : bool param =
      let name = complete_param name in
      let converter = Converter.deprecation_wrap
          ~converter:(Converter.of_arg Arg.bool false) ?deprecated ~name in
      let doc = check_deprecated doc deprecated in
      let future, promise = Future.create () in
      let converter = Converter.to_arg converter in
      let param = get_param ~converter ~default:false ~name in
      let t =
        Arg.(value @@ flag @@ info (name::synonyms) ~doc ~docv) in
      main := Term.(const (fun x () ->
          Promise.fulfill promise (param || x)) $ t $ (!main));
      future

    let term_info =
      ref (Term.info ~doc (if is_plugin then plugin_name
                           else executable_name))

    type manpage_block = [
      | `I of string * string
      | `Noblank
      | `P of string
      | `Pre of string
      | `S of string
    ]

    let manpage (man:manpage_block list) : unit =
      term_info := Term.info ~doc ~man (if is_plugin then plugin_name
                                        else executable_name)

    let determined (p:'a param) : 'a future = p

    type reader = {get : 'a. 'a param -> 'a}
    let when_ready f : unit =
      let evaluate_cmdline_args () =
        match Term.eval ~argv (!main, !term_info) with
        | `Error _ -> exit 1
        | `Ok _ -> f {get = (fun p -> Future.peek_exn p)}
        | `Version | `Help -> exit 0 in
      Stream.watch Plugins.events (fun subscription -> function
          | `Errored (name,_) when plugin_name = name ->
            Stream.unsubscribe Plugins.events subscription
          | `Loaded p when Plugin.name p = plugin_name ->
            evaluate_cmdline_args ();
            Stream.unsubscribe Plugins.events subscription
          | _ -> () )

    let doc_enum = Arg.doc_alts_enum

    let of_arg = Converter.of_arg

    let bool = of_arg Arg.bool false
    let char = of_arg Arg.char '\x00'
    let int = of_arg Arg.int 0
    let nativeint = of_arg Arg.nativeint Nativeint.zero
    let int32 = of_arg Arg.int32 Int32.zero
    let int64 = of_arg Arg.int64 Int64.zero
    let float = of_arg Arg.float 0.
    let string = of_arg Arg.string ""
    let enum x =
      let _, default = List.hd_exn x in
      of_arg (Arg.enum x) default
    let file = of_arg Arg.file ""
    let dir = of_arg Arg.dir ""
    let non_dir_file = of_arg Arg.non_dir_file ""
    let list ?sep x = of_arg (Arg.list ?sep (Converter.to_arg x)) []
    let array ?sep x =
      let default = Array.empty () in
      of_arg (Arg.array ?sep (Converter.to_arg x)) default
    let pair ?sep x y =
      let default = Converter.(default x, default y) in
      of_arg Converter.(Arg.pair ?sep (to_arg x) (to_arg y)) default
    let t2 = pair
    let t3 ?sep x y z =
      let a = Converter.to_arg x in
      let b = Converter.to_arg y in
      let c = Converter.to_arg z in
      let default = Converter.(default x, default y, default z) in
      of_arg (Arg.t3 ?sep a b c) default
    let t4 ?sep w x y z =
      let a = Converter.to_arg w in
      let b = Converter.to_arg x in
      let c = Converter.to_arg y in
      let d = Converter.to_arg z in
      let default = Converter.(default w, default x, default y,
                               default z) in
      of_arg (Arg.t4 ?sep a b c d) default
    let some ?none x = of_arg (Arg.some ?none (Converter.to_arg x)) None

  end

end
