# Well-patched `ocamlformat-mlx`

Stock [ocamlformat-mlx](https://github.com/ocaml-mlx/ocamlformat-mlx) rejects Well JSX
attribute names that are OCaml keywords (`type=`, `for=`) or HTML names with `-` / `:`
(`aria-label`, `data-id`). Build and typecheck still work via `well-mlx-pp`; only the
formatter / ocamllsp format-on-save path breaks.

This directory ships lexer patches (same idea as `well_mlx_pp/lexer.mll`: track open JSX
tags and treat attr names as plain `LIDENT`) plus `build.sh`.

## Build & install

```bash
# needs opam package sources once:
opam install ocamlformat-mlx

cd /path/to/well
./tools/ocamlformat-mlx/build.sh
make install   # copies to ~/.local/bin/ocamlformat-mlx (and well tooling)
```

Emacs/Doom must put `~/.local/bin` **before** `$OPAM_SWITCH_PREFIX/bin` on `exec-path`
so ocamllsp picks the Well binary (ocamllsp hardcodes the name `ocamlformat-mlx`).

Upstream pin: ocamlformat-mlx **0.28.1.2** (override with `OCAMLFORMAT_MLX_VERSION` /
`OCAMLFORMAT_MLX_SRC`).

## PATH / ocamllsp

`ocamllsp` resolves `ocamlformat-mlx` with `Bin.which` on the process PATH.
`envrc` / `opam env` often put `$OPAM_SWITCH_PREFIX/bin` **before** `~/.local/bin`,
so install also overwrites the switch binary (stock saved once as
`ocamlformat-mlx.stock`).

Doom additionally formats `.mlx` via absolute `~/.local/bin/ocamlformat-mlx`
and disables ocamllsp documentFormatting for `mlx-mode`.
