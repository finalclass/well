(* Well.Toml — TOML read/write utilities *)

type t = Otoml.t

let from_file path = Otoml.Parser.from_file path
let from_string s = Otoml.Parser.from_string s
let to_string t = Otoml.Printer.to_string t

let to_file path t =
  let oc = open_out path in
  Fun.protect ~finally:(fun () -> close_out oc)
    (fun () -> output_string oc (to_string t))

(* ── Getters ─────────────────────────────────────────────────────── *)

let get_string t path = Otoml.find_opt t Otoml.get_string path
let get_int t path = Otoml.find_opt t Otoml.get_integer path
let get_float t path = Otoml.find_opt t Otoml.get_float path
let get_bool t path = Otoml.find_opt t Otoml.get_boolean path
let get_table t path = Otoml.find_opt t Otoml.get_table path

let get_string_list t path =
  Otoml.find_opt t (Otoml.get_array Otoml.get_string) path

let get_int_list t path =
  Otoml.find_opt t (Otoml.get_array Otoml.get_integer) path

(* ── Setters (return new TOML value) ─────────────────────────────── *)

let set t path value = Otoml.update t path (Some value)

let set_string t path v = set t path (Otoml.string v)
let set_int t path v = set t path (Otoml.integer v)
let set_float t path v = set t path (Otoml.float v)
let set_bool t path v = set t path (Otoml.boolean v)

let remove t path = Otoml.update t path None

(* ── Constructors ────────────────────────────────────────────────── *)

let empty = Otoml.table []
let string = Otoml.string
let integer = Otoml.integer
let float = Otoml.float
let boolean = Otoml.boolean
let array = Otoml.array
let table = Otoml.table
