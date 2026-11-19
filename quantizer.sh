#!/usr/bin/env bash
# Nerun's Imatrix GGUF Quantizer: imatrix quants, mmproj, MTP head and model card for any
# Hugging Face model, using prebuilt llama.cpp.
# Copyright (c) 2026 Daniel Dias Rodrigues (a.k.a. "Nerun")
# SPDX-License-Identifier: MIT
#
# Usage: ./quantizer.sh [options] [stage ...]
#   --config FILE        config file (default: ./quantizer.conf in the working directory)
#   --llama-build bNNNN  override LLAMA_BUILD from the config
#   --init               write a commented template config and exit
# Stages: setup download convert mmproj imatrix quant mtp card   (default: all, in this order)
#         show           print the effective configuration and exit
# Stages that the config disables (no mmproj, MTP_MODE=none) do nothing.
# Every output is written to a temp name and renamed when complete, so an interrupted
# run can simply be started again: finished files are skipped.
set -euo pipefail

WORK="$PWD"
log() { printf '\n==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- template config
write_template() {
  cat > "$1" <<'CONFEOF'
# quantizer.conf -- sourced as bash by quantizer.sh (arrays use ( ... ) syntax).

# ---- model
# Hugging Face repo id or URL (https://huggingface.co/owner/name also accepted).
REPO="owner/model-name"
# Base name of every output file: $NAME-bf16.gguf, $NAME.i1-Q4_K_M.gguf, ...
NAME="model-name"

# ---- llama.cpp (prebuilt release, never upgraded automatically)
LLAMA_BUILD="b12503"
# Oldest llama.cpp build that can load the output. Used only in the model card note;
# nothing is downloaded or run with it. Empty means the same as LLAMA_BUILD.
MIN_LLAMA_BUILD=""
LLAMA_ASSET="ubuntu-vulkan-x64"   # e.g. ubuntu-x64 for CPU only
# Where llama.cpp, the converter and the Python venv live. Point several model
# folders at the same directory to share one installation.
TOOLS_DIR="$WORK"

# ---- imatrix
IMATRIX_SRC_TYPE="q8_0"           # model used to compute the imatrix
IMATRIX_NGL=99                    # GPU layers for llama-imatrix; lower it if VRAM runs out
CALIB_URL="https://gist.githubusercontent.com/bartowski1182/eb213dccb3571f863da82e99418f81e8/raw/calibration_datav3.txt"

# ---- quants (file name: $NAME.$QUANT_TAG-<type>.gguf)
QUANT_TAG="i1"
QUANTS=(
    IQ1_S IQ1_M
    IQ2_XXS IQ2_XS IQ2_S IQ2_M Q2_K_S Q2_K
    IQ3_XXS IQ3_XS IQ3_S Q3_K_S IQ3_M Q3_K_M Q3_K_L
    IQ4_XS Q4_K_S IQ4_NL Q4_0 Q4_1 Q4_K_M
    Q5_K_S Q5_K_M
    Q6_K
)

# ---- vision projector; empty list = model has no vision, skip
MMPROJ_TYPES=()                   # e.g. (f16 q8_0)

# ---- MTP head
# none     : do nothing
# download : fetch a ready head GGUF (MTP_HEAD_FILES)
# build    : convert a donor GGUF (full model + MTP block) from the checkpoint;
#            if the checkpoint has no mtp.* tensors they are taken from MTP_BASE_REPO
MTP_MODE="none"
# Entries are file names inside MTP_HEAD_REPO, or full Hugging Face file URLs
# (https://huggingface.co/owner/repo/blob/main/file.gguf), in which case
# MTP_HEAD_REPO is not needed.
MTP_HEAD_REPO=""
MTP_HEAD_FILES=()
MTP_BASE_REPO=""
MTP_DONOR_TYPE="q8_0"
# Keep the MTP block out of the main BF16/quants (needed for imatrix; graft it later).
MAIN_NO_MTP="yes"

# ---- model card: the "card" stage writes gguf/README.md for the Hugging Face repo
CARD="yes"                        # yes or no
CARD_LICENSE=""                   # empty = take "license:" from the original model card
CARD_TAGS=()                      # extra front-matter tags, e.g. (qwen3.5 code vision)
CARD_INCLUDE_ORIGINAL="yes"       # append the original model card at the end
CARD_SCRIPT_URL="https://github.com/nerun/imatrix-gguf-quantizer"   # shown in the card; empty = not mentioned
CARD_TEMPLATE=""                  # custom markdown template; empty = built-in (see README)
CONFEOF
}

# ---------------------------------------------------------------- arguments
CONF="$WORK/quantizer.conf"
CLI_LLAMA_BUILD=""
STAGES=()
while [ $# -gt 0 ]; do
  case "$1" in
    --config)        [ $# -ge 2 ] || die "--config needs a file"; CONF="$2"; shift 2 ;;
    --config=*)      CONF="${1#*=}"; shift ;;
    --llama-build)   [ $# -ge 2 ] || die "--llama-build needs a value (e.g. b12503)"
                     CLI_LLAMA_BUILD="$2"; shift 2 ;;
    --llama-build=*) CLI_LLAMA_BUILD="${1#*=}"; shift ;;
    --init)          [ -e "$CONF" ] && die "$CONF already exists"
                     write_template "$CONF"; echo "Template written to $CONF"; exit 0 ;;
    -h|--help)       sed -n '2,/^set -/{/^set -/!p}' "$0"; exit 0 ;;
    -*)              die "unknown option: $1" ;;
    *)               STAGES+=("$1"); shift ;;
  esac
