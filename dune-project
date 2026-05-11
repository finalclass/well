(lang dune 3.17)
(using menhir 3.0)

(dialect
 (name mlx)
 (implementation
  (extension mlx)
  (merlin_reader mlx)
  (preprocess
   (run well-mlx-pp %{input-file}))))

(package
 (name well)
 (version 1.3.0)
 (synopsis "Full-stack OCaml web framework")
 (depends
  (ocaml (>= 5.4))
  mlx
  menhir
  menhirLib
  eio
  eio_main
  yojson
  sqlite3
  tls-eio
  mirage-crypto-pk
  digestif
  base64
  zarith
  ppxlib
  ppx_deriving
  ppx_deriving_yojson
  otoml
  camlzip))
