(* Well.Config — project configuration from well.toml + env var overrides *)

(* ── Project root discovery ──────────────────────────────────────── *)

let _project_root = lazy (
  let rec search dir =
    let candidate = Filename.concat dir "well.toml" in
    if Sys.file_exists candidate then Some dir
    else
      let parent = Filename.dirname dir in
      if parent = dir then None (* reached filesystem root *)
      else search parent
  in
  search (Sys.getcwd ())
)

let project_root () =
  match Lazy.force _project_root with
  | Some dir -> dir
  | None -> Sys.getcwd ()

let project_root_opt () = Lazy.force _project_root

(* ── TOML loading ────────────────────────────────────────────────── *)

let _toml = lazy (
  match Lazy.force _project_root with
  | Some dir ->
    let path = Filename.concat dir "well.toml" in
    (try Some (Otoml.Parser.from_file path) with _ -> None)
  | None -> None
)

(* ── Env var name from dotted key ────────────────────────────────── *)

let env_var_of_key key =
  String.uppercase_ascii (String.map (fun c -> if c = '.' then '_' else c) key)

(* ── Key path splitting ─────────────────────────────────────────── *)

let split_key key =
  String.split_on_char '.' key

(* ── Raw TOML lookup ─────────────────────────────────────────────── *)

let find_toml_string key =
  match Lazy.force _toml with
  | None -> None
  | Some toml ->
    let path = split_key key in
    try Otoml.find_opt toml Otoml.get_string path
    with _ -> (
      (* Try reading as other types and converting to string *)
      try
        match Otoml.find_opt toml Otoml.get_integer path with
        | Some i -> Some (string_of_int i)
        | None -> None
      with _ -> (
        try
          match Otoml.find_opt toml Otoml.get_float path with
          | Some f -> Some (string_of_float f)
          | None -> None
        with _ -> (
          try
            match Otoml.find_opt toml Otoml.get_boolean path with
            | Some b -> Some (string_of_bool b)
            | None -> None
          with _ -> None
        )
      )
    )

(* ── Core getter: env var wins over TOML ─────────────────────────── *)

let get_raw key =
  let env_name = env_var_of_key key in
  match Sys.getenv_opt env_name with
  | Some _ as v -> v
  | None -> find_toml_string key

(* ── Typed getters ───────────────────────────────────────────────── *)

let get_string ?default key =
  match get_raw key, default with
  | Some s, _ -> s
  | None, Some d -> d
  | None, None ->
    failwith (Printf.sprintf "Well.Config: key %S not found (set %s or add to well.toml)"
      key (env_var_of_key key))

let get_string_opt key = get_raw key

let get_int ?default key =
  match get_raw key, default with
  | Some s, _ ->
    (try int_of_string s
     with Failure _ ->
       failwith (Printf.sprintf "Well.Config: key %S value %S is not an int" key s))
  | None, Some d -> d
  | None, None ->
    failwith (Printf.sprintf "Well.Config: key %S not found (set %s or add to well.toml)"
      key (env_var_of_key key))

let get_int_opt key =
  match get_raw key with
  | Some s -> (try Some (int_of_string s) with Failure _ -> None)
  | None -> None

let get_bool ?default key =
  let parse s =
    match String.lowercase_ascii s with
    | "true" | "1" | "yes" -> true
    | "false" | "0" | "no" -> false
    | _ -> failwith (Printf.sprintf "Well.Config: key %S value %S is not a bool" key s)
  in
  match get_raw key, default with
  | Some s, _ -> parse s
  | None, Some d -> d
  | None, None ->
    failwith (Printf.sprintf "Well.Config: key %S not found (set %s or add to well.toml)"
      key (env_var_of_key key))

let get_bool_opt key =
  match get_raw key with
  | Some s ->
    (match String.lowercase_ascii s with
     | "true" | "1" | "yes" -> Some true
     | "false" | "0" | "no" -> Some false
     | _ -> None)
  | None -> None

let get_float ?default key =
  match get_raw key, default with
  | Some s, _ ->
    (try float_of_string s
     with Failure _ ->
       failwith (Printf.sprintf "Well.Config: key %S value %S is not a float" key s))
  | None, Some d -> d
  | None, None ->
    failwith (Printf.sprintf "Well.Config: key %S not found (set %s or add to well.toml)"
      key (env_var_of_key key))

let get_float_opt key =
  match get_raw key with
  | Some s -> (try Some (float_of_string s) with Failure _ -> None)
  | None -> None
