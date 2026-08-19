open Printf
open Asttypes
open Longident
open Parsetree
open Ast_helper

let make_loc (startpos, endpos) =
  {
    Location.loc_start = startpos;
    Location.loc_end = endpos;
    Location.loc_ghost = false;
  }

let mkexp ~loc d = Exp.mk ~loc:(make_loc loc) d

let mkjsxexp ~loc:loc' e =
  let e = mkexp ~loc:loc' e in
  let loc = make_loc loc' in
  let pexp_attributes = [ Attr.mk ~loc { txt = "JSX"; loc } (PStr []) ] in
  { e with pexp_attributes }

let string_exp ~loc s =
  mkexp ~loc (Pexp_constant (Pconst_string (s, make_loc loc, None)))

let list_exp ~loc items =
  let nil =
    mkexp ~loc (Pexp_construct ({ txt = Lident "[]"; loc = make_loc loc }, None))
  in
  List.fold_right
    (fun item tail ->
      let tuple = mkexp ~loc (Pexp_tuple [ item; tail ]) in
      mkexp ~loc
        (Pexp_construct ({ txt = Lident "::"; loc = make_loc loc }, Some tuple)))
    items nil

let attr_name name =
  if String.length name > 0 && name.[String.length name - 1] = '\'' then
    String.sub name 0 (String.length name - 1)
  else name

let tuple2 ~loc a b = mkexp ~loc (Pexp_tuple [ a; b ])

let ident_exp ~loc name =
  mkexp ~loc (Pexp_ident { loc = make_loc loc; txt = Lident name })

(** Wrap a handler-attribute expression in the [Html.handler] variant that
    matches its event name. Known events specialize (extracting [event.key]
    or [event.target.value] at render time); anything else falls back to
    [On_event] with the whole event. Constructors are qualified [Html.…] so
    they resolve whether or not the call site has [open Html]. *)
let wrap_handler ~loc event_name expr =
  let ctor name =
    mkexp ~loc
      (Pexp_construct
         ( { txt = Ldot (Lident "Html", name); loc = make_loc loc },
           Some expr ))
  in
  match event_name with
  | "click" | "dblclick" | "blur" | "focus" -> ctor "Msg"
  | "keydown" | "keyup" | "keypress" -> ctor "On_key"
  | "input" | "change" -> ctor "On_value"
  | "submit" -> ctor "On_form"
  | _ -> ctor "On_event"

let append_exp ~loc left right =
  mkexp ~loc
    (Pexp_apply
       ( ident_exp ~loc "@",
         [ (Nolabel, left); (Nolabel, right) ] ))

let html_txt_exp ~loc str_exp =
  let txt_fn =
    mkexp ~loc
      (Pexp_ident { loc = make_loc loc; txt = Ldot (Lident "Html", "txt") })
  in
  mkexp ~loc (Pexp_apply (txt_fn, [ (Nolabel, str_exp) ]))

(** A string-literal child becomes [Html.txt "lit"]; any other child
    expression is left as-is. Bare-string children thus produce escaped text
    nodes, matching the README rule ([<span>(txt name)</span>] and
    [<span>"lit"</span>] are equivalent). *)
let wrap_string_child expr =
  match expr.pexp_desc with
  | Pexp_constant (Pconst_string _) ->
      let loc = (expr.pexp_loc.loc_start, expr.pexp_loc.loc_end) in
      html_txt_exp ~loc expr
  | _ -> expr

(** Walk a list-shaped expression (cons cells + nil) and wrap each element
    that is a string literal via {!wrap_string_child}. Children that are
    already node expressions (JSX elements, identifiers, parenthesized
    applications) pass through unchanged. *)
let rec wrap_string_children expr =
  match expr.pexp_desc with
  | Pexp_construct ({ txt = Lident "[]"; _ }, None) -> expr
  | Pexp_construct ({ txt = Lident "::"; _ }, Some tuple) -> begin
      match tuple.pexp_desc with
      | Pexp_tuple [ head; tail ] ->
          let head' = wrap_string_child head in
          let tail' = wrap_string_children tail in
          let loc = (expr.pexp_loc.loc_start, expr.pexp_loc.loc_end) in
          mkexp ~loc
            (Pexp_construct
               ( { txt = Lident "::"; loc = make_loc loc },
                 Some (mkexp ~loc (Pexp_tuple [ head'; tail' ])) ))
      | _ -> expr
    end
  | _ -> expr


let rec equal_longindent a b =
  match a, b with
  | Longident.Lident a, Longident.Lident b -> String.equal a b
  | Ldot (pa, a), Ldot (pb, b) ->
      String.equal a b && equal_longindent pa pb
  | Lapply _, _ | _, Lapply _ -> assert false
  | _ -> false

