(** Shared types used across the well framework. *)

(** An HTTP request with parsed method, path, headers, body, route params, and query string. *)
type request = {
  meth : string;
  path : string;
  headers : (string * string) list;
  body : string;
  params : (string * string) list;
  query : (string * string) list;
  session_id : string;
  _context : (int * Obj.t) list;
}
