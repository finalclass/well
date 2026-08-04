#!/usr/bin/env bash
# Build Well-patched ocamlformat-mlx (JSX attrs: keywords + hyphen/colon names).
# Output: tools/ocamlformat-mlx/ocamlformat-mlx (binary)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
WELL_ROOT="$(cd "$ROOT/../.." && pwd)"
OUT="$ROOT/ocamlformat-mlx"
VERSION="${OCAMLFORMAT_MLX_VERSION:-0.28.1.2}"
WORK="${OCAMLFORMAT_MLX_WORK:-${TMPDIR:-/tmp}/well-ocamlformat-mlx-build}"

log() { printf '==> %s\n' "$*"; }

find_source() {
  # 1) Explicit override
  if [[ -n "${OCAMLFORMAT_MLX_SRC:-}" && -f "$OCAMLFORMAT_MLX_SRC/vendor/parser-extended/lexer.mll" ]]; then
    echo "$OCAMLFORMAT_MLX_SRC"
    return
  fi
  # 2) opam switch sources (after opam install / source ocamlformat-mlx)
  local opam_switch
  opam_switch="$(opam var prefix 2>/dev/null || true)"
  if [[ -n "$opam_switch" ]]; then
    local cand
    for cand in \
      "$opam_switch/../.opam-switch/sources/ocamlformat-mlx.${VERSION}" \
      "$opam_switch/../.opam-switch/sources/ocamlformat-mlx-lib.${VERSION}" \
      "$HOME/.opam"/*/".opam-switch/sources/ocamlformat-mlx.${VERSION}"; do
      if [[ -f "${cand}/vendor/parser-extended/lexer.mll" ]]; then
        # resolve glob / relative
        echo "$(cd "$cand" && pwd)"
        return
      fi
    done
  fi
  return 1
}

SRC="$(find_source || true)"
if [[ -z "${SRC}" ]]; then
  log "ocamlformat-mlx ${VERSION} sources not found."
  log "Install once:  opam install ocamlformat-mlx"
  log "Or set OCAMLFORMAT_MLX_SRC=/path/to/ocamlformat-mlx-checkout"
  exit 1
fi

log "source: $SRC"
rm -rf "$WORK"
mkdir -p "$WORK"
cp -a "$SRC"/. "$WORK"/

# Patches are git-style a/ b/ — apply with -p1 from WORK root
apply_one() {
  local patch="$1"
  log "apply $(basename "$patch")"
  # Try -p1 (a/vendor...), then -p0 (vendor...)
  if patch -p1 --forward --dry-run -d "$WORK" <"$patch" >/dev/null 2>&1; then
    patch -p1 --forward -d "$WORK" <"$patch"
  elif patch -p0 --forward --dry-run -d "$WORK" <"$patch" >/dev/null 2>&1; then
    patch -p0 --forward -d "$WORK" <"$patch"
  else
    # already applied?
    if grep -q 'jsx_open_tag' "$WORK/vendor/parser-extended/lexer.mll" 2>/dev/null; then
      log "already patched, skip $(basename "$patch")"
      return 0
    fi
    log "FAILED to apply $patch"
    exit 1
  fi
}

apply_one "$ROOT/parser-extended-lexer.patch"
apply_one "$ROOT/parser-standard-lexer.patch"

log "dune build"
(
  cd "$WORK"
  # Prefer project dune if present, else system
  if [[ -x ./vendor/dune ]]; then
    DUNE=./vendor/dune
  else
    DUNE=dune
  fi
  $DUNE build bin/ocamlformat/main.exe
)

BIN="$WORK/_build/default/bin/ocamlformat/main.exe"
if [[ ! -x "$BIN" ]]; then
  log "build failed: missing $BIN"
  exit 1
fi

cp -fL "$BIN" "$OUT"
chmod 755 "$OUT"
log "built $OUT"
"$OUT" --version || true
