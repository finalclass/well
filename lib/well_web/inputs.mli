(** Inputs — Client role: host attributes, JS properties, and prop hydrate.

    Bridges external host inputs ([Props.t]) into the TEA loop by publishing
    on MessageBus topic ["msg"] (same path as DOM event handlers). Tracks
    last-seen prop values per instance to skip no-op updates via [equal]. *)

(** HydrateInstance — after [init], before first vdom publish: transfer any
    own data properties that shadow CE accessors into [__well_prop_*], then
    read host attributes (parseable props) and JS properties; fold each
    resulting msg through [update] synchronously so the first paint reflects
    host inputs. Property value wins over attribute when both present.

    ```use-case
    (START)
    [Transfer own data props → accessor storage (unshadow)]
    [Load props specs for instance]
    [For each parseable attr present on host: parse → msg]
    [For each prop with a JS property already set: coerce → msg]
    [Fold msgs through update + StateAccess.persist]
    [Return final state]
    (STOP)
    ```
*)
val hydrate_instance :
  instance_id:string ->
  host:Bridge.element ->
  initial_state:Component_access.state ->
  Component_access.state

(** HandleAttributeChange — [attributeChangedCallback] path.
    On set: parse new value (skip if unparseable / equal). On removal
    ([new_value = None]): apply scalar [default_value] when present.
    Publish ["msg"] when the effective value changed. *)
val handle_attribute_change :
  host:Bridge.element ->
  name:string ->
  old_value:string option ->
  new_value:string option ->
  unit

(** HandlePropertySet — prototype setter path for list/of_eq (and scalars).
    [Props.list]: accept JS [Array] (elements coerced) or OCaml list
    (jsoo heap); reject other values closed. Skip when [equal]; publish
    ["msg"]. *)
val handle_property_set :
  host:Bridge.element ->
  name:string ->
  value:Bridge.value ->
  unit

(** Observed attribute names for a tag (scalars and [Props.attr_or_prop]). *)
val observed_attribute_names : tag_name:string -> string list

(** All prop names that get JS property accessors on the custom element. *)
val property_names : tag_name:string -> string list

(** Drop last-seen prop cache for an instance (disconnect). *)
val forget_instance : instance_id:string -> unit
