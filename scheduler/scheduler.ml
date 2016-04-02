module Result' = Result
open Core.Std
open Async.Std

type t = {
  consul : Consul.t;
  services_prefix : string;
  watchers_w : (string * Edn.t) Pipe.Writer.t
}

type role_key = string

type watcher = {
  watcher_key : string;
  watcher_value : Edn.t;
  watcher_roles : role_key list;
  watcher_stopper : unit -> unit Deferred.t;
}

type node = {
  node_ip : string;
  node_name : string;
  node_tags : (string, string) List.Assoc.t;
} [@@deriving fields, sexp]

module VKV = struct
  module T = struct
    type t = (string * string) [@@deriving compare, sexp]
  end
  include T
  include Comparable.Make (T)
end

type role = {
  role_key : role_key;
  role_nodes : string list;
  role_services : (string, Edn.t) List.Assoc.t [@opaque];
  role_matcher : (string, string) List.Assoc.t -> bool;
} [@@deriving fields]

type state = {
  vkv : string VKV.Map.t;
  roles : role list;
  nodes : node list;
  watchers : watcher list;
}

module JSON = struct
  module Role = struct
    type t = {
      role_key : string [@key "key"];
      role_nodes : string list [@key "nodes"];
      role_services : string list [@key "services"];
    } [@@deriving yojson]
  end

  module Node = struct
    type t = {
      node_ip : string [@key "ip"];
      node_name : string [@key "name"];
      node_tags : Utils.Yojson_assoc.String.t [@key "tags"];
      node_roles : string list [@key "roles"];
    } [@@deriving yojson]
  end

  module Watcher = struct
    type t = {
      watcher_key : string [@key "key"];
      watcher_roles : string list [@key "roles"];
      watcher_value : Yojson.Safe.json;
    } [@@deriving yojson]
  end

  module State = struct
    type t = {
      roles : Role.t list;
      nodes : Node.t list;
      watchers : Watcher.t list;
    } [@@deriving yojson]
  end

  let of_state {roles; nodes; watchers} =
    let prepare_role {role_key; role_nodes; role_services} =
      {Role.role_key = role_key;
       role_nodes = role_nodes;
       role_services = List.map role_services fst} in
    let prepare_node roles {node_name; node_ip; node_tags} =
      let roles = List.filter_map roles (function
          | {role_nodes; role_key} when List.mem role_nodes node_name -> Some role_key
          | _ -> None) in
      {Node.node_name = node_name;
       node_ip = node_ip;
       node_tags = node_tags;
       node_roles = roles} in
    let prepare_watcher {watcher_key; watcher_roles; watcher_value} =
      {Watcher.watcher_key = watcher_key;
       watcher_roles = watcher_roles;
       watcher_value = (Edn.Json.to_json watcher_value :> Yojson.Safe.json)} in
    { State.roles = List.map roles prepare_role;
      nodes = List.map nodes (prepare_node roles);
      watchers = List.map watchers prepare_watcher;}
end


let rec create_service t k v =
  L.info "Save service %s" (Filename.concat t.services_prefix k);
  Consul.put t.consul ~path:(Filename.concat t.services_prefix k) ~body:v
  >>= function
  | Error exn ->
    L.error "Error while creating service node in Consul KV. We will try it again until success: %s" (Utils.of_exn exn);
    after (Time.Span.of_int_sec 5)
    >>= fun () ->
    create_service t k v
  | Ok () -> return ()

let delete_service t k =
  L.info "Delete service %s" (Filename.concat t.services_prefix k);
  Consul.delete t.consul ~path:(Filename.concat t.services_prefix k)
  >>= function
  | Error exn ->
    L.error "Error while deleting service node in Consul KV. We will not try it again: %s" (Utils.of_exn exn);
    return ()
  | Ok () -> return ()