let make_jsx_element ~raise ~loc:_ ~tag ~end_tag ~props ~children () =
  let children = wrap_string_children children in
  let tag_to_string = function
    | `Module, _, tag ->
        Longident.flatten tag |> String.concat "."
    | `Value, _, tag ->
        Longident.flatten tag |> String.concat "."
    | `Html, _, tag ->
        Longident.flatten tag |> String.concat "."
  in
  let () =
    match end_tag with
    | None -> ()
    | Some (end_tag, (_, end_loc_e)) ->
        let eq =
          match tag, end_tag with
          | (`Module, _, s), (`Module, _, e) -> equal_longindent s e
          | (`Value, _, s), (`Value, _, e) -> equal_longindent s e
          | (`Html, _, s), (`Html, _, e) -> equal_longindent s e
          | _ -> false
        in
        if not eq then
          let _, (end_loc_s, _), _ = end_tag in
          let end_loc = end_loc_s, end_loc_e in
          let _, start_loc, _ = tag in
          let tag = tag_to_string tag in
          raise
            Syntaxerr.(
              Error
                (Unclosed
                   ( make_loc start_loc,
                     sprintf "<%s>" tag,
                     make_loc end_loc,
                     sprintf "</%s>" tag )))
  in
  let tag_expr =
    match tag with
    | `Html, loc, _txt ->
        mkexp ~loc (Pexp_ident { loc = make_loc loc; txt = Ldot (Lident "Html", "tag") })
    | `Value, loc, txt ->
        mkexp ~loc (Pexp_ident { loc = make_loc loc; txt })
    | `Module, loc, txt ->
        let txt = Longident.Ldot (txt, "createElement") in
        mkexp ~loc (Pexp_ident { loc = make_loc loc; txt })
  in
  let component_props =
    let prop_exp ~loc name =
      let id = Location.mkloc (Lident name) (make_loc loc) in
      mkexp ~loc (Pexp_ident id)
    in
    List.map
      (function
        | loc, `Prop_punned name -> Labelled name, prop_exp ~loc name
        | loc, `Prop_opt_punned name -> Optional name, prop_exp ~loc name
        | _loc, `Prop (name, expr) -> Labelled name, expr
        | _loc, `Prop_opt (name, expr) -> Optional name, expr)
      props
  in
  let html_props tag_name tag_loc =
    let attrs, bool_attrs, handlers, attrs_base, bool_attrs_base, addr =
      List.fold_left
        (fun (attrs, bool_attrs, handlers, attrs_base, bool_attrs_base, addr) -> function
          | loc, `Prop_punned name ->
              (attrs, string_exp ~loc (attr_name name) :: bool_attrs, handlers, attrs_base, bool_attrs_base, addr)
          | _loc, `Prop ("attrs", expr) ->
              (attrs, bool_attrs, handlers, Some expr, bool_attrs_base, addr)
          | _loc, `Prop ("bool_attrs", expr) ->
              (attrs, bool_attrs, handlers, attrs_base, Some expr, addr)
          | _loc, `Prop ("addr", expr) ->
              (attrs, bool_attrs, handlers, attrs_base, bool_attrs_base, Some expr)
          | loc, `Prop (name, expr) when String.length name > 3 && String.sub name 0 3 = "on_" ->
              let event_name = String.sub name 3 (String.length name - 3) in
              let event_label = string_exp ~loc event_name in
              let handler_expr = wrap_handler ~loc event_name expr in
              (attrs, bool_attrs, tuple2 ~loc event_label handler_expr :: handlers, attrs_base, bool_attrs_base, addr)
          | loc, `Prop (name, expr) ->
              let name = string_exp ~loc (attr_name name) in
              (tuple2 ~loc name expr :: attrs, bool_attrs, handlers, attrs_base, bool_attrs_base, addr)
          | _loc, `Prop_opt_punned name ->
              ignore name;
              Stdlib.raise
                Syntaxerr.(
                  Error (Other (make_loc _loc)))
          | _loc, `Prop_opt (name, _) ->
              ignore name;
              Stdlib.raise
                Syntaxerr.(
                  Error (Other (make_loc _loc))))
        ([], [], [], None, None, None) props
    in
    let attrs = List.rev attrs in
    let bool_attrs = List.rev bool_attrs in
    let handlers = List.rev handlers in
    let attrs_expr = list_exp ~loc:tag_loc attrs in
    let bool_attrs_expr = list_exp ~loc:tag_loc bool_attrs in
    let handlers_expr = list_exp ~loc:tag_loc handlers in
    let attrs_expr =
      match attrs_base, attrs with
      | Some base, [] -> base
      | Some base, _ -> append_exp ~loc:tag_loc base attrs_expr
      | None, _ -> attrs_expr
    in
    let bool_attrs_expr =
      match bool_attrs_base, bool_attrs with
      | Some base, [] -> base
      | Some base, _ -> append_exp ~loc:tag_loc base bool_attrs_expr
      | None, _ -> bool_attrs_expr
    in
    let args =
      [
        (Nolabel, string_exp ~loc:tag_loc tag_name);
        (Labelled "attrs", attrs_expr);
        (Labelled "bool_attrs", bool_attrs_expr);
        (Labelled "handlers", handlers_expr);
        (Labelled "children", children);
      ]
    in
    match addr with
    | None -> args
    | Some expr -> args @ [ (Labelled "addr", expr) ]
  in
  let unit =
    Exp.mk ~loc:Location.none
      (Pexp_construct ({ txt = Lident "()"; loc = Location.none }, None))
  in
  match tag with
  | `Html, tag_loc, tag_name ->
      let tag_name = Longident.flatten tag_name |> String.concat "." in
      Pexp_apply (tag_expr, html_props tag_name tag_loc @ [ (Nolabel, unit) ])
  | _ ->
      let props = (Labelled "children", children) :: component_props in
      Pexp_apply (tag_expr, (Nolabel, unit) :: props)
