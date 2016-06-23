open Core_kernel.Std

type ida

type 'a command = {
  script  : string;
  process : string -> 'a;
  language : [`python | `idc ]
}

module Command = struct
  type 'a t = 'a command
  type language = [`python | `idc]
  let create language ~script ~process = {script; process; language}
  let language x = x.language
  let script x = x.script
  let parser x = x.process
end

module Service = struct
  type t = {
    exec : 'a. 'a command -> 'a;
    close : unit -> unit
  }

  exception Service_not_provided

  let creator = ref (fun _ -> {
        exec = (fun x -> raise Service_not_provided);
        close = (fun () -> raise Service_not_provided);
      } )

  let create target : t = !creator target
  let provide (create:string -> t) : unit = creator := create

end

module Ida = struct
  type t = Service.t

  exception Failed of string
  exception Not_in_path

  let create = Service.create
  let exec (service:t) = service.exec
  let close (service:t) = service.close ()

  let with_file target command =
    let ida = create target in
    let f ida = exec ida command in
    protectx ~f ida ~finally:close
end

module Std = struct
  type ida = Ida.t
  type 'a command = 'a Command.t
  module Ida = Ida
  module Command = Command
  module Service = Service
end
