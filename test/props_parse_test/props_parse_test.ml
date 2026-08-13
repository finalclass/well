open Well_test

module P = Component_access.Props

let () =
  describe "Well.Web Props decl metadata" (fun () ->
    it "marks scalars observable and complex/list not" (fun () ->
      let s = P.string "label" ~on:(fun v -> v) () in
      let b = P.bool "flag" ~on:(fun v -> string_of_bool v) () in
      let i = P.int "n" ~on:(fun v -> string_of_int v) () in
      let l = P.list "items" ~eq:String.equal ~on:(fun _ -> "x") in
      let o = P.of_eq "obj" ~eq:( = ) ~on:(fun _ -> "y") in
      let a =
        P.attr_or_prop "payload"
          ~of_string:(fun s -> Some s)
          ~of_js:(fun _ -> None)
          ~eq:String.equal
          ~on:(fun v -> v)
          ()
      in
      expect (P.is_observable s) |> to_be_true;
      expect (P.is_observable b) |> to_be_true;
      expect (P.is_observable i) |> to_be_true;
      expect (P.is_observable l) |> to_be_false;
      expect (P.is_observable o) |> to_be_false;
      expect (P.is_observable a) |> to_be_true;
      expect (P.name s) |> to_equal_string "label";
      expect (P.name a) |> to_equal_string "payload";
      expect (P.kind l = P.List) |> to_be_true;
      expect (P.kind o = P.Complex) |> to_be_true;
      expect (P.kind s = P.String) |> to_be_true;
      expect (P.kind a = P.Attr_or_prop) |> to_be_true
    )
  );

  run ~source_file:__FILE__ () |> exit_with_result
