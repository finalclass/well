(* ── Well.Form — applicative form validation ─────────────────────── *)

type 'a t = {
  field : string;
  value : 'a option;
  errors : (string * string) list;
}

(* ── Field extraction ─────────────────────────────────────────────── *)

let get (data : (string * string) list) field_name =
  let v =
    match List.assoc_opt field_name data with
    | Some v -> v
    | None -> ""
  in
  { field = field_name; value = Some v; errors = [] }

(* ── Validators ───────────────────────────────────────────────────── *)

let trim t =
  match t.value with
  | Some v -> { t with value = Some (String.trim v) }
  | None -> t

let required t =
  match t.value with
  | Some "" | None ->
      { t with value = None;
        errors = (t.field, "required") :: t.errors }
  | Some _ -> t

let min_length n t =
  match t.value with
  | Some v when String.length v < n ->
      { t with value = None;
        errors = (t.field, Printf.sprintf "min %d characters" n) :: t.errors }
  | _ -> t

let max_length n t =
  match t.value with
  | Some v when String.length v > n ->
      { t with value = None;
        errors = (t.field, Printf.sprintf "max %d characters" n) :: t.errors }
  | _ -> t

let format_ pattern t =
  match t.value with
  | Some v ->
      let re = Str.regexp pattern in
      if Str.string_match re v 0 && Str.match_end () = String.length v then t
      else
        { t with value = None;
          errors = (t.field, "invalid format") :: t.errors }
  | None -> t

let number t =
  match t.value with
  | Some v ->
      (match int_of_string_opt v with
       | Some n ->
           { field = t.field; value = Some n; errors = t.errors }
       | None ->
           { field = t.field; value = None;
             errors = (t.field, "must be a number") :: t.errors })
  | None ->
      { field = t.field; value = None; errors = t.errors }

let decimal t =
  match t.value with
  | Some v ->
      (match float_of_string_opt v with
       | Some f ->
           { field = t.field; value = Some f; errors = t.errors }
       | None ->
           { field = t.field; value = None;
             errors = (t.field, "must be a number") :: t.errors })
  | None ->
      { field = t.field; value = None; errors = t.errors }

let custom f t =
  match t.value with
  | Some v ->
      (match f v with
       | None -> t
       | Some msg ->
           { t with value = None;
             errors = (t.field, msg) :: t.errors })
  | None -> t

(* ── Applicative operators ────────────────────────────────────────── *)

let ( let+ ) t f =
  { field = "";
    value = Option.map f t.value;
    errors = t.errors }

let ( and+ ) a b =
  { field = "";
    value = (match a.value, b.value with
             | Some x, Some y -> Some (x, y)
             | _ -> None);
    errors = a.errors @ b.errors }

(* ── Result conversion ────────────────────────────────────────────── *)

let validate t =
  match t.value with
  | Some v -> Ok v
  | None -> Error t.errors
