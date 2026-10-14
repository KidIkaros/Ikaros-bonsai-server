#!/usr/bin/env bash
# get-models.sh - download Bonsai GGUFs from Hugging Face.
#
# Uses plain curl/wget against the public HF resolve endpoint, so there are no
# Python dependencies on the beginner path. Downloads are resumable and are
# verified against the size HF reports.
#
# Usage:
#   ./scripts/get-models.sh                     interactive picker (recommended)
#   ./scripts/get-models.sh --list              list the catalog with fit info
#   ./scripts/get-models.sh --list abliterated  list entries matching a tag
#   ./scripts/get-models.sh --get 3             download catalog entry 3
#   ./scripts/get-models.sh --recommend         show and download the best fit
#   ./scripts/get-models.sh --repo <owner/name> [--file <name|glob>]
#   ./scripts/get-models.sh --repo <owner/name> --list
#
# Overrides:
#   HF_TOKEN=hf_xxx             for private or gated repos
#   KILN_MODELS_DIR=/path     where GGUFs land (default: <repo>/models)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

CATALOG="$SCRIPT_DIR/models.catalog"

MODE=""
ARG=""
REPO=""
FILE=""

while [ $# -gt 0 ]; do
    case "$1" in
        --list)      MODE="list"; [ -n "${2:-}" ] && [ "${2#--}" = "$2" ] && { ARG="$2"; shift; } ;;
        --get)       MODE="get";  ARG="${2:-}"; shift ;;
        --recommend) MODE="recommend" ;;
        --repo)      MODE="repo"; REPO="${2:-}"; shift ;;
        --file)      FILE="${2:-}"; shift ;;
        -h|--help)   sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)           die "Unknown option: $1" ;;
    esac
    shift
done

[ -f "$CATALOG" ] || die "Catalog not found: $CATALOG"

if detect_is_stale; then
    "$SCRIPT_DIR/detect.sh" >/dev/null 2>&1
fi
load_detect

mkdir -p "$MODELS_DIR"

# ---------------------------------------------------------------------------
# Catalog helpers
# ---------------------------------------------------------------------------

catalog_rows() {
    grep -v '^[[:space:]]*#' "$CATALOG" | grep -v '^[[:space:]]*$'
}

# sanitize REPO - turn owner/name into a filename-safe token.
sanitize() { printf '%s' "$1" | tr '/' '_'; }

# dest_for REPO FILE - the on-disk path a model lands at.
dest_for() { printf '%s/%s__%s' "$MODELS_DIR" "$(sanitize "$1")" "$2"; }

# fits REPO FILE - succeed when the entry fits the detected hardware.
fits() {
    _min_vram="$1"; _min_ram="$2"
    if [ "$VRAM_GB" -ge "$_min_vram" ] 2>/dev/null && [ "$_min_vram" -gt 0 ] 2>/dev/null; then
        return 0
    fi
    if [ "$_min_ram" -gt 0 ] 2>/dev/null && [ "$RAM_GB" -ge "$_min_ram" ] 2>/dev/null; then
        return 0
    fi
    return 1
}

print_row() {
    _n="$1" _repo="$2" _file="$3" _size="$4" _vram="$5" _ram="$6" _tags="$7"
    _mark=" "
    if [ "$_vram" -gt 0 ] 2>/dev/null; then
        if fits "$_vram" "$_ram"; then _mark="${C_GREEN}*${C_RESET}"; else _mark="${C_RED}-${C_RESET}"; fi
    fi
    printf '  %s %2s. %-58s %7s GB  %s\n' "$_mark" "$_n" "$_file" "$_size" "$_tags"
    printf '        %s%s\n' "${C_DIM}" "$_repo"
    printf '%s' "$C_RESET"
}

list_catalog() {
    _filter="${1:-}"
    step "Model catalog"
    printf '  %s* = fits this machine    - = does not fit    VRAM %s GB, RAM %s GB%s\n\n' \
        "$C_DIM" "$VRAM_GB" "$RAM_GB" "$C_RESET"

    _n=0
    while IFS='|' read -r _repo _file _size _vram _ram _tags; do
        [ -n "$_repo" ] || continue
        if [ -n "$_filter" ]; then
            case ",$_tags," in *",$_filter,"*) ;; *) continue ;; esac
        fi
        _n=$((_n + 1))
        print_row "$_n" "$_repo" "$_file" "$_size" "$_vram" "$_ram" "$_tags"
    done < <(catalog_rows)
    echo ""
    printf '  Download: %s./scripts/get-models.sh --get <number>%s\n' "$C_CYAN" "$C_RESET"
}

