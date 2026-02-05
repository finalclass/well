type request = {
  meth : string;
  path : string;
  headers : (string * string) list;
  body : string;
  params : (string * string) list;
  query : (string * string) list;
  session_id : string;
}