done

# ---------------------------------------------------------------- defaults, then config
REPO=""
NAME=""
LLAMA_BUILD="b12503"
MIN_LLAMA_BUILD=""
LLAMA_ASSET="ubuntu-vulkan-x64"
TOOLS_DIR="$WORK"
THREADS="${THREADS:-$(nproc)}"
IMATRIX_SRC_TYPE="q8_0"
IMATRIX_NGL=99
CALIB_URL="https://gist.githubusercontent.com/bartowski1182/eb213dccb3571f863da82e99418f81e8/raw/calibration_datav3.txt"
QUANT_TAG="i1"
QUANTS=(Q4_K_M)
MMPROJ_TYPES=()
MTP_MODE="none"
MTP_HEAD_REPO=""
MTP_HEAD_FILES=()
MTP_BASE_REPO=""
MTP_DONOR_TYPE="q8_0"
MAIN_NO_MTP="yes"
CARD="yes"
CARD_LICENSE=""
CARD_TAGS=()
CARD_INCLUDE_ORIGINAL="yes"
CARD_SCRIPT_URL=""
CARD_TEMPLATE=""

[ -f "$CONF" ] || die "config not found: $CONF (create one with: $0 --init)"
# shellcheck source=/dev/null
source "$CONF"
[ -n "$CLI_LLAMA_BUILD" ] && LLAMA_BUILD="$CLI_LLAMA_BUILD"