# recommend - print the catalog number best suited to this machine.
recommend() {
    _want=""
    if [ "$VRAM_GB" -ge 12 ]; then _want="recommended"
    elif [ "$VRAM_GB" -ge 5 ]; then _want="recommended-small"
    elif [ "$RAM_GB" -ge 6 ]; then _want="recommended-cpu"
    fi

    _n=0
    while IFS='|' read -r _repo _file _size _vram _ram _tags; do
        [ -n "$_repo" ] || continue
        _n=$((_n + 1))
        if [ -n "$_want" ]; then
            case ",$_tags," in *",$_want,"*) printf '%s' "$_n"; return 0 ;; esac
        fi
    done < <(catalog_rows)

    if [ -z "$_want" ]; then
        # Very small machine: fall back to the smallest official model.
        printf '12'
        return 0
    fi
    printf ''
}

# ---------------------------------------------------------------------------
# Download
# ---------------------------------------------------------------------------

# fetch REPO FILE [SIZE_GB] - download one file into the models directory.
# Sets FETCH_RESULT to the on-disk path. SIZE_GB, when known, is checked
# against free disk first so a full SSD fails fast instead of mid-download
# (which looks like corruption).
fetch() {
    _repo="$1" _file="$2" _size_gb="${3:-}"
    _dest="$(dest_for "$_repo" "$_file")"
    FETCH_RESULT="$_dest"

    if [ -f "$_dest" ]; then
        info "Already present: $(basename "$_dest")"
        return 0
    fi

    # Pre-flight disk check: need the model size plus a little headroom. Only
    # when the caller told us the size; otherwise skip silently.
    if [ -n "$_size_gb" ]; then
        _free_gb="$(df -Pk "$(dirname "$_dest")" 2>/dev/null | awk 'NR==2{printf "%.1f", $4/1048576}')"
        if [ -n "$_free_gb" ] && awk -v n="$_size_gb" -v f="$_free_gb" 'BEGIN{exit !(n+1 > f)}'; then
            die "Not enough disk: $_file needs ~${_size_gb} GB but only ${_free_gb} GB free in $(dirname "$_dest").
       Free up space, or pick a smaller model: ./scripts/get-models.sh --list"
        fi
    fi

    _url="https://huggingface.co/$_repo/resolve/main/$_file"
    info "Downloading $_file"
    dim "  from $_repo"

    _auth_args=()
    [ -n "${HF_TOKEN:-}" ] && _auth_args=(-H "Authorization: Bearer $HF_TOKEN")

    if command -v curl >/dev/null 2>&1; then
        curl -fL --retry 3 --retry-delay 2 -C - "${_auth_args[@]}" -o "$_dest" "$_url" || {
            rm -f "$_dest"
            die "Download failed: $_url"
        }
    elif command -v wget >/dev/null 2>&1; then
        wget -c -O "$_dest" --header="Authorization: Bearer ${HF_TOKEN:-}" "$_url" || {
            rm -f "$_dest"
            die "Download failed: $_url"
        }
    else
        die "Neither curl nor wget found."
    fi

    # Verify the download. A SHA256 from Hugging Face is the real check: a
    # truncated or corrupted file is removed rather than left to fail later at
    # model load, which is where it would otherwise surface.
    _hash="$(hf_file_hash "$_repo" "$_file" || true)"
    if [ -n "$_hash" ]; then
        _want="$(printf '%s' "$_hash" | cut -d' ' -f1)"
        _want_size="$(printf '%s' "$_hash" | cut -d' ' -f2)"
        _got_size="$(stat -c '%s' "$_dest" 2>/dev/null || stat -f '%z' "$_dest")"

        if [ "${_want_size:-0}" != "0" ] && [ "$_got_size" != "$_want_size" ]; then
            rm -f "$_dest"
            die "Size mismatch for $_file: expected $_want_size bytes, got $_got_size.
       The partial file was removed; re-run to download it again."
        fi

        _got="$(file_sha256 "$_dest" || true)"
        if [ -z "$_got" ]; then
            warn "No sha256 tool available, so $_file could only be size-checked."
        elif [ "$_want" != "$_got" ]; then
            rm -f "$_dest"
            die "SHA256 mismatch for $_file.
       expected $_want
       got      $_got
       The file was removed; re-run to download it again."
        else
            info "SHA256 verified."
        fi
    else
        # No LFS hash (small files are stored directly), so fall back to size.
        _expected="$(hf_tree "$_repo" | awk -v f="$_file" '$2 == f { print $1 }' | head -1)"
        if [ -n "$_expected" ] && [ "$_expected" != "0" ]; then
            _got="$(stat -c '%s' "$_dest" 2>/dev/null || stat -f '%z' "$_dest")"
            if [ "$_got" != "$_expected" ]; then
                warn "Size mismatch for $_file (expected $_expected, got $_got)."
                warn "The file may be incomplete. Delete it and re-run to resume."
            fi
        fi
    fi

    info "Saved: $_dest  ($(human_size "$(stat -c '%s' "$_dest" 2>/dev/null || stat -f '%z' "$_dest")"))"
}

