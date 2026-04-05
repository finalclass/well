(** Well.Toml -- TOML read/write utilities wrapping otoml. *)

(** A TOML document value. *)
type t = Otoml.t

(** Parse a TOML file from disk. *)
let from_file path = Otoml.Parser.from_file path

(** Parse a TOML string. *)
let from_string s = Otoml.Parser.from_string s

(** Serialize a TOML value to string. *)
let to_string t = Otoml.Printer.to_string t

(** Write a TOML value to a file. *)
let to_file path t =
  let oc = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out oc)
    (fun () -> output_string oc (to_string t))

(* ── Getters ─────────────────────────────────────────────────────── *)

(** Get a string value at the given key path, e.g. [["server"; "host"]]. *)
let get_string t path = Otoml.find_opt t Otoml.get_string path

(** Get an integer value at the given key path. *)
let get_int t path = Otoml.find_opt t Otoml.get_integer path

(** Get a float value at the given key path. *)
let get_float t path = Otoml.find_opt t Otoml.get_float path

(** Get a boolean value at the given key path. *)
let get_bool t path = Otoml.find_opt t Otoml.get_boolean path

(** Get a table (list of key-value pairs) at the given key path. *)
let get_table t path = Otoml.find_opt t Otoml.get_table path

let get_string_list t path =
  Otoml.find_opt t (Otoml.get_array Otoml.get_string) path

let get_int_list t path =
  Otoml.find_opt t (Otoml.get_array Otoml.get_integer) path

(* ── Setters (return new TOML value) ─────────────────────────────── *)

(** Set a TOML value at the given key path, returning a new document. *)
let set t path value = Otoml.update t path (Some value)

let set_string t path v = set t path (Otoml.string v)

let set_int t path v = set t path (Otoml.integer v)

let set_float t path v = set t path (Otoml.float v)

let set_bool t path v = set t path (Otoml.boolean v)

(** Remove a key at the given path, returning a new document. *)
let remove t path = Otoml.update t path None

(* ── Constructors ────────────────────────────────────────────────── *)

(** An empty TOML document. *)
let empty = Otoml.table []

let string = Otoml.string

let integer = Otoml.integer

let float = Otoml.float

let boolean = Otoml.boolean

let array = Otoml.array

let table = Otoml.table

(* ── Merge/patch ─────────────────────────────────────────────────── *)

let merge base patch =
  let rec merge_vals b p =
    List.fold_left
      (fun acc (k, v) ->
        let merged_v =
          match List.assoc_opt k b with
          | Some (Otoml.TomlTable bv) -> (
            match v with
            | Otoml.TomlTable pv -> Otoml.TomlTable (merge_vals bv pv)
            | _ -> v )
          | _ -> v
        in
        (k, merged_v) :: List.remove_assoc k acc )
      b
      p
  in
  match (base, patch) with
  | Otoml.TomlTable b, Otoml.TomlTable p -> Otoml.TomlTable (merge_vals b p)
  | _, p -> p

let patch base patches = List.fold_left merge base patches
