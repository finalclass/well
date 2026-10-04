let () =
  Well_web.component ~module_:(module Cap_stream) ~tag_name:"cap-stream" () ;
  Well_web.component ~module_:(module Cap_repl) ~tag_name:"cap-repl" ()
