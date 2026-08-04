(lang dune 3.17)
(using menhir 3.0)

(dialect
 (name mlx)
 (implementation
  (extension mlx)
  (merlin_reader well)
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
  merlin-extend
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
  camlzip
  (js_of_ocaml (= 6.2.0))
  (js_of_ocaml-compiler (= 6.2.0))
  (js_of_ocaml-ppx (= 6.2.0))))
