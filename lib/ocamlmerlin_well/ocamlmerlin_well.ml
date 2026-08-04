(** Merlin reader for Well MLX.

    Invokes [well-mlx-pp] (same binary dune uses for the dialect preprocess)
    so ocamllsp/Merlin see [Html.tag "div" …] instead of stock MLX
    [div () ~children:…].

    Dune: [(merlin_reader well)] → process name [ocamlmerlin-well] on PATH.
*)

open Extend_protocol.Reader

let well_mlx_pp_candidates () =
  let from_env = Sys.getenv_opt "WELL_MLX_PP" in
  let beside_self =
    try
      let self = Sys.executable_name in
      let dir = Filename.dirname self in
      Some (Filename.concat dir "well-mlx-pp")
    with _ -> None
  in
  List.filter_map
    (fun x -> x)
    [ from_env; beside_self; Some "well-mlx-pp" ]

let find_well_mlx_pp () =
  let rec loop = function
    | [] -> None
    | path :: rest ->
        if path = "" then loop rest
        else if String.contains path '/' then
          if Sys.file_exists path then Some path else loop rest
        else Some path (* bare name → PATH *)
  in
  loop (well_mlx_pp_candidates ())

(** Rewrite every [pos_fname] so diagnostics attach to the editor buffer. *)
let set_filename (fname : string) (str : Parsetree.structure) :
    Parsetree.structure =
  let open Ast_mapper in
  let map_pos (p : Lexing.position) = { p with pos_fname = fname } in
  let map_loc (loc : Location.t) =
    {
      loc with
      loc_start = map_pos loc.loc_start;
      loc_end = map_pos loc.loc_end;
    }
  in
  let mapper =
    { default_mapper with location = (fun _m loc -> map_loc loc) }
  in
  mapper.structure mapper str

let run_pp ~filename text : (Parsetree.structure, string) result =
  match find_well_mlx_pp () with
  | None ->
      Error "well-mlx-pp not found (set WELL_MLX_PP or put well on PATH)"
  | Some pp ->
      let tmp_in = Filename.temp_file "well-merlin-" ".mlx" in
      let tmp_out = tmp_in ^ ".ast" in
      let err_file = tmp_in ^ ".err" in
      let cleanup () =
        List.iter
          (fun f -> try Sys.remove f with _ -> ())
          [ tmp_in; tmp_out; err_file ]
      in
      Fun.protect ~finally:cleanup (fun () ->
          Out_channel.with_open_bin tmp_in (fun oc ->
              output_string oc text);
          let cmd =
            Printf.sprintf "%s %s > %s 2> %s" (Filename.quote pp)
              (Filename.quote tmp_in) (Filename.quote tmp_out)
              (Filename.quote err_file)
          in
          match Sys.command cmd with
          | 0 -> (
              try
                In_channel.with_open_bin tmp_out (fun ic ->
                    let magic =
                      Ppxlib_ast.Compiler_version.Ast.Config
                      .ast_impl_magic_number
                    in
                    let got = really_input_string ic (String.length magic) in
                    if got <> magic then
                      Error
                        (Printf.sprintf
                           "well-mlx-pp magic mismatch (got %S want %S)" got
                           magic)
                    else
                      let _pp_fname : string = input_value ic in
                      let str :
                          Ppxlib_ast.Compiler_version.Ast.Parsetree.structure
                          =
                        input_value ic
                      in
                      let str = (Obj.magic str : Parsetree.structure) in
                      Ok (set_filename filename str))
              with exn ->
                Error
                  (Printf.sprintf "failed reading well-mlx-pp AST: %s"
                     (Printexc.to_string exn)))
          | code ->
              let err =
                try In_channel.with_open_text err_file In_channel.input_all
                with _ -> ""
              in
              Error
                (Printf.sprintf "well-mlx-pp exit %d: %s" code
                   (String.trim err)))

let error_structure msg : Parsetree.structure =
  let loc = Location.none in
  let open Ast_helper in
  let payload = Str.eval ~loc (Exp.constant ~loc (Const.string msg)) in
  [
    Str.eval ~loc
      (Exp.extension ~loc ({ loc; txt = "ocaml.error" }, PStr [ payload ]));
  ]

module Well_reader = struct
  type t = buffer

  let load buffer = buffer

  let parse { text; path; _ } =
    match run_pp ~filename:path text with
    | Ok str -> Structure str
    | Error msg -> Structure (error_structure msg)

  let for_completion t _pos = { complete_labels = true }, parse t

  let parse_line _t _pos text =
    match run_pp ~filename:"*buffer*" text with
    | Ok str -> Structure str
    | Error msg -> Structure (error_structure msg)

  let ident_at _ _ = []

  let pretty_print ppf = function
    | Pretty_structure s -> Pprintast.structure ppf s
    | Pretty_signature s -> Pprintast.signature ppf s
    | Pretty_expression e -> Pprintast.expression ppf e
    | Pretty_pattern p -> Pprintast.pattern ppf p
    | Pretty_core_type t -> Pprintast.core_type ppf t
    | Pretty_toplevel_phrase p -> Pprintast.toplevel_phrase ppf p
    | Pretty_case_list cases ->
        Format.pp_print_list
          ~pp_sep:(fun ppf () -> Format.fprintf ppf "@ | ")
          (fun ppf (c : Parsetree.case) ->
            Format.fprintf ppf "@[<hov 2>| %a@ -> %a@]" Pprintast.pattern
              c.pc_lhs Pprintast.expression c.pc_rhs)
          ppf cases

  let print_outcome = Extend_helper.print_outcome_using_oprint
end

let () =
  if Sys.win32 then begin
    set_binary_mode_in stdin true;
    set_binary_mode_out stdout true
  end;
  Extend_main.extension_main
    ~reader:(Extend_main.Reader.make_v0 (module Well_reader : V0))
    (Extend_main.Description.make_v0 ~name:"well" ~version:"0.1")
