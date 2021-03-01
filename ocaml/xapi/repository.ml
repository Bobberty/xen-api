(*
 * Copyright (C) Citrix Systems Inc.
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published
 * by the Free Software Foundation; version 2.1 only. with the special
 * exception on linking described in file LICENSE.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *)

module Unixext = Xapi_stdext_unix.Unixext

module D = Debug.Make (struct let name = "repository" end)

open D

open Repository_helpers

module UpdateIdSet = Set.Make (String)

let capacity_in_parallel = 16
let reposync_mutex = Mutex.create ()

let introduce ~__context ~name_label ~name_description ~binary_url ~source_url =
  assert_url_is_valid ~url:binary_url;
  assert_url_is_valid ~url:source_url;
  Db.Repository.get_all ~__context
  |> List.iter (fun ref ->
      if name_label = Db.Repository.get_name_label ~__context ~self:ref
      || binary_url = Db.Repository.get_binary_url ~__context ~self:ref then
        raise Api_errors.( Server_error (repository_already_exists, [(Ref.string_of ref)]) ));
  create_repository_record ~__context ~name_label ~name_description ~binary_url ~source_url

let forget ~__context ~self =
  let pool = Helpers.get_pool ~__context in
  let enabled = Db.Pool.get_repository ~__context ~self:pool in
  if enabled = self then
    raise Api_errors.(Server_error (repository_is_in_use, []))
  else
    Db.Repository.destroy ~__context ~self

let with_reposync_lock f =
  if Mutex.try_lock reposync_mutex then
    Xapi_stdext_pervasives.Pervasiveext.finally
      (fun () -> f ())
      (fun () -> Mutex.unlock reposync_mutex)
  else
    raise Api_errors.(Server_error (reposync_in_progress, []))

let get_enabled_repository ~__context =
  let pool = Helpers.get_pool ~__context in
  match Db.Pool.get_repository ~__context ~self:pool with
  | ref when ref <> Ref.null -> ref
  | _ ->
    raise Api_errors.(Server_error (no_repository_enabled, []))

let cleanup_pool_repo () =
  try
    clean_yum_cache !Xapi_globs.pool_repo_name;
    Unixext.unlink_safe (Filename.concat !Xapi_globs.yum_repos_config_dir
                           !Xapi_globs.pool_repo_name);
    Helpers.rmtree !Xapi_globs.local_pool_repo_dir
  with e ->
    error "Failed to cleanup pool repository: %s" (ExnHelper.string_of_exn e);
    raise Api_errors.(Server_error (repository_cleanup_failed, []))

let sync ~__context ~self =
  try
    remove_repo_conf_file !Xapi_globs.pool_repo_name;
    let binary_url = Db.Repository.get_binary_url  ~__context ~self in
    let source_url = Db.Repository.get_source_url  ~__context ~self in
    write_yum_config ~source_url:(Some source_url) binary_url !Xapi_globs.pool_repo_name;
    let config_params =
        [
          "--save";
          if !Xapi_globs.repository_gpgcheck then "--setopt=repo_gpgcheck=1"
          else "--setopt=repo_gpgcheck=0";
          Printf.sprintf "%s" !Xapi_globs.pool_repo_name;
        ]
    in
    ignore (Helpers.call_script !Xapi_globs.yum_config_manager_cmd config_params);
    (* sync with remote repository *)
    let sync_params =
        [
          "-p"; !Xapi_globs.local_pool_repo_dir;
          "--downloadcomps";
          "--download-metadata";
          if !Xapi_globs.repository_gpgcheck then "--gpgcheck" else "";
          "--delete";
          Printf.sprintf "--repoid=%s" !Xapi_globs.pool_repo_name;
        ]
    in
    Unixext.mkdir_rec !Xapi_globs.local_pool_repo_dir 0o700;
    clean_yum_cache !Xapi_globs.pool_repo_name;
    ignore (Helpers.call_script !Xapi_globs.reposync_cmd sync_params)
  with e ->
    error "Failed to sync with remote YUM repository: %s" (ExnHelper.string_of_exn e);
    raise Api_errors.(Server_error (reposync_failed, []))

