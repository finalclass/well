open Base;

[@deriving yojson]
type todo_item = {
  id: string,
  text: string,
  done_: bool,
};

[@deriving yojson]
type model = {
  items: list(todo_item),
  next_id: int,
  editing: option(string),  /* id of item being edited */
};

[@deriving yojson]
type add_todo_form = {
  text: string,
};

[@deriving yojson]
type edit_todo_form = {
  text: string,
};

[@deriving yojson]
type msg =
  | AddTodo(add_todo_form)
  | ToggleTodo(string)
  | RemoveTodo(string)
  | EditTodo(string)
  | SaveTodo(edit_todo_form)
  | CancelEdit
  | ClearCompleted;

let persistence = Liveview.User;

let init = (_ctx: Liveview.ctx, _props: Yojson.Safe.t): model => {
  items: [],
  next_id: 1,
  editing: None,
};

let update = (ctx: Liveview.ctx, model: model, msg: msg): model =>
  switch (msg) {
  | AddTodo({ text }) =>
    let trimmed = String.strip(text);
    if (String.is_empty(trimmed)) {
      model;
    } else {
      let id = "todo_" ++ Int.to_string(model.next_id);
      let item = { id, text: trimmed, done_: false };
      {
        ...model,
        items: List.append(model.items, [item]),
        next_id: model.next_id + 1,
      };
    };
  | ToggleTodo(id) => {
      ...model,
      items: List.map(model.items, ~f=(item) =>
        if (String.equal(item.id, id)) {
          { ...item, done_: !item.done_ };
        } else {
          item;
        }
      ),
    }
  | RemoveTodo(id) =>
    Eio.Time.sleep(Eio.Stdenv.clock(ctx.env), 2.0); /* TEST: simulate slow request */
    {
      ...model,
      items: List.filter(model.items, ~f=(item) => !String.equal(item.id, id)),
    }
  | EditTodo(id) => { ...model, editing: Some(id) }
  | SaveTodo({ text }) =>
    let trimmed = String.strip(text);
    switch (model.editing) {
    | Some(id) => {
        ...model,
        editing: None,
        items: List.map(model.items, ~f=(item) =>
          if (String.equal(item.id, id)) {
            { ...item, text: String.is_empty(trimmed) ? item.text : trimmed };
          } else {
            item;
          }
        ),
      }
    | None => model
    };
  | CancelEdit => { ...model, editing: None }
  | ClearCompleted => {
      ...model,
      items: List.filter(model.items, ~f=(item) => !item.done_),
    }
  };

let render = (model: model): Html.element => {
  let total = List.length(model.items);
  let done_count = List.length(List.filter(model.items, ~f=(item) => item.done_));

  Html.(
    <div className="todo-app">
      <h2> {txt("Lista zadań")} </h2>
      {tagWithAttrs("form", ~attrs=[lvSubmit("AddTodo")], ~children=[
        <div className="todo-input-row">
          <input type_="text" name="text" placeholder="Dodaj nowe zadanie..." />
          <button type_="submit"> {txt("Dodaj")} </button>
        </div>
      ], ())}
      {each(~id="todos", ~tag="ul", model.items, ~key=(item) => item.id, (item) => {
        let is_editing = switch (model.editing) {
        | Some(eid) => String.equal(eid, item.id)
        | None => false
        };
        if (is_editing) {
          tag("li", ~attrs=[
            ("class", "todo-item editing"),
          ], ~children=[
            tagWithAttrs("form", ~attrs=[lvSubmit("SaveTodo"), ("class", "todo-edit-form")], ~children=[
              self_closing_tag("input", ~attrs=[
                ("type", "text"),
                ("name", "text"),
                ("value", item.text),
                ("class", "todo-edit-input"),
                ("data-lv-focus", ""),
              ], ()),
              tag("button", ~attrs=[
                ("type", "submit"),
                ("class", "todo-edit-save"),
              ], ~children=[txt("✓")], ()),
              tag("button", ~attrs=[
                ("type", "button"),
                lvClick("CancelEdit"),
                ("class", "todo-edit-cancel"),
              ], ~children=[txt("✗")], ()),
            ], ()),
          ], ());
        } else {
          tag("li", ~attrs=[
            ("class", "todo-item" ++ (if (item.done_) { " done" } else { "" })),
          ], ~children=[
            tag("span", ~attrs=[
              ("class", "todo-checkbox"),
              lvClick("ToggleTodo(" ++ item.id ++ ")"),
            ], ~children=[
              txt(if (item.done_) { "☑" } else { "☐" }),
            ], ()),
            tag("span", ~attrs=[
              ("class", "todo-text"),
              lvClick("EditTodo(" ++ item.id ++ ")"),
            ], ~children=[
              txt(item.text),
            ], ()),
            tag("button", ~attrs=[
              ("class", "todo-remove"),
              lvClick("RemoveTodo(" ++ item.id ++ ")"),
            ], ~children=[
              txt("×"),
            ], ()),
          ], ());
        };
      })}
      <div className="todo-footer">
        {dynamic("todo_count", Int.to_string(total) ++ (if (total == 1) { " zadanie" } else { " zadań" }))}
        {if (done_count > 0) {
          <lvButton click="ClearCompleted" className="clear-btn">
            {txt("Wyczyść ukończone (" ++ Int.to_string(done_count) ++ ")")}
          </lvButton>
        } else {
          raw("")
        }}
      </div>
    </div>
  );
};
