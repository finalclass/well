open Well_test

module C = Component_access.Cmd

let () =
  describe "Well.Web Cmd" (fun () ->
    it "is_none treats None and empty/nested batch of nones" (fun () ->
      expect (C.is_none C.none) |> to_be_true;
      expect (C.is_none (C.batch [])) |> to_be_true;
      expect (C.is_none (C.batch [ C.none; C.batch [ C.none ] ])) |> to_be_true;
      expect (C.is_none (C.msg 1)) |> to_be_false;
      expect (C.is_none (C.batch [ C.none; C.msg 2 ])) |> to_be_false
    );

    it "iter walks batch in order" (fun () ->
      let acc = ref [] in
      let cmd =
        C.batch
          [
            C.msg 1;
            C.batch [ C.msg 2; C.msg 3 ];
            C.none;
            C.emit "e";
            C.focus "#x";
            C.emit_dom ~name:"want-remind" ();
            C.send ~addr:"project-docs" 7;
          ]
      in
      C.iter cmd
        ~none:(fun () -> acc := "none" :: !acc)
        ~msg:(fun m -> acc := ("msg:" ^ string_of_int m) :: !acc)
        ~emit:(fun e -> acc := ("emit:" ^ e) :: !acc)
        ~emit_dom:(fun ~name ~detail:_ -> acc := ("dom:" ^ name) :: !acc)
        ~focus:(fun s -> acc := ("focus:" ^ s) :: !acc)
        ~perform:(fun _ -> acc := "perform" :: !acc)
        ~send:(fun ~addr packed ->
          acc :=
            ("send:" ^ addr ^ ":" ^ string_of_int (Obj.obj packed)) :: !acc);
      let got = String.concat "," (List.rev !acc) in
      expect got
      |> to_equal_string
           "msg:1,msg:2,msg:3,none,emit:e,focus:#x,dom:want-remind,send:project-docs:7"
    );

    it "perform constructor is not is_none and iter invokes run" (fun () ->
      let hit = ref false in
      let cmd =
        C.perform (fun ~dispatch ->
          hit := true;
          dispatch 42)
      in
      expect (C.is_none cmd) |> to_be_false;
      let got = ref 0 in
      C.iter cmd
        ~none:(fun () -> ())
        ~msg:(fun _ -> ())
        ~emit:(fun _ -> ())
        ~emit_dom:(fun ~name:_ ~detail:_ -> ())
        ~focus:(fun _ -> ())
        ~perform:(fun f -> f ~dispatch:(fun m -> got := m))
        ~send:(fun ~addr:_ _ -> ());
      expect !hit |> to_be_true;
      expect !got |> to_equal_int 42
    );

    it "send is not is_none and iter yields addr plus packed payload" (fun () ->
      expect (C.is_none (C.send ~addr:"loop-a" 1)) |> to_be_false;
      let got_addr = ref "" in
      let got_n = ref 0 in
      C.iter
        (C.send ~addr:"loop-a" 9)
        ~none:(fun () -> ())
        ~msg:(fun _ -> ())
        ~emit:(fun _ -> ())
        ~emit_dom:(fun ~name:_ ~detail:_ -> ())
        ~focus:(fun _ -> ())
        ~perform:(fun _ -> ())
        ~send:(fun ~addr packed ->
          got_addr := addr;
          got_n := Obj.obj packed);
      expect !got_addr |> to_equal_string "loop-a";
      expect !got_n |> to_equal_int 9
    )
  );

  run ~source_file:__FILE__ () |> exit_with_result