let http_get_host_updates_in_json ~__context ~host ~installed =
  let host_session_id =
    Xapi_session.login_no_password ~__context ~uname:None ~host ~pool:true
      ~is_local_superuser:true ~subject:Ref.null ~auth_user_sid:""
      ~auth_user_name:"" ~rbac_permissions:[]
  in
  let request = Xapi_http.http_request
      ~cookie:[("session_id", Ref.string_of host_session_id)]
      ~query:[("installed", (string_of_bool installed))]
      Http.Get Constants.get_host_updates_uri
  in
  let host_name = (Db.Host.get_hostname ~__context ~self:host) in
  let host_addr = Db.Host.get_address ~__context ~self:host in
  let open Xmlrpc_client in
  let transport = SSL (SSL.make () ~verify_cert:false, host_addr, !Constants.https_port) in
  debug "getting host updates on %s (addr %s) by HTTP GET" host_name host_addr;
  Xapi_stdext_pervasives.Pervasiveext.finally
    (fun () ->
      try
        let json_str =
          with_transport transport
            (with_http request (fun (response, fd) ->
                 Xapi_stdext_unix.Unixext.string_of_fd fd))
        in
        debug "host %s returned updates: %s" host_name json_str;
        Yojson.Basic.from_string json_str
      with e ->
        let ref = Ref.string_of host in
        error "Failed to get updates from host ref='%s': %s" ref (ExnHelper.string_of_exn e);
        raise Api_errors.(Server_error (get_host_updates_failed, [ref])))
    (fun () -> Xapi_session.destroy_db_session ~__context ~self:host_session_id)