# row_by_number N - print "repo|file" for catalog row N.
row_by_number() {
    _want="$1"
    _n=0
    while IFS='|' read -r _repo _file _size _vram _ram _tags; do
        [ -n "$_repo" ] || continue
        _n=$((_n + 1))
        if [ "$_n" = "$_want" ]; then printf '%s|%s|%s' "$_repo" "$_file" "$_tags"; return 0; fi
    done < <(catalog_rows)
    return 1
}

# ---------------------------------------------------------------------------
# Arbitrary repo passthrough
# ---------------------------------------------------------------------------

list_repo() {
    _repo="$1"
    step "GGUF files in $_repo"
    if ! _tree="$(hf_tree "$_repo")"; then
        die "Could not read $_repo. Private or gated? Set HF_TOKEN, or check the repo id."
    fi
    if [ -z "$_tree" ]; then
        die "No .gguf files in $_repo. It may be an MLX, safetensors or LoRA-only repo."
    fi
    printf '%s\n' "$_tree" | while read -r _size _path; do
        _note=""
        if ! quant_supported "$_path"; then
            _note="  ${C_RED}[unsupported format]${C_RESET}"
        fi
        printf '  %8s  %-60s %s%s\n' "$(human_size "$_size")" "$_path" "$(quant_label "$_path")" "$_note"
    done
    echo ""
    printf '  Download: %s./scripts/get-models.sh --repo %s --file <name|glob>%s\n' "$C_CYAN" "$_repo" "$C_RESET"
}

download_repo() {
    _repo="$1" _pattern="$2"
    if ! _tree="$(hf_tree "$_repo")"; then
        die "Could not read $_repo. Private or gated? Set HF_TOKEN."
    fi
    [ -n "$_tree" ] || die "No .gguf files in $_repo."

    # Match the pattern against the basename. An exact name matches exactly;
    # a pattern containing '*' is treated as a glob anchored on both ends, so
    # '*-Q4*' matches only Q4 files rather than (as an earlier version did)
    # printing every file in the repo whenever the pattern contained a '*'
    # anywhere - which turned a narrow request into a full-repo download.
    _matched="$(printf '%s\n' "$_tree" | awk -v p="$_pattern" '
        function basename(path,   n, a) {
            n = split(path, a, "/")
            return a[n]
        }
        {
            b = basename($2)
            if (p == b)                    { print; next }
            if (index(p, "*") == 0)        { next }
            # Glob: build a regex from the pattern, anchored both ends.
            re = "^"
            m = split(p, segs, "*")
            for (i = 1; i <= m; i++) {
                gsub(/[][(){}.?+^$|\\]/, "\\\\&", segs[i])
                re = re segs[i]
                if (i < m) re = re ".*"
            }
            re = re "$"
            if (b ~ re) print
        }
    ')"
    [ -n "$_matched" ] || die "No .gguf in $_repo matches '$_pattern'. Try --list."

    printf '%s\n' "$_matched" | while read -r _size _path; do
        if ! quant_supported "$_path"; then
            warn "Skipping $_path - format not supported by the pinned fork."
            warn "  (MLX, GSQ-RCO, NInfer and AWQ are different runtimes.)"
            continue
        fi
        if [ "$BACKEND" = "vulkan" ] && quant_needs_vulkan_warning "$_path"; then
            warn "$_path uses $(quant_label "$_path"); Vulkan support for it is partial."
        fi
        fetch "$_repo" "$_path"
    done
}

