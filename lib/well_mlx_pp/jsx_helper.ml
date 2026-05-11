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

let append_exp ~loc left right =
  mkexp ~loc
    (Pexp_apply
       ( ident_exp ~loc "@",
         [ (Nolabel, left); (Nolabel, right) ] ))

let rec equal_longindent a b =
  match a, b with
  | Longident.Lident a, Longident.Lident b -> String.equal a b
  | Ldot (pa, a), Ldot (pb, b) ->
      String.equal a b && equal_longindent pa pb
  | Lapply _, _ | _, Lapply _ -> assert false
  | _ -> false

let make_jsx_element ~raise ~loc:_ ~tag ~end_tag ~props ~children () =
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
    let attrs, bool_attrs, attrs_base, bool_attrs_base =
      List.fold_left
        (fun (attrs, bool_attrs, attrs_base, bool_attrs_base) -> function
          | loc, `Prop_punned name ->
              (attrs, string_exp ~loc (attr_name name) :: bool_attrs, attrs_base, bool_attrs_base)
          | _loc, `Prop ("attrs", expr) ->
              (attrs, bool_attrs, Some expr, bool_attrs_base)
          | _loc, `Prop ("bool_attrs", expr) ->
              (attrs, bool_attrs, attrs_base, Some expr)
          | loc, `Prop (name, expr) ->
              let name = string_exp ~loc (attr_name name) in
              (tuple2 ~loc name expr :: attrs, bool_attrs, attrs_base, bool_attrs_base)
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
        ([], [], None, None) props
    in
    let attrs = List.rev attrs in
    let bool_attrs = List.rev bool_attrs in
    let attrs_expr = list_exp ~loc:tag_loc attrs in
    let bool_attrs_expr = list_exp ~loc:tag_loc bool_attrs in
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
    [
      (Nolabel, string_exp ~loc:tag_loc tag_name);
      (Labelled "attrs", attrs_expr);
      (Labelled "bool_attrs", bool_attrs_expr);
      (Labelled "children", children);
    ]
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
