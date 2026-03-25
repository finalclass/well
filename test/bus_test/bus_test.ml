open Well_test

let () =
  describe "MessageBus" (fun () ->

    describe "publish and subscribe" (fun () ->
      it "subscriber receives published event" (fun () ->
        Well.MessageBus.init ();
        let received = ref "" in
        let _sub = Well.MessageBus.subscribe "test.chan" (fun ev ->
          received := Yojson.Safe.to_string ev.payload
        ) in
        let _id = Well.MessageBus.publish "test.chan" (`String "hello") in
        expect !received |> to_equal_string {|"hello"|}
      );
      it "publish returns positive event id" (fun () ->
        Well.MessageBus.init ();
        let id = Well.MessageBus.publish "test.id" (`Int 1) in
        expect id |> to_be_greater_than 0
      );
      it "ephemeral publish returns 0" (fun () ->
        Well.MessageBus.init ();
        let id = Well.MessageBus.publish ~ephemeral:true "eph.chan" (`Int 1) in
        expect id |> to_equal_int 0
      );
      it "ephemeral events are still delivered" (fun () ->
        Well.MessageBus.init ();
        let received = ref false in
        let _sub = Well.MessageBus.subscribe "eph.delivery" (fun _ev ->
          received := true
        ) in
        let _id = Well.MessageBus.publish ~ephemeral:true "eph.delivery" (`Null) in
        expect !received |> to_be_true
      );
      it "unsubscribe stops delivery" (fun () ->
        Well.MessageBus.init ();
        let count = ref 0 in
        let sub = Well.MessageBus.subscribe "unsub.chan" (fun _ev ->
          incr count
        ) in
        let _ = Well.MessageBus.publish "unsub.chan" (`Null) in
        expect !count |> to_equal_int 1;
        Well.MessageBus.unsubscribe sub;
        let _ = Well.MessageBus.publish "unsub.chan" (`Null) in
        expect !count |> to_equal_int 1
      );
    );

    describe "wildcard matching" (fun () ->
      it "trailing * matches prefix" (fun () ->
        Well.MessageBus.init ();
        let received = ref 0 in
        let _sub = Well.MessageBus.subscribe "wild.*" (fun _ev ->
          incr received
        ) in
        let _ = Well.MessageBus.publish "wild.a" (`Null) in
        let _ = Well.MessageBus.publish "wild.b" (`Null) in
        let _ = Well.MessageBus.publish "other" (`Null) in
        expect !received |> to_equal_int 2
      );
      it "exact pattern only matches exact" (fun () ->
        Well.MessageBus.init ();
        let received = ref 0 in
        let _sub = Well.MessageBus.subscribe "exact" (fun _ev ->
          incr received
        ) in
        let _ = Well.MessageBus.publish "exact" (`Null) in
        let _ = Well.MessageBus.publish "exact.sub" (`Null) in
        expect !received |> to_equal_int 1
      );
    );

    describe "replay" (fun () ->
      it "replays persisted events" (fun () ->
        Well.MessageBus.init ();
        let id1 = Well.MessageBus.publish "replay.chan" (`String "first") in
        let _id2 = Well.MessageBus.publish "replay.chan" (`String "second") in
        let replayed = ref [] in
        Well.MessageBus.replay ~since_id:(id1 - 1) "replay.chan" (fun ev ->
          replayed := (Yojson.Safe.to_string ev.payload) :: !replayed
        );
        expect (List.length !replayed) |> to_be_greater_than 0
      );
      it "does not replay ephemeral events" (fun () ->
        Well.MessageBus.init ();
        let _ = Well.MessageBus.publish ~ephemeral:true "eph.replay" (`String "gone") in
        let replayed = ref 0 in
        Well.MessageBus.replay "eph.replay" (fun _ev ->
          incr replayed
        );
        expect !replayed |> to_equal_int 0
      );
    );

    describe "prune" (fun () ->
      it "deletes old events" (fun () ->
        Well.MessageBus.init ();
        let id1 = Well.MessageBus.publish "prune.chan" (`Int 1) in
        let _id2 = Well.MessageBus.publish "prune.chan" (`Int 2) in
        let deleted = Well.MessageBus.prune ~keep_since_id:id1 () in
        expect deleted |> to_be_greater_than 0
      );
    );

    describe "typed topics" (fun () ->
      let my_topic =
        Well.MessageBus.topic "typed.test"
          (fun s -> `String s)
          (function `String s -> Ok s | _ -> Error "expected string")
      in

      it "typed publish and subscribe" (fun () ->
        Well.MessageBus.init ();
        let received = ref "" in
        let _sub = Well.MessageBus.subscribe_typed my_topic (fun ev ->
          received := ev.value
        ) in
        let _id = Well.MessageBus.publish_typed my_topic "typed hello" in
        expect !received |> to_equal_string "typed hello"
      );
      it "typed replay" (fun () ->
        Well.MessageBus.init ();
        let _id = Well.MessageBus.publish_typed my_topic "for replay" in
        let found = ref false in
        Well.MessageBus.replay_typed my_topic (fun ev ->
          if ev.value = "for replay" then found := true
        );
        expect !found |> to_be_true
      );
    );

    describe "Well re-exports" (fun () ->
      it "Well.topic creates a topic" (fun () ->
        let t = Well.topic "reexport.test"
          (fun n -> `Int n)
          (function `Int n -> Ok n | _ -> Error "bad")
        in
        expect (Well.topic_name t) |> to_equal_string "reexport.test"
      );
      it "Well.publish and Well.subscribe work" (fun () ->
        let t = Well.topic "reexport.ps"
          (fun n -> `Int n)
          (function `Int n -> Ok n | _ -> Error "bad")
        in
        Well.MessageBus.init ();
        let received = ref 0 in
        let _sub = Well.subscribe t (fun ev -> received := ev.value) in
        Well.publish t 42;
        expect !received |> to_equal_int 42
      );
    );
  );

  run ~source_file:__FILE__ () |> exit_with_result