# ---------------------------------------------------------------------------
# Modes
# ---------------------------------------------------------------------------

case "$MODE" in
    list)
        if [ -n "$REPO" ]; then
            list_repo "$REPO"
        else
            list_catalog "$ARG"
        fi
        ;;

    repo)
        [ -n "$REPO" ] || die "--repo needs an owner/name argument."
        case "$REPO" in */*) ;; *) die "Repo id must look like owner/name (got '$REPO')." ;; esac
        if [ -z "$FILE" ]; then
            list_repo "$REPO"
        else
            download_repo "$REPO" "$FILE"
        fi
        ;;

    get)
        [ -n "$ARG" ] || die "--get needs a catalog number. Run --list first."
        _row="$(row_by_number "$ARG")" || die "No catalog entry number $ARG."
        _repo="$(printf '%s' "$_row" | cut -d'|' -f1)"
        _file="$(printf '%s' "$_row" | cut -d'|' -f2)"
        _size="$(printf '%s' "$_row" | cut -d'|' -f3)"
        step "Fetching $_file"
        fetch "$_repo" "$_file" "$_size"
        ;;

    recommend)
        _n="$(recommend)"
        [ -n "$_n" ] || die "Could not determine a recommendation. Run --list."
        _row="$(row_by_number "$_n")" || die "Recommendation $_n is not a valid entry."
        _repo="$(printf '%s' "$_row" | cut -d'|' -f1)"
        _file="$(printf '%s' "$_row" | cut -d'|' -f2)"
        _size="$(printf '%s' "$_row" | cut -d'|' -f3)"
        step "Recommended for this machine"
        printf '  %s%s\n' "$C_DIM" "$_repo"
        printf '%s' "$C_RESET"
        printf '  %s\n' "$_file"
        # Say WHY: param count + quant + VRAM fit, so the choice is legible.
        dim "  $(model_reason "$_file" "${VRAM_GB:-0}")"
        echo ""
        fetch "$_repo" "$_file" "$_size"
        ;;

    "")
        # Interactive: recommend, then offer the full catalog.
        _n="$(recommend)"
        list_catalog
        _default="$_n"
        # Say WHY the default is the default. A catalog of PQ2_0 / PTQ1_0 /
        # abliterated rows asks a first-time user the one question they came
        # to the tool to avoid - "which quant fits my card?" - so name the
        # recommendation and its reason in one line before asking for a number.
        if [ -n "$_n" ]; then
            _rec_row="$(row_by_number "$_n" || true)"
            if [ -n "$_rec_row" ]; then
                _rec_file="$(printf '%s' "$_rec_row" | cut -d'|' -f2)"
                _rec_vram="$(printf '%s' "$_rec_row" | cut -d'|' -f4)"
                if [ "${_rec_vram:-0}" -gt 0 ] 2>/dev/null && [ "${VRAM_GB:-0}" -gt 0 ] 2>/dev/null; then
                    dim "  Recommended for your ${VRAM_GB} GB card: entry $_n ($_rec_file),"
                    dim "  it fits with room for the KV cache. Press Enter to take it,"
                    dim "  or type another entry number."
                else
                    dim "  Recommended for this machine: entry $_n ($_rec_file). Press Enter to take it."
                fi
            fi
        fi
        _choice="$(ask "Entry number to download" "$_default")"
        [ -n "$_choice" ] || die "Nothing selected."
        _row="$(row_by_number "$_choice")" || die "No catalog entry number $_choice."
        _repo="$(printf '%s' "$_row" | cut -d'|' -f1)"
        _file="$(printf '%s' "$_row" | cut -d'|' -f2)"
        _size="$(printf '%s' "$_row" | cut -d'|' -f3)"
        step "Fetching $_file"
        fetch "$_repo" "$_file" "$_size"
        ;;
esac

if [ -n "${FETCH_RESULT:-}" ]; then
    dim "  server will list this model as: $(basename "${FETCH_RESULT%.gguf}")"
fi

echo ""
info "Models directory: $MODELS_DIR"
