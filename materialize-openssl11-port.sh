#!/usr/bin/env bash
# One-shot helper: materialize the staged OpenSSL 1.1 compatibility work into
# the actual PHP 5.3 source files, remove development scaffolding, commit and
# push the resulting source port.

set -Eeuo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_DIR"

command -v python3 >/dev/null 2>&1 || {
  printf 'ERROR: python3 is required.\n' >&2
  exit 1
}
command -v git >/dev/null 2>&1 || {
  printf 'ERROR: git is required.\n' >&2
  exit 1
}

[[ -f ext/openssl/openssl.c && -f ext/openssl/xp_ssl.c ]] || {
  printf 'ERROR: run this script from the php53 repository root.\n' >&2
  exit 1
}
[[ -f tools/apply-openssl11-compat.py ]] || {
  printf 'ERROR: stage-1 transformer is missing.\n' >&2
  exit 1
}
[[ -f tools/apply-openssl11-compat-stage2.py ]] || {
  printf 'ERROR: stage-2 transformer is missing.\n' >&2
  exit 1
}

# Refuse to mix this port with unrelated local edits.
if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
  printf 'ERROR: tracked working tree is not clean. Commit or reset local changes first.\n' >&2
  git status --short >&2
  exit 1
fi

printf '==> applying OpenSSL 1.1 source compatibility stage 1\n'
python3 tools/apply-openssl11-compat.py "$REPO_DIR"

# PHP 5.3's openssl_open() has insignificant trailing whitespace differences
# between two equivalent cleanup branches. Normalize only this function before
# the strict second-stage transform.
python3 - <<'PY'
from pathlib import Path

path = Path("ext/openssl/openssl.c")
text = path.read_text(encoding="utf-8")
marker = "PHP_FUNCTION(openssl_open)"
start = text.index(marker)
end = text.index("\n/* }}} */", start)
block = text[start:end]
normalized = "\n".join(line.rstrip(" \t") for line in block.split("\n"))
path.write_text(text[:start] + normalized + text[end:], encoding="utf-8")
PY

printf '==> applying OpenSSL 1.1 source compatibility stage 2\n'
python3 tools/apply-openssl11-compat-stage2.py "$REPO_DIR"

printf '==> removing temporary development scaffolding\n'
rm -f \
  build-php53-openssl11-dev.sh \
  tools/apply-openssl11-compat.py \
  tools/apply-openssl11-compat-stage2.py \
  .github/workflows/materialize-openssl11-port.yml \
  materialize-openssl11-port.sh

# Remove the now-empty workflow directory when applicable.
rmdir .github/workflows 2>/dev/null || true
rmdir .github 2>/dev/null || true

git diff --check
git add -A

if git diff --cached --quiet; then
  printf 'ERROR: materialization produced no staged changes.\n' >&2
  exit 1
fi

printf '==> committing source port\n'
git commit -m "Port PHP 5.3 OpenSSL extension to OpenSSL 1.1"

printf '==> pushing main\n'
git push origin HEAD:main

printf '\nOpenSSL 1.1 source port materialized and pushed.\n'
printf 'Next build command:\n  FORCE=1 ./build-php53.sh\n'