# Accept https://huggingface.co/owner/name[/tree/...] as well as owner/name.
hf_repo() {
  local r="$1"
  r="${r#https://huggingface.co/}"; r="${r#http://huggingface.co/}"
  r="${r%%/tree/*}"; r="${r%%/blob/*}"; r="${r%%/resolve/*}"; r="${r%/}"
  printf '%s' "$r"
}
is_repo() { [[ $1 =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; }

REPO="$(hf_repo "$REPO")"
[ -n "$MTP_HEAD_REPO" ] && MTP_HEAD_REPO="$(hf_repo "$MTP_HEAD_REPO")"
[ -n "$MTP_BASE_REPO" ] && MTP_BASE_REPO="$(hf_repo "$MTP_BASE_REPO")"

# ---------------------------------------------------------------- validation
is_repo "$REPO" || die "REPO must be owner/name or a huggingface.co URL (got '$REPO')"
[ -n "$NAME" ] || die "NAME is not set in $CONF"
[[ $LLAMA_BUILD =~ ^b[0-9]+$ ]] || die "LLAMA_BUILD must look like b12503 (got '$LLAMA_BUILD')"
MIN_LLAMA_BUILD="${MIN_LLAMA_BUILD:-$LLAMA_BUILD}"
[[ $MIN_LLAMA_BUILD =~ ^b[0-9]+$ ]] || die "MIN_LLAMA_BUILD must look like b12343 (got '$MIN_LLAMA_BUILD')"
[ "${MIN_LLAMA_BUILD#b}" -le "${LLAMA_BUILD#b}" ] || die "MIN_LLAMA_BUILD ($MIN_LLAMA_BUILD) cannot be newer than LLAMA_BUILD ($LLAMA_BUILD)"
[ ${#QUANTS[@]} -gt 0 ] || die "QUANTS is empty"
case "$MTP_MODE" in
  none) ;;
  download)
    [ ${#MTP_HEAD_FILES[@]} -gt 0 ] || die "MTP_MODE=download needs MTP_HEAD_FILES"
    for e in "${MTP_HEAD_FILES[@]}"; do
      [[ $e == https://* ]] || is_repo "$MTP_HEAD_REPO" \
        || die "MTP head entry '$e' is a plain file name but MTP_HEAD_REPO is not set"
    done ;;
  build)
    [ -z "$MTP_BASE_REPO" ] || is_repo "$MTP_BASE_REPO" || die "bad MTP_BASE_REPO '$MTP_BASE_REPO'" ;;
  *) die "MTP_MODE must be none, download or build (got '$MTP_MODE')" ;;
esac

[[ $CARD == yes || $CARD == no ]] || die "CARD must be yes or no (got '$CARD')"
[ -z "$CARD_TEMPLATE" ] || [ -f "$CARD_TEMPLATE" ] || die "CARD_TEMPLATE not found: $CARD_TEMPLATE"

# ---------------------------------------------------------------- derived paths
LLAMA="$TOOLS_DIR/llama.cpp"
VENV="$TOOLS_DIR/venv"
BIN_DIR="$TOOLS_DIR/llama-bin"
TOOLS="$TOOLS_DIR/mtp_tools.py"
MODEL_DIR="$WORK/hf/$NAME"
BASE_DIR="$WORK/hf/${MTP_BASE_REPO##*/}"
MERGED_DIR="$WORK/hf/${NAME}-mtp-merged"
OUT="$WORK/gguf"
CALIB="$WORK/calibration.txt"
[ -f "$WORK/calibration_datav3.txt" ] && CALIB="$WORK/calibration_datav3.txt"  # older runs
IMATRIX="$OUT/$NAME.imatrix.gguf"
PY="$VENV/bin/python"
HF="$VENV/bin/hf"
CONVERT="$LLAMA/convert_hf_to_gguf.py"

mkdir -p "$OUT" "$WORK/hf" "$TOOLS_DIR"
BIN="$(cat "$TOOLS_DIR/.llama_bin" 2>/dev/null || true)"   # set by the setup stage

# ---------------------------------------------------------------- helpers
# build FINAL cmd... : skip if FINAL exists; otherwise run cmd with @OUT@ replaced by a
# temporary name and rename it to FINAL only on success, so Ctrl+C never leaves a
# truncated file under the final name. The temp name keeps the .gguf extension.
build() {
  local final="$1" tmp; shift
  [ -f "$final" ] && { echo "skip $(basename "$final")"; return 0; }
  tmp="$(dirname "$final")/.part-$(basename "$final")"
  rm -f "$tmp"
  CUR_TMP="$tmp"
  "${@//@OUT@/$tmp}" || return 1   # explicit: do not rely on set -e inside functions
  mv "$tmp" "$final"
  CUR_TMP=""
}

# Remove the unfinished temp file on Ctrl+C or error (an interrupted step restarts from zero anyway).
CUR_TMP=""
cleanup() { if [ -n "$CUR_TMP" ]; then rm -f "$CUR_TMP"; fi; }
trap cleanup EXIT

need_bin() {
  [ -n "$BIN" ] && [ -x "$BIN/llama-quantize" ] || die "llama.cpp binaries not found; run the setup stage first"
  # Release binaries link against libllama/libggml shipped in the same directory.
  export LD_LIBRARY_PATH="$BIN${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
}

need_py() {
  [ -x "$PY" ] && [ -f "$CONVERT" ] || die "venv or converter missing; run the setup stage first"
}

has_mtp() {  # true if the checkpoint in $1 already contains mtp.* tensors
  local r
  r="$("$PY" -I "$TOOLS" has-mtp "$1")" || die "could not inspect $1"
  [ "$r" = yes ]
}

# ---------------------------------------------------------------- stages
stage_show() {
  cat <<EOF
config        $CONF
REPO          $REPO
NAME          $NAME
llama.cpp     $LLAMA_BUILD ($LLAMA_ASSET) in $TOOLS_DIR
min build     $MIN_LLAMA_BUILD (model card note only)
imatrix       from $IMATRIX_SRC_TYPE, ngl=$IMATRIX_NGL
quants        $NAME.$QUANT_TAG-{${QUANTS[*]}}.gguf
mmproj        ${MMPROJ_TYPES[*]:-(none)}
MTP           $MTP_MODE${MTP_HEAD_REPO:+ from $MTP_HEAD_REPO}${MTP_BASE_REPO:+ (base: $MTP_BASE_REPO)}
model card    $CARD${CARD_TEMPLATE:+ (template: $CARD_TEMPLATE)}
output        $OUT
EOF
  [ "$MTP_MODE" = download ] && printf 'MTP files     %s\n' "${MTP_HEAD_FILES[@]}"
  return 0
}

stage_setup() {
  local tag="$LLAMA_BUILD" old
  old="$(cat "$TOOLS_DIR/.llama_tag" 2>/dev/null || true)"

  # Reuse an existing download as-is; never fetch a different build on its own.
  if [ -n "$BIN" ] && [ -x "$BIN/llama-quantize" ] && [ -f "$CONVERT" ] && [ -x "$PY" ]; then
    if [ -n "$old" ] && [ "$old" != "$tag" ]; then
      die "llama.cpp $old is installed in $TOOLS_DIR but $tag was requested; set LLAMA_BUILD=$old or delete $BIN_DIR $LLAMA $TOOLS_DIR/.llama_tag"
    fi
    log "Using existing llama.cpp ${old:-(unknown build)} in $BIN"
    need_bin
    return
  fi
  if [ -n "$old" ] && [ "$old" != "$tag" ]; then
    die "partial setup of llama.cpp $old found; set LLAMA_BUILD=$old or delete $BIN_DIR $LLAMA $TOOLS_DIR/.llama_tag"
  fi

  local url="https://github.com/ggml-org/llama.cpp/releases/download/$tag/llama-$tag-bin-$LLAMA_ASSET.tar.gz"
  log "Downloading llama.cpp $tag"
  echo "$url"
  mkdir -p "$BIN_DIR"
  if [ -z "$(find "$BIN_DIR" -name llama-quantize 2>/dev/null)" ]; then
    curl -fL "$url" -o "$TOOLS_DIR/llama-release.tar.gz"
    tar -xzf "$TOOLS_DIR/llama-release.tar.gz" -C "$BIN_DIR"
    rm -f "$TOOLS_DIR/llama-release.tar.gz"
  fi
  echo "$tag" > "$TOOLS_DIR/.llama_tag"
  BIN="$(dirname "$(find "$BIN_DIR" -name llama-quantize | head -n1)")"
  chmod +x "$BIN"/llama-* 2>/dev/null || true
  echo "$BIN" > "$TOOLS_DIR/.llama_bin"
  need_bin
  "$BIN/llama-quantize" --help >/dev/null 2>&1 || [ $? -le 1 ] || die "llama-quantize does not run (missing libs?)"

  # The converter script is not in the binary release: take it from the same tag.
  log "Fetching convert_hf_to_gguf.py and Python deps from tag $tag"
  [ -d "$LLAMA" ] || git clone --depth 1 --branch "$tag" https://github.com/ggml-org/llama.cpp "$LLAMA"
  log "Creating Python venv"
  [ -d "$VENV" ] || python3 -m venv "$VENV"
  "$PY" -m pip install -U pip
  (cd "$LLAMA" && "$PY" -m pip install -r requirements/requirements-convert_hf_to_gguf.txt \
        "huggingface_hub[cli]" safetensors)
}

stage_download() {
  need_py
  log "Downloading $REPO"
  "$HF" download "$REPO" --local-dir "$MODEL_DIR"
}

fetch_base_mtp() {  # only used by stage_mtp when the checkpoint lacks mtp.* tensors
  log "No MTP tensors in $REPO; fetching MTP shard(s) from $MTP_BASE_REPO"
  # --include does not fail if the index is absent (single-file checkpoint).
  "$HF" download "$MTP_BASE_REPO" --include config.json model.safetensors.index.json --local-dir "$BASE_DIR"
  local shards s
  shards="$("$PY" -I "$TOOLS" shards "$BASE_DIR")" || die "could not read $MTP_BASE_REPO index"
  [ -n "$shards" ] || die "$MTP_BASE_REPO lists no mtp.* tensors"
  for s in $shards; do
    "$HF" download "$MTP_BASE_REPO" "$s" --local-dir "$BASE_DIR"
  done
}

stage_convert() {
  need_py; need_bin
  log "Converting text model to BF16 GGUF"
  local extra=() help
  help="$("$PY" "$CONVERT" --help)"
  [ "$MAIN_NO_MTP" = yes ] && [[ $help == *--no-mtp* ]] && extra+=(--no-mtp)
  build "$OUT/$NAME-bf16.gguf" "$PY" "$CONVERT" "$MODEL_DIR" \
      --outtype bf16 --outfile @OUT@ "${extra[@]}"
  log "Creating $IMATRIX_SRC_TYPE copy for imatrix computation"
  build "$OUT/$NAME-$IMATRIX_SRC_TYPE.gguf" "$BIN/llama-quantize" \
      "$OUT/$NAME-bf16.gguf" @OUT@ "${IMATRIX_SRC_TYPE^^}" "$THREADS"
}

stage_mmproj() {
  [ ${#MMPROJ_TYPES[@]} -gt 0 ] || { log "mmproj disabled in config; skipping"; return 0; }
  need_py
  log "Converting mmproj (${MMPROJ_TYPES[*]})"
  local t
  for t in "${MMPROJ_TYPES[@]}"; do
    build "$OUT/mmproj-$NAME-$t.gguf" "$PY" "$CONVERT" "$MODEL_DIR" \
        --mmproj --outtype "$t" --outfile @OUT@
  done
}

stage_imatrix() {
  need_bin
  log "Computing imatrix"
  [ -f "$CALIB" ] || { curl -fL "$CALIB_URL" -o "$CALIB.part" && mv "$CALIB.part" "$CALIB"; }
  build "$IMATRIX" "$BIN/llama-imatrix" \
      -m "$OUT/$NAME-$IMATRIX_SRC_TYPE.gguf" -f "$CALIB" \
      -o @OUT@ -ngl "$IMATRIX_NGL" -t "$THREADS"
}

stage_quant() {
  need_bin
  [ -f "$IMATRIX" ] || die "imatrix not found; run the imatrix stage first"
  log "Quantizing with imatrix"
  local q
  for q in "${QUANTS[@]}"; do
    build "$OUT/$NAME.$QUANT_TAG-$q.gguf" "$BIN/llama-quantize" --imatrix "$IMATRIX" \
        "$OUT/$NAME-bf16.gguf" @OUT@ "$q" "$THREADS"
  done
}

stage_mtp() {
  case "$MTP_MODE" in
    none)     log "MTP disabled in config; skipping" ;;
    download) mtp_download ;;
    build)    mtp_build ;;
  esac
}

mtp_download() {
  need_py
  log "Downloading MTP head"
  local e repo rev file n
  for e in "${MTP_HEAD_FILES[@]}"; do
    if [[ $e == https://* ]]; then
      [[ ${e#https://huggingface.co/} =~ ^([^/]+/[^/]+)/(blob|resolve)/([^/]+)/(.+)$ ]] \
        || die "not a Hugging Face file URL: $e"
      repo="${BASH_REMATCH[1]}"; rev="${BASH_REMATCH[3]}"; file="${BASH_REMATCH[4]%%\?*}"
    else
      repo="$MTP_HEAD_REPO"; rev="main"; file="$e"
    fi
    "$HF" download "$repo" "$file" --revision "$rev" --local-dir "$OUT/mtp-head"
    n="$("$PY" -I "$TOOLS" count-gguf "$LLAMA/gguf-py" "$OUT/mtp-head/$file")" || die "could not read $file"
    [ "$n" -gt 0 ] || die "$file has no MTP/nextn tensors"
    echo "OK: $n MTP/nextn tensors in $file"
  done
}

mtp_build() {
  need_py
  log "Building MTP donor GGUF (full model + MTP block, $MTP_DONOR_TYPE)"
  local src="$MODEL_DIR" donor="$OUT/$NAME-MTP-donor-$MTP_DONOR_TYPE.gguf" n
  if has_mtp "$MODEL_DIR"; then
    echo "Checkpoint contains mtp.* tensors; using them."
  else
    [ -n "$MTP_BASE_REPO" ] || die "$REPO has no mtp.* tensors and MTP_BASE_REPO is not set"
    fetch_base_mtp
    "$PY" -I "$TOOLS" merge "$MODEL_DIR" "$BASE_DIR" "$MERGED_DIR"
    src="$MERGED_DIR"
  fi
  # Newer converters leave MTP out unless --mtp is given.
  local extra=() help
  help="$("$PY" "$CONVERT" --help)"
  [[ $help =~ (^|[^-a-z])--mtp([^-a-z]|$) ]] && extra+=(--mtp)
  build "$donor" "$PY" "$CONVERT" "$src" --outtype "$MTP_DONOR_TYPE" --outfile @OUT@ "${extra[@]}"
  # An older converter silently drops mtp.*; check the result instead of trusting it.
  n="$("$PY" -I "$TOOLS" count-gguf "$LLAMA/gguf-py" "$donor")" || die "could not read $donor"
  [ "$n" -gt 0 ] || die "donor has no MTP/nextn tensors; converter in $LLAMA lacks MTP support"
  echo "Donor OK: $n MTP/nextn tensors in $donor"
}

stage_card() {
  [ "$CARD" = yes ] || { log "model card disabled in config; skipping"; return 0; }
  [ -x "$PY" ] || die "venv missing; run the setup stage first"
  log "Generating model card"
  local args=() q t f
  args+=(--out "$OUT/README.md" --name "$NAME" --repo "$REPO" --llama-build "$LLAMA_BUILD" --min-llama-build "$MIN_LLAMA_BUILD")
  args+=(--imatrix-type "$IMATRIX_SRC_TYPE" --calib-url "$CALIB_URL" --quant-tag "$QUANT_TAG")
  args+=(--main-has-mtp "$([ "$MAIN_NO_MTP" = yes ] && echo no || echo yes)")
  if [ -n "$CARD_TEMPLATE" ]; then args+=(--template "$CARD_TEMPLATE"); fi
  if [ -n "$CARD_LICENSE" ]; then args+=(--license "$CARD_LICENSE"); fi
  if [ -n "$CARD_SCRIPT_URL" ]; then args+=(--script-url "$CARD_SCRIPT_URL"); fi
  if [ "$CARD_INCLUDE_ORIGINAL" = yes ] && [ -f "$MODEL_DIR/README.md" ]; then
    args+=(--original "$MODEL_DIR/README.md")
  fi
  for t in "${CARD_TAGS[@]}"; do args+=(--tag "$t"); done
  for q in "${QUANTS[@]}"; do args+=(--llm "$OUT/$NAME.$QUANT_TAG-$q.gguf=$QUANT_TAG-$q"); done
  # The plain copy used to compute the imatrix is a valid quant too (made without --imatrix)
  args+=(--llm "$OUT/$NAME-$IMATRIX_SRC_TYPE.gguf=${IMATRIX_SRC_TYPE^^} (no imatrix)")
  args+=(--extra "$OUT/$NAME-bf16.gguf=BF16" --extra "$IMATRIX=imatrix")
  for t in "${MMPROJ_TYPES[@]}"; do args+=(--mmproj "$OUT/mmproj-$NAME-$t.gguf=$t"); done
  for f in "$OUT"/mtp-head/*.gguf "$OUT/$NAME-MTP-donor-$MTP_DONOR_TYPE.gguf"; do
    if [ -f "$f" ]; then args+=(--mtp "$f"); fi
  done
  "$PY" -I "$TOOLS" card "${args[@]}"
}

# ---------------------------------------------------------------- helper script
cat > "$TOOLS" <<'PYEOF'
"""Helpers to find and graft an MTP head (mtp.* tensors) into a checkpoint."""
import json
import sys
from pathlib import Path


def is_mtp(name):
    return name.startswith("mtp.") or ".mtp." in name


def distill_keys(d):
    from safetensors import safe_open
    keys = []
    for p in sorted(Path(d).glob("*.safetensors")):
        with safe_open(str(p), "pt") as f:
            keys += [(k, p.name) for k in f.keys()]
    return keys


def base_map(base):
    from safetensors import safe_open
    idx = Path(base) / "model.safetensors.index.json"
    if idx.exists():
        wm = json.loads(idx.read_text())["weight_map"]
        return {k: v for k, v in wm.items() if is_mtp(k)}
    with safe_open(str(Path(base) / "model.safetensors"), "pt") as f:
        return {k: "model.safetensors" for k in f.keys() if is_mtp(k)}


CARD_MARKER = "<!-- generated by quantizer.sh; remove this line to keep manual edits -->"

DEFAULT_CARD = """{{FRONT_MATTER}}

{{MARKER}}

# {{NAME}} GGUF

Weighted/imatrix GGUF quantizations of [{{REPO}}](https://huggingface.co/{{REPO}}), made with llama.cpp {{LLAMA_BUILD}}.

## Files

{{FILE_TABLE}}
{{MMPROJ_SECTION}}{{MTP_SECTION}}{{USAGE}}{{HOW_MADE}}{{LICENSE_SECTION}}{{ORIGINAL_CARD}}
"""


def fmt_size(n):
    if n >= 1024 ** 3:
        return f"{n / 1024 ** 3:.1f} GiB (~{n / 1000 ** 3:.1f} GB)"
    return f"{n / 1024 ** 2:.0f} MiB (~{n / 1000 ** 2:.0f} MB)"


def split_front_matter(text):
    """Split a Hugging Face README into (front matter, body)."""
    if text.startswith("---\n"):
        end = text.find("\n---", 4)
        if end != -1:
            nl = text.find("\n", end + 4)
            body = text[nl + 1:] if nl != -1 else ""
            return text[4:end], body.lstrip("\n")
    return "", text


def card(argv):
    """Generate the model card (README.md) for the published GGUF repository."""
    import argparse
    import os
    import re

    ap = argparse.ArgumentParser(prog="card")
    for opt in ("out", "name", "repo"):
        ap.add_argument(f"--{opt}", required=True)
    for opt in ("llama-build", "min-llama-build", "calib-url", "template", "license", "script-url",
                "original", "quant-tag"):
        ap.add_argument(f"--{opt}", default="")
    ap.add_argument("--imatrix-type", default="q8_0")
    ap.add_argument("--main-has-mtp", default="no")
    for opt in ("tag", "llm", "extra", "mmproj", "mtp"):
        ap.add_argument(f"--{opt}", action="append", default=[])
    a = ap.parse_args(argv)
    missing = []

    def rows(items, labeled=True):
        found = []
        for item in items:
            path, label = (item.rpartition("=")[0], item.rpartition("=")[2]) if labeled else (item, "")
            if labeled and not path:
                path, label = label, ""
            if os.path.isfile(path):
                found.append((os.path.basename(path), label, os.path.getsize(path)))
            else:
                missing.append(os.path.basename(path))
        return found

    def table(rs, label_head=None):
        if not rs:
            return ""
        if label_head:
            lines = [f"| File | {label_head} | Size |", "| ---- | ---- | ---- |"]
            lines += [f"| {f} | {lb} | {fmt_size(s)} |" for f, lb, s in rs]
        else:
            lines = ["| File | Size |", "| ---- | ---- |"]
            lines += [f"| {f} | {fmt_size(s)} |" for f, _, s in rs]
        return "\n".join(lines) + "\n"

    by_size = lambda r: (r[2], r[0])
    llm = sorted(rows(a.llm), key=by_size)
    extra = rows(a.extra)
    mmproj = sorted(rows(a.mmproj), key=by_size)
    mtp = rows(a.mtp, labeled=False)

    # Original model card: reused for the license and appended at the end
    orig_fm, orig_body = "", ""
    if a.original and os.path.isfile(a.original):
        with open(a.original, encoding="utf-8", errors="replace") as f:
            orig_fm, orig_body = split_front_matter(f.read())
    lic = a.license
    if not lic:
        m = re.search(r"^license:\s*(.+?)\s*$", orig_fm, re.M)
        if m:
            lic = m.group(1).strip("'\"")

    tags = []
    for t in ["gguf", "imatrix", "llama.cpp"] + a.tag:
        if t not in tags:
            tags.append(t)
    fm = ["---", "library_name: gguf"]
    if lic:
        fm.append(f"license: {lic}")
    fm += ["base_model:", f"- {a.repo}", "base_model_relation: quantized", "tags:"]
    fm += [f"- {t}" for t in tags] + ["---"]

    cmd = f"llama-server -m {a.name}.{a.quant_tag}-<QUANT>.gguf"
    if mmproj:
        cmd += f" \\\n    --mmproj {mmproj[0][0]}"
    steps = [
        f"Converted to BF16 with `convert_hf_to_gguf.py` (llama.cpp {a.llama_build}).",
        f"Computed the importance matrix with `llama-imatrix` on a {a.imatrix_type.upper()} copy of the model"
        + (f", using the calibration text at <{a.calib_url}>." if a.calib_url else "."),
        "Made every quant from the BF16 file with `llama-quantize --imatrix`.",
    ]
    how = "\n## How it was made\n\n" + "\n".join(f"{i}. {s}" for i, s in enumerate(steps, 1)) + "\n"
    if a.script_url:
        how += f"\nScript: [Nerun's Imatrix GGUF Quantizer]({a.script_url})\n"

    subs = {
        "MARKER": CARD_MARKER,
        "FRONT_MATTER": "\n".join(fm),
        "NAME": a.name,
        "REPO": a.repo,
        "LLAMA_BUILD": a.llama_build,
        "MIN_LLAMA_BUILD": a.min_llama_build or a.llama_build,
        "FILE_TABLE": table(llm + extra, "Quant") or "_No files found yet._\n",
        "MMPROJ_SECTION": (
            "\n## Vision projector (mmproj)\n\n"
            "Load one of these with `--mmproj`, next to any quant above.\n\n"
            + table(mmproj, "Type")) if mmproj else "",
        "MTP_SECTION": (
            "\n## MTP head\n\n" + table(mtp)
            + ("" if a.main_has_mtp == "yes" else
               "\nThe quants listed under Files do not contain the MTP block; "
               "these files hold the MTP head separately.\n")) if mtp else "",
        "USAGE": ("\n## Usage\n\n```sh\n# Replace <QUANT> with the quant of the file you downloaded\n"
                  + cmd + "\n```\n"
                  + f"\nThese files need llama.cpp {a.min_llama_build or a.llama_build} or newer: "
                  "older builds may fail to load them (for example with a missing tensor error).\n"),
        "HOW_MADE": how,
        "LICENSE_SECTION": (
            f"\n## License\n\nThese files are derived from [{a.repo}](https://huggingface.co/{a.repo}) "
            f"and keep its license: {lic}.\n") if lic else "",
    }
    orig_card = ("\n## Original model card\n\nThe model card of the original repository is "
                 "reproduced below for reference.\n\n---\n\n" + orig_body.rstrip() + "\n"
                 ) if orig_body.strip() else ""

    if a.template:
        with open(a.template, encoding="utf-8") as f:
            tpl = f.read()
    else:
        tpl = DEFAULT_CARD
    has_marker = "{{MARKER}}" in tpl
    out = re.sub(r"\{\{(\w+)\}\}", lambda m: subs.get(m.group(1), m.group(0)), tpl)
    out = re.sub(r"\n{3,}", "\n\n", out)
    out = out.replace("{{ORIGINAL_CARD}}", orig_card)  # last, so its text is never touched
    out = out.rstrip() + "\n"
    if not has_marker:
        out += "\n" + CARD_MARKER + "\n"

    # Never overwrite a card that was edited by hand (marker removed)
    target = a.out
    if os.path.exists(target):
        with open(target, encoding="utf-8", errors="replace") as f:
            if CARD_MARKER not in f.read():
                root, ext = os.path.splitext(target)
                target = root + ".generated" + ext
                print(f"note: {a.out} has no generator marker (manual edits?); writing {target} instead")
    tmp = os.path.join(os.path.dirname(target) or ".", ".part-" + os.path.basename(target))
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(out)
    os.replace(tmp, target)
    if missing:
        print(f"note: {len(missing)} listed file(s) not found, left out: {', '.join(missing)}", file=sys.stderr)
    print(f"wrote {target}")


def main():
    cmd = sys.argv[1]
    if cmd == "has-mtp":
        print("yes" if any(is_mtp(k) for k, _ in distill_keys(sys.argv[2])) else "no")
    elif cmd == "shards":
        idx = Path(sys.argv[2]) / "model.safetensors.index.json"
        if not idx.exists():  # single-file checkpoint: the whole file is needed
            print("model.safetensors")
            return
        wm = json.loads(idx.read_text())["weight_map"]
        print("\n".join(sorted({v for k, v in wm.items() if is_mtp(k)})))
    elif cmd == "merge":
        from safetensors import safe_open
        from safetensors.torch import save_file
        distill, base, out = map(Path, sys.argv[2:5])
        out.mkdir(parents=True, exist_ok=True)
        mmap = base_map(base)
        if not mmap:
            sys.exit("no mtp.* tensors found in base checkpoint")
        tensors = {}
        for shard in sorted(set(mmap.values())):
            with safe_open(str(base / shard), "pt") as f:
                for k in f.keys():
                    if is_mtp(k):
                        tensors[k] = f.get_tensor(k)
        save_file(tensors, str(out / "model-mtp.safetensors"), metadata={"format": "pt"})
        weight_map = dict(distill_keys(distill))
        weight_map.update({k: "model-mtp.safetensors" for k in tensors})
        (out / "model.safetensors.index.json").write_text(
            json.dumps({"metadata": {}, "weight_map": weight_map}, indent=2))
        for p in distill.iterdir():  # link everything else (weights, tokenizer, configs)
            if p.name != "model.safetensors.index.json" and not (out / p.name).exists():
                (out / p.name).symlink_to(p.resolve())
        print(f"merged {len(tensors)} mtp tensors into {out}")
    elif cmd == "count-gguf":
        sys.path.insert(0, sys.argv[2])  # use the gguf-py from the same llama.cpp tag
        import gguf
        r = gguf.GGUFReader(sys.argv[3])
        print(sum(1 for t in r.tensors if "nextn" in t.name or "mtp" in t.name))
    elif cmd == "card":
        card(sys.argv[2:])
    else:
        sys.exit(f"unknown command {cmd}")


main()
PYEOF

# ---------------------------------------------------------------- dispatch
[ ${#STAGES[@]} -eq 0 ] && STAGES=(setup download convert mmproj imatrix quant mtp card)
for s in "${STAGES[@]}"; do
  declare -F "stage_$s" >/dev/null || die "unknown stage: $s"
done
stage_show
for s in "${STAGES[@]}"; do
  [ "$s" = show ] && continue
  "stage_$s"
done
[[ " ${STAGES[*]} " == *" show "* && ${#STAGES[@]} -eq 1 ]] || log "Done. Output in $OUT"