let execute_diff t vkv vkv' =
  VKV.Map.symmetric_diff vkv vkv' ~data_equal:String.(=)
  |> Deferred.Sequence.iter ~f:(function
      | (node_name, service_name), `Right v | (node_name, service_name), `Unequal (_, v) ->
        create_service t (Filename.concat node_name service_name) v
      | (node_name, service_name), `Left v ->
        delete_service t (Filename.concat node_name service_name))

let compile_matcher (matcher : Edn.t) =
  let rec compile_bool = function
    | `List (`Symbol (None,"and")::xs) -> compile_and xs
    | `List (`Symbol (None,"eq")::xs) -> compile_eq xs
    | `List (`Symbol (None,"or")::xs) -> compile_or xs
    | `List (`Symbol (None,"not")::[x]) -> compile_not x
    | _ -> Error (Failure "Bad matcher. Each element should be boolean expression")
  and compile_and = function
    | [] -> Error (Failure "Bad matcher. `and` expression should contain at least one subexpression")
    | [x] -> compile_bool x
    | x::xs ->
      Result.(compile_bool x >>= fun checker ->
              compile_and xs >>| fun rest_checker ->
              (fun v -> if checker v then rest_checker v else false) )
  and compile_or = function
    | [] -> Error (Failure "Bad matcher. `or` expression should contain at least one subexpression")
    | [x] -> compile_bool x
    | x::xs ->
      Result.(compile_bool x >>= fun checker ->
              compile_or xs >>| fun rest_checker ->
              (fun v -> if checker v then true else rest_checker v))
  and compile_not x = Result.(compile_bool x >>| fun checker ->
                              (fun v -> not (checker v)))
  and compile_eq = function
    | [] -> Error (Failure "Bad matcher. `eq` expression should contain at least one subexpression")
    | xs ->
      Result.(List.map xs ~f:compile_accessor |> all >>| fun accessors ->
              (fun v ->
                 let current_val = (List.hd_exn accessors v) in
                 try
                   List.iter (List.tl_exn accessors) ~f:(fun accessor ->
                       if not ((accessor v) = current_val) then raise Exit);
                   true
                 with
                 | Exit -> false))
  and compile_accessor = function
    | `Keyword (None, k) -> (fun v -> List.Assoc.find v k) |> Result.return
    | `String const_v -> Fn.const (Some const_v) |> Result.return
    | `Null -> Fn.const None |> Result.return
    | _ -> Error (Failure "Bad matcher. Expressions of `eq` should be nil, keyword or string")in
  compile_bool matcher

let render watchers node (service_name, (v : Edn.t)) =
  let rec replace_watchers = function
    | `Tag (Some "condo", "watcher", `String key) ->
      List.find_exn watchers ~f:(fun {watcher_key} -> watcher_key = key)
      |> fun {watcher_value} -> watcher_value
    | `Assoc xs -> `Assoc (List.map xs (fun (v1, v2) -> ((replace_watchers v1), (replace_watchers v2))))
    | `List xs -> `List (List.map xs replace_watchers)
    | `Set xs -> `Set (List.map xs replace_watchers)
    | `Vector xs -> `Vector (List.map xs replace_watchers)
    | other -> other in
  let json = replace_watchers v |> Edn.Json.to_json in
  Spec.of_yojson (json :> Yojson.Safe.json) |> Utils.yojson_to_result
  |> function
  | Error exn ->
    L.error "Can't render service %s for node %s: %s"
      service_name node.node_name (Utils.of_exn exn);
    None
  | Ok spec ->
    let envs' = {Spec.Env.name = "HOST"; value = node.node_ip}::spec.Spec.envs in
    let spec' = Spec.{spec with envs = envs'} in
    Spec.to_yojson spec' |> Yojson.Safe.to_string |> Option.return

let render_role node {role_services} watchers =
  List.filter_map role_services (fun (service_name, v)->
      Option.map (render watchers node (service_name, v))
        (fun content -> (service_name, content)))

module KV = Consul.KvBody

let parse_node v =
  Result.(try_with (fun () -> Yojson.Safe.from_string v)
          >>| Syncer.NodeRecord.of_yojson
          >>= Utils.yojson_to_result)
  |> function
  | Error exn ->
    L.error "Error while parsing node %s:\n%s" (Utils.of_exn exn) v;
    None
  | Ok v -> Some v

let role_of_edn key v =
  let matcher = Edn.Util.(v |> member (`Keyword (None, "matcher")))
                |> compile_matcher in
  let services = Edn.Util.(v |> member (`Keyword (None, "services")) |> to_assoc
                           |> List.filter_map ~f:(function
                               | (`Keyword (None, k), v) -> Some (k, v)
                               | _ ->
                                 L.error "Can't parse services part of role %s" key;
                                 None)) in
  match matcher with
  | Error exn -> Error exn
  | Ok matcher -> Ok {role_key = key;
                      role_nodes = [];
                      role_matcher = matcher;
                      role_services = services}

let parse_role key v =
  Result.(try_with (fun () -> Edn.from_string v)
          >>= role_of_edn key)
  |> function
  | Error exn ->
    L.error "Error while parsing role %s:\n%s" (Utils.of_exn exn) v;
    None
  | Ok v -> Some v

let apply_node_new t state {KV.key; value} =
  parse_node value
  |> function
  | None -> state
  | Some {Syncer.NodeRecord.tags; ip} ->
    let node_name = Filename.basename key in
    let split_and_update_role (mine, all) = function
      | {role_matcher; role_nodes} as role when role_matcher tags ->
        let role' = {role with role_nodes = node_name::role_nodes} in
        (role'::mine, role'::all)
      | role -> (mine, role::all) in
    let (roles, all_roles) = List.fold state.roles  ~init:([], []) ~f:split_and_update_role in
    let node = {node_ip = ip;
                node_name = node_name;
                node_tags = tags} in
    let services = List.concat_map roles (fun role -> render_role node role state.watchers) in
    let vkv' = List.fold services ~init:state.vkv ~f:(fun vkv (k, v) ->
        VKV.Map.add vkv (node.node_name, k) v) in
    {state with vkv = vkv';
                nodes = node::state.nodes;
                roles = all_roles}

let apply_node_removed t state key =
  let node_name = Filename.basename key in
  let roles' =  List.fold state.roles  ~init:[] ~f:(fun roles role ->
      match role with
      | {role_nodes} when List.mem role_nodes node_name ->
        {role with role_nodes = List.filter role_nodes ((<>) node_name)}::roles
      | role -> role::roles) in
  let vkv' = List.fold (VKV.Map.keys state.vkv) ~init:state.vkv ~f:(fun vkv (k, v) ->
      if k = node_name then
        VKV.Map.remove vkv (k, v)
      else
        vkv) in
  {state with vkv = vkv';
              nodes = List.filter state.nodes (fun node -> node.node_name <> node_name);
              roles = roles'}

let apply_node_updated t state kv =
  apply_node_removed t state kv.KV.key |> fun state ->
  apply_node_new t state kv

let find_watchers (v : Edn.t) =
  let rec find acc = function
    | `Tag ((Some "condo"), "watcher", (`String v)) ->
      v::acc
    | `Tag ((Some "condo"), "watcher", v) ->
      L.error "Bad formed watcher: %s" (Edn.to_string v);
      acc
    | `Assoc ((v1, v2)::xs) ->
      find [] v1 @ find [] v2 @ find [] (`Assoc xs) @ acc
    | `Set (v::xs) | `List (v::xs) | `Vector (v::xs) -> find [] v @ List.concat_map xs (find []) @ acc
    | other -> acc in
  find [] v

let start_watcher t init_role_key key =
  let parse value = Result.try_with (fun () -> Edn.from_string value) |> function
    | Ok value -> value
    | Error exn ->
      L.error "Can't parse value of watcher %s: %s" key (Utils.of_exn exn);
      `Null in
  let (consul_watcher, stopper) = Consul.key t.consul key in
  Pipe.read consul_watcher
  >>| function
  | `Eof -> raise (Failure (sprintf "Watcher %s unexpectedly stopped" key))
  | `Ok value ->
    let value' = parse value in
    Pipe.transfer consul_watcher t.watchers_w ~f:(fun v -> (key, parse v)) |> don't_wait_for;
    {watcher_key = key;
     watcher_roles = [init_role_key];
     watcher_value = value';
     watcher_stopper = stopper}

let increment_watchers t watchers role new_watchers =
  let new_watcher watchers' w =
    List.find watchers' ~f:(fun {watcher_key} -> watcher_key = w)
    |> function
    | Some ({watcher_roles} as watcher) ->
      let without_this = List.filter watchers' ~f:(fun {watcher_key} -> watcher_key <> w) in
      {watcher with watcher_roles = role::watcher_roles}::without_this
      |> return
    | None ->
      (start_watcher t role w)
      >>| fun watcher ->
      watcher::watchers' in
  Deferred.List.fold new_watchers ~init:watchers ~f:new_watcher

let decrement_watchers watchers role =
  let decrement watchers' w =
    let roles = List.filter w.watcher_roles ~f:((=) role) in
    if List.length roles = 0 then
      w.watcher_stopper () >>| fun () ->
      watchers'
    else
      {w with watcher_roles = roles}::watchers' |> return in
  Deferred.List.fold watchers ~init:[] ~f:decrement

let apply_role_new t state {KV.key; value} =
  parse_role key value
  |> function
  | None -> return state
  | Some role ->
    let nodes = List.filter_map state.nodes (function
        | {node_name; node_tags} as node when role.role_matcher node_tags -> Some node
        | _ -> None) in
    let new_watchers = List.concat_map role.role_services (fun (_, v) -> find_watchers v) in
    increment_watchers t state.watchers key new_watchers
    >>| fun watchers' ->
    let add_node vkv node =
      List.fold role.role_services ~init:vkv
        ~f:(fun vkv' (service_name, v) ->
            match render watchers' node (service_name, v) with
            | Some content -> VKV.Map.add vkv' (node.node_name, service_name) content
            | None -> (VKV.Map.find state.vkv (node.node_name, service_name) |> function
              | Some old_content -> VKV.Map.add vkv' (node.node_name, service_name) old_content
              | None -> vkv')
          ) in
    let vkv' = List.fold nodes ~init:state.vkv ~f:add_node in
    {state with roles = {role with role_nodes = List.map nodes node_name}::state.roles;
                vkv = vkv';
                watchers = state.watchers @ watchers'}

let apply_role_removed t state key =
  let current = List.find_exn state.roles ~f:(fun {role_key} -> role_key = key) in
  let delete_node vkv node_name =
    List.fold current.role_services ~init:vkv
      ~f:(fun vkv' (service_name, _) -> VKV.Map.remove vkv' (node_name, service_name)) in
  let vkv' = List.fold current.role_nodes ~init:state.vkv ~f:delete_node in
  decrement_watchers state.watchers key
  >>| fun watchers' ->
  {state with vkv = vkv';
              roles = List.filter state.roles (fun {role_key} -> role_key <> key);
              watchers = watchers'}

(* This is not optimized but correct. We can do it because we do KV side effects
   after in diff step *)
let apply_role_updated t state kv =
  apply_role_removed t state kv.KV.key >>= fun state ->
  apply_role_new t state kv

let apply_watcher_updated t state key value =
  let current = List.find_exn state.watchers ~f:(fun {watcher_key} -> watcher_key = key) in
  let roles = List.map current.watcher_roles ~f:(fun role_key' ->
      List.find_exn state.roles ~f:(fun {role_key} -> role_key' = role_key)) in
  let current' = {current with watcher_value = value} in
  let watchers' = current' :: (List.filter state.watchers (fun {watcher_key} -> watcher_key <> key)) in
  let vkv' = List.fold roles ~init:state.vkv
      ~f:(fun vkv {role_services; role_nodes} ->
          List.fold role_nodes ~init:vkv
            ~f:(fun vkv node_name' ->
                let node = List.find_exn state.nodes ~f:(fun {node_name} -> node_name = node_name') in
                List.fold role_services ~init:vkv
                  ~f:(fun vkv (service_name, v) ->
                      match render watchers' node (service_name, v) with
                      | None -> vkv
                      | Some content -> VKV.Map.add vkv (node_name', service_name) content))) in
  {state with vkv = vkv';
              watchers = watchers'}

type rpc_event = GetState of state Ivar.t

type event = Node of Consul.prefix_change
           | Role of Consul.prefix_change
           | Watcher of string * Edn.t
           | RPC of rpc_event

let apply t state = function
  | Node `New v -> apply_node_new t state v |> return
  | Node `Updated v -> apply_node_updated t state v |> return
  | Node `Removed k -> apply_node_removed t state k |> return
  | Role `New v -> apply_role_new t state v
  | Role `Updated v -> apply_role_updated t state v
  | Role `Removed k -> apply_role_removed t state k
  | Watcher (k, v) -> apply_watcher_updated t state k v |> return
  | RPC GetState answer -> Ivar.fill answer state; return state

let worker t state event =
  apply t state event
  >>= fun state' ->
  execute_diff t state.vkv state'.vkv >>| fun () ->
  state'

module Server = struct
  module HTTP = Cohttp
  module Server = Cohttp_async.Server

  let state rpc _ _ _ =
    let answer = Ivar.create () in
    Pipe.write rpc (GetState answer) >>= fun () ->
    Ivar.read answer
    >>| fun state ->
    state |> JSON.of_state |> JSON.State.to_yojson

  let json_response handler keys rest request =
    (handler keys rest request)
    >>| Yojson.Safe.to_string >>= fun data ->
    let headers = (Cohttp.Header.init_with "Content-Type" "application/json") in
    Server.respond_with_string ~headers data

  let handler rpc request =
    let table = [
      "/state" , json_response (state rpc)
    ] in
    let uri = request.HTTP.Request.uri in
    match Dispatch.DSL.dispatch table (Uri.path uri) with
    | Result'.Ok handler -> handler request
    | Result'.Error _ -> Server.respond_with_string ~code:`Not_found "Not found"

  let create rpc port =
    let callback ~body _a req = handler rpc req in
    let where_to_listen = Tcp.on_port port in
    Server.create where_to_listen callback |> Deferred.ignore
end

let create consul ~services_prefix ~nodes_prefix ~roles_prefix ~server_port =
  let (nodes, nodes_closer) = Consul.prefix consul nodes_prefix in
  let (roles, roles_closer) = Consul.prefix consul roles_prefix in
  let (watchers_r, watchers_w) = Pipe.create () in
  let (rpc_r, rpc_w) = Pipe.create () in
  let t = { consul; services_prefix; watchers_w } in
  let s = {vkv = VKV.Map.empty; roles = []; nodes = []; watchers = []} in
  (* FIXME gracefully stop server *)
  Option.map server_port (Server.create rpc_w) |> ignore;
  Pipe.interleave [Pipe.map nodes ~f:(fun v -> Node v);
                   Pipe.map roles ~f:(fun v -> Role v);
                   Pipe.map watchers_r ~f:(fun (k, v) -> Watcher (k, v));
                   Pipe.map rpc_r ~f:(fun v -> RPC v)]
  |> Pipe.fold ~init:s ~f:(worker t)
  >>= (fun {watchers} ->
      watchers
      |> List.map ~f:(fun {watcher_stopper} -> watcher_stopper ())
      |> Deferred.all_unit) |> don't_wait_for;
  (fun () ->
     [nodes_closer (); roles_closer ()] |> Deferred.all_unit)