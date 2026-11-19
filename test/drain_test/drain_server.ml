let append line =
  let channel =
    open_out_gen [Open_append; Open_creat; Open_wronly] 0o644 "step.log"
  in
  output_string channel (line ^ "\n");
  close_out channel

let () =
  Mirage_crypto_rng_unix.use_default ();
  let port = int_of_string Sys.argv.(1) in
  Well.drain_timeout (float_of_string Sys.argv.(2));
  Well.get "/ready" (fun _ -> `Text "ready");
  Well.get "/slow/:seconds" (fun req ->
    Well.sleep (float_of_string (List.assoc "seconds" req.params));
    `Text "done");
  Well.every ~name:"step" ~sleep:0.01 (fun () ->
    append (if Well.Drain.requested () then "late" else "start");
    Well.sleep 0.3;
    append "end");
  Well.run ~port ~workers:2 ()
