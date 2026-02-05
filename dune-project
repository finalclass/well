(lang dune 3.17)

(dialect
 (name mlx)
 (implementation
  (extension mlx)
  (merlin_reader mlx)
  (preprocess
   (run mlx-pp %{input-file}))))

(package
 (name well)
 (synopsis "Full-stack OCaml web framework")
 (depends
  (ocaml (>= 5.2))
  mlx
  eio
  eio_main
  yojson
  sqlite3))
