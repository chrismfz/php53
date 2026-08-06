#!/usr/bin/env bash
# Temporary development wrapper for the PHP 5.3 -> OpenSSL 1.1.1 port.
#
# It loads the normal build script without executing its final main call,
# overrides fetch_php_source() to apply the staged compatibility transformers to
# the disposable checkout, and then runs the normal build pipeline.

set -Eeuo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_SCRIPT="${REPO_DIR}/build-php53.sh"

[ -f "$BASE_SCRIPT" ] || {
  printf 'ERROR: base build script not found: %s\n' "$BASE_SCRIPT" >&2
  exit 1
}
command -v python3 >/dev/null 2>&1 || {
  printf 'ERROR: python3 is required for the staged OpenSSL 1.1 transformers.\n' >&2
  exit 1
}

last_line="$(tail -n 1 "$BASE_SCRIPT")"
[ "$last_line" = 'main "$@"' ] || {
  printf 'ERROR: unexpected build-php53.sh footer; refusing to source it.\n' >&2
  exit 1
}

tmp_script="$(mktemp)"
trap 'rm -f "$tmp_script"' EXIT
sed '$d' "$BASE_SCRIPT" > "$tmp_script"
# shellcheck source=/dev/null
source "$tmp_script"

# Preserve the original function, then patch the freshly fetched disposable
# checkout before generated-file detection and configure run.
eval "$(declare -f fetch_php_source | sed '1s/fetch_php_source/original_fetch_php_source/')"
fetch_php_source() {
  original_fetch_php_source
  python3 "${SRC_DIR}/tools/apply-openssl11-compat.py" "$SRC_DIR"

  # PHP 5.3 has one trailing space in openssl_open() that makes two otherwise
  # identical failure branches differ. Normalize only that exact legacy line so
  # the stage-2 transformer can keep strict occurrence checks.
  python3 - "${SRC_DIR}/ext/openssl/openssl.c" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
old = "\t\t\tif (keyresource == -1) { \n"
new = "\t\t\tif (keyresource == -1) {\n"
count = text.count(old)
if count != 1:
    raise SystemExit("OpenSSL source normalization: expected one trailing-space keyresource line, found %d" % count)
path.write_text(text.replace(old, new, 1), encoding="utf-8")
PY

  python3 "${SRC_DIR}/tools/apply-openssl11-compat-stage2.py" "$SRC_DIR"
}

main "$@"
