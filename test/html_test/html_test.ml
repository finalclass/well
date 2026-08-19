open Well_test

let to_str (n : _ Html.node) = Html.element_to_string n

let () =
  describe "Html" (fun () ->

    describe "escape_html" (fun () ->
      it "escapes ampersand" (fun () ->
        expect (Html.escape_html "a&b") |> to_equal_string "a&amp;b"
      );
      it "escapes less-than" (fun () ->
        expect (Html.escape_html "a<b") |> to_equal_string "a&lt;b"
      );
      it "escapes greater-than" (fun () ->
        expect (Html.escape_html "a>b") |> to_equal_string "a&gt;b"
      );
      it "escapes double quote" (fun () ->
        expect (Html.escape_html {|a"b|}) |> to_equal_string "a&quot;b"
      );
      it "escapes all at once" (fun () ->
        expect (Html.escape_html {|<script>"&"|}) |> to_equal_string "&lt;script&gt;&quot;&amp;&quot;"
      );
      it "leaves safe text alone" (fun () ->
        expect (Html.escape_html "hello world") |> to_equal_string "hello world"
      );
      it "handles empty string" (fun () ->
        expect (Html.escape_html "") |> to_equal_string ""
      );
    );

    describe "txt" (fun () ->
      it "creates escaped text node" (fun () ->
        expect (to_str (Html.txt "<b>bold</b>")) |> to_equal_string "&lt;b&gt;bold&lt;/b&gt;"
      );
      it "returns node type" (fun () ->
        expect (to_str (Html.txt "hello")) |> to_equal_string "hello"
      );
    );

    describe "raw" (fun () ->
      it "passes through without escaping" (fun () ->
        expect (to_str (Html.raw "<b>bold</b>")) |> to_equal_string "<b>bold</b>"
      );
    );

    describe "tag" (fun () ->
      it "renders div with no attrs" (fun () ->
        expect (to_str (Html.div ())) |> to_equal_string "<div></div>"
      );
      it "renders div with id" (fun () ->
        expect (to_str (Html.div ~attrs:[("id", "main")] ())) |> to_equal_string {|<div id="main"></div>|}
      );
      it "renders div with class" (fun () ->
        expect (to_str (Html.div ~attrs:[("class", "container")] ())) |> to_equal_string {|<div class="container"></div>|}
      );
      it "renders div with children" (fun () ->
        expect (to_str (Html.div ~children:[Html.txt "hello"] ())) |> to_equal_string "<div>hello</div>"
      );
      it "renders nested tags" (fun () ->
        expect (to_str
                 (Html.div ~children:[
                    Html.p ~children:[Html.txt "text"] ()
                  ] ())) |> to_equal_string "<div><p>text</p></div>"
      );
      it "renders multiple children" (fun () ->
        expect (to_str
                 (Html.ul ~children:[
                    Html.li ~children:[Html.txt "one"] ();
                    Html.li ~children:[Html.txt "two"] ();
                  ] ())) |> to_equal_string "<ul><li>one</li><li>two</li></ul>"
      );
    );

    describe "addr" (fun () ->
      it "serializes element ~addr as data-well-addr" (fun () ->
        expect
          (to_str
             (Html.element "dg-docs-table" ~addr:"project-docs" ()))
        |> to_equal_string
             {|<dg-docs-table data-well-addr="project-docs"></dg-docs-table>|}
      );
      it "omits data-well-addr when addr is empty" (fun () ->
        expect (to_str (Html.element "dg-docs-table" ~addr:"" ()))
        |> to_equal_string {|<dg-docs-table></dg-docs-table>|}
      );
      it "lets ~addr win over a data-well-addr in attrs" (fun () ->
        expect
          (to_str
             (Html.element "x-el"
                ~addr:"b"
                ~attrs:[ (Html.addr_attr, "a") ]
                ()))
        |> to_equal_string {|<x-el data-well-addr="b"></x-el>|}
      );
    );

    describe "tag attributes" (fun () ->
      it "renders href on anchor" (fun () ->
        expect (to_str (Html.a ~attrs:[("href", "/home")] ~children:[Html.txt "Home"] ())) |> to_contain {|href="/home"|}
      );
      it "renders data-lv-click" (fun () ->
        expect (to_str (Html.button ~attrs:[("data-lv-click", "increment")] ~children:[Html.txt "+"] ())) |> to_contain {|data-lv-click="increment"|}
      );
      it "renders form with method and action" (fun () ->
        expect (to_str (Html.form ~attrs:[("action", "/submit"); ("method", "POST")] ())) |> to_contain {|action="/submit"|}
      );
      it "omits empty attributes" (fun () ->
        expect (to_str (Html.div ~attrs:[("id", "x")] ())) |> not_ |> to_contain "class="
      );
      it "renders boolean attributes" (fun () ->
        expect (to_str (Html.input ~attrs:[("type", "text")] ~bool_attrs:["required"; "autofocus"] ())) |> to_contain "required";
        expect (to_str (Html.input ~attrs:[("type", "text")] ~bool_attrs:["required"; "autofocus"] ())) |> to_contain "autofocus"
      );
    );

    describe "void_tag" (fun () ->
      it "renders meta as self-closing" (fun () ->
        let s = to_str (Html.meta ~attrs:[("charset", "utf-8")] ()) in
        expect s |> to_contain {|<meta|};
        expect s |> to_contain {|charset="utf-8"|};
        expect s |> to_contain "/>"
      );
    );

    describe "LiveView helpers" (fun () ->
      it "field_error renders error span" (fun () ->
        let errors = [("name", "required")] in
        expect (to_str (Html.field_error errors "name")) |> to_contain "required";
        expect (to_str (Html.field_error errors "name")) |> to_contain "field-error"
      );
      it "field_error returns empty for missing field" (fun () ->
        expect (to_str (Html.field_error [] "name")) |> to_equal_string ""
      );
    );

    describe "csrf_input" (fun () ->
      it "renders hidden input with token" (fun () ->
        let s = to_str (Html.csrf_input "tok123") in
        expect s |> to_contain {|type="hidden"|};
        expect s |> to_contain {|name="_csrf_token"|};
        expect s |> to_contain {|value="tok123"|}
      );
      it "escapes token value" (fun () ->
        expect (to_str (Html.csrf_input {|a"b|})) |> to_contain {|value="a&quot;b"|}
      );
    );
  );

  run ~source_file:__FILE__ () |> exit_with_result
