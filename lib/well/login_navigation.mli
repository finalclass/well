val safe_target : string -> string

val return_target : Types.request -> string

val login_url : ?login_path:string -> ?return_param:string -> string -> string
