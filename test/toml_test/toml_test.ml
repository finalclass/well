open Well_test
open Otoml

let value_at document path = find document Fun.id path

let serialize_and_parse document =
  let text = Well.Toml.to_string document in
  let parsed = Well.Toml.from_string text in
  expect (Well.Toml.to_string parsed) |> to_equal_string text ;
  (text, parsed)

let () =
  describe "Well.Toml serialization" (fun () ->
      it
        "keeps scalar fields in their owning table after nested sections"
        (fun () ->
          let document =
            table
              [ ( "nested"
                , table
                    [ ("child", table [("value", integer 1)])
                    ; ("label", string "nested") ] )
              ; ("name", string "root")
              ; ("enabled", boolean true) ]
          in
          let _, parsed = serialize_and_parse document in
          expect (Well.Toml.get_string parsed ["name"] = Some "root")
          |> to_be_true ;
          expect (Well.Toml.get_bool parsed ["enabled"] = Some true)
          |> to_be_true ;
          expect
            (Well.Toml.get_string parsed ["nested"; "label"] = Some "nested")
          |> to_be_true ;
          expect (Well.Toml.get_int parsed ["nested"; "child"; "value"] = Some 1)
          |> to_be_true ) ;
      it
        "writes ordered arrays of tables and their nested collections"
        (fun () ->
          let document =
            table
              [ ( "rows"
                , array
                    [ table
                        [ ("children", array [table [("id", integer 3)]])
                        ; ("id", integer 1) ]
                    ; table [("id", integer 2)] ] )
              ; ("version", integer 4) ]
          in
          let text, parsed = serialize_and_parse document in
          expect text |> to_contain "[[rows]]" ;
          expect text |> to_contain "[[rows.children]]" ;
          expect (Well.Toml.get_int parsed ["version"] = Some 4) |> to_be_true ;
          let rows = get_array Fun.id (value_at parsed ["rows"]) in
          expect
            ( List.map (fun row -> get_integer (value_at row ["id"])) rows
            = [1; 2] )
          |> to_be_true ;
          let children =
            get_array Fun.id (value_at (List.hd rows) ["children"])
          in
          expect (get_integer (value_at (List.hd children) ["id"]))
          |> to_equal_int 3 ) ;
      it
        "preserves empty arrays, scalar arrays, mixed arrays and inline tables"
        (fun () ->
          let escaped = "quotes \" and backslash \\ and newline\n" in
          let document =
            table
              [ ("empty", array [])
              ; ("values", array [integer 2; integer 1])
              ; ("mixed", array [string "value"; integer 7])
              ; ("inline", inline_table [("text", string escaped)])
              ; ("inline_rows", array [inline_table [("id", integer 5)]])
              ; ("empty_table", table []) ]
          in
          let text, parsed = serialize_and_parse document in
          expect (value_at parsed ["empty"] = TomlArray []) |> to_be_true ;
          expect (value_at parsed ["values"] = TomlArray [integer 2; integer 1])
          |> to_be_true ;
          expect
            (value_at parsed ["mixed"] = TomlArray [string "value"; integer 7])
          |> to_be_true ;
          expect (Well.Toml.get_string parsed ["inline"; "text"] = Some escaped)
          |> to_be_true ;
          expect (Well.Toml.get_table parsed ["empty_table"] = Some [])
          |> to_be_true ;
          expect text |> not_ |> to_contain "[[inline_rows]]" ;
          let rows = get_array Fun.id (value_at parsed ["inline_rows"]) in
          expect (get_integer (value_at (List.hd rows) ["id"]))
          |> to_equal_int 5 ) ;
      it
        "preserves explicit table arrays and writes the same text to files"
        (fun () ->
          let document =
            table
              [ ("rows", TomlTableArray [table [("id", integer 9)]])
              ; ("name", string "file-test") ]
          in
          let text, _ = serialize_and_parse document in
          let path = Filename.temp_file "well-toml-test-" ".toml" in
          Fun.protect
            ~finally:(fun () -> Sys.remove path)
            (fun () ->
              Well.Toml.to_file path document ;
              let ic = open_in_bin path in
              let written =
                Fun.protect
                  ~finally:(fun () -> close_in_noerr ic)
                  (fun () -> really_input_string ic (in_channel_length ic))
              in
              expect written |> to_equal_string text ;
              expect
                ( Well.Toml.get_string (Well.Toml.from_file path) ["name"]
                = Some "file-test" )
              |> to_be_true ) ) ) ;
  run ~source_file:__FILE__ () |> exit_with_result