let set_available_updates ~__context ~self =
  let hosts = Db.Host.get_all ~__context in
  let xml_path =
    "repodata/repomd.xml"
    |> Filename.concat !Xapi_globs.pool_repo_name
    |> Filename.concat !Xapi_globs.local_pool_repo_dir
  in
  let md = UpdateInfoMetaData.of_xml_file xml_path in
  let are_updates_available host () =
    let json = http_get_host_updates_in_json ~__context ~host ~installed:false in
    (* TODO: live patches *)
    match Yojson.Basic.Util.member "updates" json with
    | `List [] -> false
    | _ -> true
    | exception e ->
      let ref = Ref.string_of host in
      error "Invalid updates from host ref='%s': %s" ref (ExnHelper.string_of_exn e);
      raise Api_errors.(Server_error (get_host_updates_failed, [ref]))
  in
  let funs = List.map (fun h -> are_updates_available h) hosts in
  let rets_of_hosts = Helpers.run_in_parallel funs capacity_in_parallel in
  let is_all_up_to_date = not (List.exists (fun b -> b) rets_of_hosts) in
  Db.Repository.set_up_to_date ~__context ~self ~value:is_all_up_to_date;
  Db.Repository.set_hash ~__context ~self ~value:(md.UpdateInfoMetaData.checksum);
  md.UpdateInfoMetaData.checksum

let create_pool_repository ~__context ~self =
  let repo_dir = Filename.concat !Xapi_globs.local_pool_repo_dir !Xapi_globs.pool_repo_name in
  match Sys.file_exists repo_dir with
  | true ->
    (try
       let cachedir = get_cachedir !Xapi_globs.pool_repo_name in
       let md = UpdateInfoMetaData.of_xml_file (Filename.concat cachedir "repomd.xml") in
       let updateinfo_xml_gz_path =
         Filename.concat repo_dir (md.UpdateInfoMetaData.checksum ^ "-updateinfo.xml.gz")
       in
       ignore (Helpers.call_script !Xapi_globs.createrepo_cmd [repo_dir]);
       begin match Sys.file_exists updateinfo_xml_gz_path with
         | true ->
           with_updateinfo_xml updateinfo_xml_gz_path (fun xml_file_path ->
               let repodata_dir = Filename.concat repo_dir "repodata" in
               ignore (Helpers.call_script !Xapi_globs.modifyrepo_cmd
                         ["--remove"; "updateinfo"; repodata_dir]);
               ignore (Helpers.call_script !Xapi_globs.modifyrepo_cmd
                         ["--mdtype"; "updateinfo"; xml_file_path; repodata_dir]));
           with_pool_repository (fun () ->
               set_available_updates ~__context ~self)
         | false ->
           error "No updateinfo.xml.gz found: %s" updateinfo_xml_gz_path;
           raise Api_errors.(Server_error (invalid_updateinfo_xml, []))
       end
     with
     | Api_errors.(Server_error (code, _)) as e when code <> Api_errors.internal_error ->
       raise e
     | e ->
       error "Creating local pool repository failed: %s" (ExnHelper.string_of_exn e);
       raise Api_errors.(Server_error (createrepo_failed, [])))
  | false ->
    error "local pool repository directory '%s' does not exist" repo_dir;
    raise Api_errors.(Server_error (reposync_failed, []))

let get_host_updates_in_json ~__context ~installed =
  try
    with_local_repository ~__context (fun () ->
      let rpm2updates = get_updates_from_updateinfo () in
      let installed_pkgs = match installed with
        | true -> get_installed_pkgs ()
        | false -> []
      in
      let params_of_list =
        [
          "-q"; "--disablerepo=*"; Printf.sprintf "--enablerepo=%s" !Xapi_globs.local_repo_name;
          "list"; "updates";
        ]
      in
      let updates =
        clean_yum_cache !Xapi_globs.local_repo_name;
        Helpers.call_script !Xapi_globs.yum_cmd params_of_list
        |> Astring.String.cuts ~sep:"\n"
        |> List.filter_map
          (Repository_helpers.get_rpm_update_in_json ~rpm2updates ~installed_pkgs)
      in
      (* TODO: live patches *)
      `Assoc [("updates", `List updates)])
  with
  | Api_errors.(Server_error (code, _)) as e when code <> Api_errors.internal_error ->
    raise e
  | e ->
    let ref = Ref.string_of (Helpers.get_localhost ~__context) in
    error "Failed to get host updates on host ref=%s: %s" ref (ExnHelper.string_of_exn e);
    raise Api_errors.(Server_error (get_host_updates_failed, [ref]))

(* This handler hosts HTTP endpoint '/repository' which will be available iif
 * 'is_local_pool_repo_enabled' returns true with 'with_pool_repository' being called by
 * others.
 *)
let get_repository_handler (req : Http.Request.t) s _ =
  let open Http in
  let open Xapi_stdext_std.Xstringext in
  debug "Repository.get_repository_handler URL %s" req.Request.uri ;
  req.Request.close <- true ;
  if is_local_pool_repo_enabled () then
    (try
        let len = String.length Constants.get_repository_uri in
        begin match String.sub_to_end req.Request.uri len with
          | uri_path ->
            let root = Filename.concat
                !Xapi_globs.local_pool_repo_dir !Xapi_globs.pool_repo_name
            in
            Fileserver.response_file s (Helpers.resolve_uri_path ~root ~uri_path)
          | exception e ->
            let msg =
              Printf.sprintf "Failed to get path from uri': %s" (ExnHelper.string_of_exn e)
            in
            raise Api_errors.(Server_error (internal_error, [msg]))
        end
    with e ->
      error
        "Failed to serve for request on uri %s: %s" req.Request.uri (ExnHelper.string_of_exn e);
      Http_svr.response_forbidden ~req s)
  else
    (error "Rejecting request: local pool repository is not enabled";
     Http_svr.response_forbidden ~req s)

let parse_updateinfo ~hash =
  let repo_dir = Filename.concat !Xapi_globs.local_pool_repo_dir !Xapi_globs.pool_repo_name in
  let repodata_dir = Filename.concat repo_dir "repodata" in
  let repomd_xml_path = Filename.concat repodata_dir "repomd.xml" in
  let md = UpdateInfoMetaData.of_xml_file repomd_xml_path in
  if hash <> md.UpdateInfoMetaData.checksum then
    (error "Unexpected mismatch between XAPI DB and YUM DB. Need to do pool.sync-updates again.";
     raise Api_errors.(Server_error (createrepo_failed, [])));
  let updateinfo_xml_gz_path = Filename.concat repo_dir md.UpdateInfoMetaData.location in
  match Sys.file_exists updateinfo_xml_gz_path with
  | false ->
    error "File %s doesn't exist" updateinfo_xml_gz_path;
    raise Api_errors.(Server_error (invalid_updateinfo_xml, []))
  | true ->
    with_updateinfo_xml updateinfo_xml_gz_path UpdateInfo.of_xml_file

let get_pool_updates_in_json ~__context ~hosts =
  let ref = get_enabled_repository ~__context in
  let hash = Db.Repository.get_hash ~__context ~self:ref in
  try
    let funs = List.map (fun host ->
        fun () ->
          ( (Ref.string_of host),
            (http_get_host_updates_in_json ~__context ~host ~installed:true) )
      ) hosts
    in
    let rets =
      with_pool_repository (fun () ->
          Helpers.run_in_parallel funs capacity_in_parallel)
    in
    let updates_info = parse_updateinfo ~hash in
    let updates_of_hosts, ids_of_updates =
      rets
      |> List.fold_left (fun (acc1, acc2) (host, ret_of_host) ->
          let json_of_host, uids =
            consolidate_updates_of_host ~updates_info host ret_of_host
          in
          ( (json_of_host :: acc1), (UpdateIdSet.union uids acc2) )
      ) ([], UpdateIdSet.empty)
    in
    `Assoc [
      ("hosts", `List updates_of_hosts);
      ("updates", `List (UpdateIdSet.elements ids_of_updates |> List.map (fun uid  ->
           UpdateInfo.to_json (List.assoc uid updates_info))));
      ("hash", `String hash)]
  with
  | Api_errors.(Server_error (code, _)) as e when code <> Api_errors.internal_error ->
    raise e
  | e ->
    error "getting updates for pool failed: %s" (ExnHelper.string_of_exn e);
    raise Api_errors.(Server_error (get_updates_failed, []))

let apply ~__context ~host =
  (* This function runs on slave host *)
  with_local_repository ~__context (fun () ->
      let params =
          [
            "-y"; "--disablerepo=*";
            Printf.sprintf "--enablerepo=%s" !Xapi_globs.local_repo_name;
            "upgrade"
          ]
      in
      try ignore (Helpers.call_script !Xapi_globs.yum_cmd params)
      with e ->
        let ref = Ref.string_of host in
        error "Failed to apply updates on host ref='%s': %s" ref (ExnHelper.string_of_exn e);
        raise Api_errors.(Server_error (apply_updates_failed, [ref])))

let restart_device_models ~__context host =
  (* Restart device models of all running HVM VMs on the host by doing
   * local migrations. *)
  Db.Host.get_resident_VMs ~__context ~self:host
  |> List.map (fun self -> (self, Db.VM.get_record ~__context ~self))
  |> List.filter (fun (_, record) -> not record.API.vM_is_control_domain)
  |> List.filter_map (fun (ref, record) ->
      match record.API.vM_power_state,
            Helpers.has_qemu_currently ~__context ~self:ref with
      | `Running, true ->
        Helpers.call_api_functions ~__context (fun rpc session_id ->
            Client.Client.VM.pool_migrate rpc session_id ref host [("live", "true")]);
        None
      | `Paused, true ->
        error "VM 'ref=%s' is paused, can't restart its device models" (Ref.string_of ref);
        Some ref
      | _ ->
        (* No device models are running for this VM *)
        None)
  |> function
  | [] -> ()
  | _ :: _ ->
    let msg = "Can't restart device models for some VMs" in
    raise Api_errors.(Server_error (internal_error, [msg]))

let apply_immediate_guidances ~__context ~host ~guidances =
  (* This function runs on master host *)
  try
    let num_of_hosts = List.length (Db.Host.get_all ~__context) in
    let open Client in
    Helpers.call_api_functions ~__context (fun rpc session_id ->
        let open Guidance in
        match guidances with
        | [RebootHost] ->
          Client.Host.reboot ~rpc ~session_id ~host
        | [EvacuateHost] ->
          (* EvacuatHost should be done before applying updates by XAPI users.
           * Here only the guidances to be applied after applying updates are handled.
           *)
          ()
        | [RestartDeviceModel] ->
          restart_device_models ~__context host
        | [RestartToolstack] ->
          Client.Host.restart_agent ~rpc ~session_id ~host
        | l when eq_set1 l ->
          (* EvacuateHost and RestartToolstack *)
          Client.Host.restart_agent ~rpc ~session_id ~host
        | l when eq_set2 l ->
          (* RestartDeviceModel and RestartToolstack *)
          restart_device_models ~__context host;
          Client.Host.restart_agent ~rpc ~session_id ~host
        | l when eq_set3 l ->
          (* RestartDeviceModel and EvacuateHost *)
          (* Evacuating host restarted device models already *)
          if num_of_hosts = 1 then restart_device_models ~__context host;
          ()
        | l when eq_set4 l ->
          (* EvacuateHost, RestartToolstack and RestartDeviceModel *)
          (* Evacuating host restarted device models already *)
          if num_of_hosts = 1 then restart_device_models ~__context host;
          Client.Host.restart_agent ~rpc ~session_id ~host
        | l ->
          let ref = Ref.string_of host in
          error "Found wrong guidance(s) after applying updates on host ref='%s': %s"
            ref (String.concat ";" (List.map Guidance.to_string l));
          raise Api_errors.(Server_error (apply_guidance_failed, [ref])))
  with e ->
    let ref = Ref.string_of host in
    error "applying immediate guidances on host ref='%s' failed: %s"
      ref (ExnHelper.string_of_exn e);
    raise Api_errors.(Server_error (apply_guidance_failed, [ref]))

let apply_updates ~__context ~host ~hash =
  (* This function runs on master host *)
  try
    with_pool_repository (fun () ->
        let updates =
          http_get_host_updates_in_json ~__context ~host ~installed:true
          |> Yojson.Basic.Util.member "updates"
          |> Yojson.Basic.Util.to_list
          |> List.map Update.of_json
        in
        match updates with
        | [] ->
          let ref = Ref.string_of host in
          info "Host ref='%s' is already up to date." ref;
          []
        | l ->
          let updates_info = parse_updateinfo ~hash in
          let immediate_guidances =
            eval_guidances ~updates_info ~updates:l ~kind:Recommended
          in
          Guidance.assert_valid_guidances immediate_guidances;
          Helpers.call_api_functions ~__context (fun rpc session_id ->
              Client.Client.Repository.apply ~rpc ~session_id ~host);
          (* TODO: absolute guidances *)
          immediate_guidances)
  with
  | Api_errors.(Server_error (code, _)) as e when code <> Api_errors.internal_error ->
    raise e
  | e ->
    let ref = Ref.string_of host in
    error "applying updates on host ref='%s' failed: %s" ref (ExnHelper.string_of_exn e);
    raise Api_errors.(Server_error (apply_updates_failed, [ref]))