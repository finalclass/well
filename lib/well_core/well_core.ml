let version = "0.1.0-dev"

let run f =
  Eio_main.run @@ fun env ->
  f env
