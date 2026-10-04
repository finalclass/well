(lang dune 3.17)
(using menhir 3.0)

(dialect
 (name mlx)
 (implementation
  (extension mlx)
  (merlin_reader well)
  (preprocess
   (run well-mlx-pp %{input-file}))))

; Cyrograf is pinned to a published, reachable revision on
; github.com/finalclass/cyrograf (main). Do not replace with a home path,
; placeholder SHA or a rewritten single root commit.
(pin
 (url "git+https://github.com/finalclass/cyrograf#8f07d974c633054ec44196bedab5e130b454c129")
 (package
  (name cyrograf)))

(package
 (name well)
 (version 1.3.1)
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
  (x509 (>= 1.2.0))
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
  (js_of_ocaml-ppx (= 6.2.0))
  cyrograf))
