open Well_test

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
        let (`Html s) = Html.txt "<b>bold</b>" in
        expect s |> to_equal_string "&lt;b&gt;bold&lt;/b&gt;"
      );
      it "returns node type" (fun () ->
        let node = Html.txt "hello" in
        let (`Html s) = node in
        expect s |> to_equal_string "hello"
      );
    );

    describe "raw" (fun () ->
      it "passes through without escaping" (fun () ->
        let (`Html s) = Html.raw "<b>bold</b>" in
        expect s |> to_equal_string "<b>bold</b>"
      );
    );

    describe "tag" (fun () ->
      it "renders div with no attrs" (fun () ->
        let (`Html s) = Html.div () in
        expect s |> to_equal_string "<div></div>"
      );
      it "renders div with id" (fun () ->
        let (`Html s) = Html.div ~attrs:[("id", "main")] () in
        expect s |> to_equal_string {|<div id="main"></div>|}
      );
      it "renders div with class" (fun () ->
        let (`Html s) = Html.div ~attrs:[("class", "container")] () in
        expect s |> to_equal_string {|<div class="container"></div>|}
      );
      it "renders div with children" (fun () ->
        let (`Html s) = Html.div ~children:[Html.txt "hello"] () in
        expect s |> to_equal_string "<div>hello</div>"
      );
      it "renders nested tags" (fun () ->
        let (`Html s) =
          Html.div ~children:[
            Html.p ~children:[Html.txt "text"] ()
          ] ()
        in
        expect s |> to_equal_string "<div><p>text</p></div>"
      );
      it "renders multiple children" (fun () ->
        let (`Html s) =
          Html.ul ~children:[
            Html.li ~children:[Html.txt "one"] ();
            Html.li ~children:[Html.txt "two"] ();
          ] ()
        in
        expect s |> to_equal_string "<ul><li>one</li><li>two</li></ul>"
      );
    );

    describe "tag attributes" (fun () ->
      it "renders href on anchor" (fun () ->
        let (`Html s) = Html.a ~attrs:[("href", "/home")] ~children:[Html.txt "Home"] () in
        expect s |> to_contain {|href="/home"|}
      );
      it "renders data-lv-click" (fun () ->
        let (`Html s) = Html.button ~attrs:[("data-lv-click", "increment")] ~children:[Html.txt "+"] () in
        expect s |> to_contain {|data-lv-click="increment"|}
      );
      it "renders form with method and action" (fun () ->
        let (`Html s) = Html.form ~attrs:[("action", "/submit"); ("method", "POST")] () in
        expect s |> to_contain {|action="/submit"|};
        expect s |> to_contain {|method="POST"|}
      );
      it "omits empty attributes" (fun () ->
        let (`Html s) = Html.div ~attrs:[("id", "x")] () in
        expect s |> not_ |> to_contain "class="
      );
      it "renders boolean attributes" (fun () ->
        let (`Html s) = Html.input ~attrs:[("type", "text")] ~bool_attrs:["required"; "autofocus"] () in
        expect s |> to_contain "required";
        expect s |> to_contain "autofocus"
      );
    );

    describe "void_tag" (fun () ->
      it "renders meta as self-closing" (fun () ->
        let (`Html s) = Html.meta ~attrs:[("charset", "utf-8")] () in
        expect s |> to_contain {|<meta|};
        expect s |> to_contain {|charset="utf-8"|};
        expect s |> to_contain "/>"
      );
    );

    describe "LiveView helpers" (fun () ->
      it "field_error renders error span" (fun () ->
        let errors = [("name", "required")] in
        let (`Html s) = Html.field_error errors "name" in
        expect s |> to_contain "required";
        expect s |> to_contain "field-error"
      );
      it "field_error returns empty for missing field" (fun () ->
        let (`Html s) = Html.field_error [] "name" in
        expect s |> to_equal_string ""
      );
    );

    describe "csrf_input" (fun () ->
      it "renders hidden input with token" (fun () ->
        let (`Html s) = Html.csrf_input "tok123" in
        expect s |> to_contain {|type="hidden"|};
        expect s |> to_contain {|name="_csrf_token"|};
        expect s |> to_contain {|value="tok123"|}
      );
      it "escapes token value" (fun () ->
        let (`Html s) = Html.csrf_input {|a"b|} in
        expect s |> to_contain {|value="a&quot;b"|}
      );
    );

    describe "each (keyed lists)" (fun () ->
      it "renders keyed list with data-lv-each" (fun () ->
        let items = ["a"; "b"; "c"] in
        let (`Html s) =
          Html.each ~id:"items" items
            ~key:(fun x -> x)
            (fun x -> Html.li ~children:[Html.txt x] ())
        in
        expect s |> to_contain {|data-lv-each="items"|};
        expect s |> to_contain "a";
        expect s |> to_contain "b";
        expect s |> to_contain "c"
      );
      it "injects data-lv-key on each item" (fun () ->
        let items = ["x"] in
        let (`Html s) =
          Html.each ~id:"test" items
            ~key:(fun x -> x)
            (fun x -> Html.span ~children:[Html.txt x] ())
        in
        expect s |> to_contain {|data-lv-key="x"|}
      );
    );
  );

  run ~source_file:__FILE__ () |> exit_with_result
