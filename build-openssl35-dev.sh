#!/usr/bin/env bash
# Experimental PHP 5.3.29 + OpenSSL 3.5 LTS build.
#
# This wrapper deliberately leaves the production PHP 5.3 / OpenSSL 1.1 path
# untouched. It reuses build-php53.sh in a disposable build tree and applies
# only temporary OpenSSL 3.5 compatibility edits there.
#
# PHP:     /opt/ngm/php/5.3-openssl35-dev
# OpenSSL: /opt/ngm/php/openssl-3.5 (through a build-only prefix view)

set -Eeuo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_BUILD="${REPO_DIR}/build-php53.sh"

NGM_ROOT="${NGM_ROOT:-/opt/ngm/php}"
REAL_OPENSSL_PREFIX="${OPENSSL_PREFIX:-${NGM_ROOT}/openssl-3.5}"
PREFIX="${PREFIX:-${NGM_ROOT}/5.3-openssl35-dev}"
BUILD_ROOT="${BUILD_ROOT:-/usr/local/src/ngm-php53-openssl35}"
OPENSSL_VIEW="${BUILD_ROOT}/openssl-3.5-view"
GENERATED_BUILD="${BUILD_ROOT}/build-php53-openssl35-generated.sh"
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 2)}"
FORCE="${FORCE:-1}"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run as root."
[ -r "$BASE_BUILD" ] || die "missing ${BASE_BUILD}."
[ "${FORCE_DEPS:-0}" != "1" ] || die "FORCE_DEPS=1 is intentionally disabled for the OpenSSL 3.5 dev wrapper."

find_openssl_libdir() {
  local dir
  for dir in "${REAL_OPENSSL_PREFIX}/lib64" "${REAL_OPENSSL_PREFIX}/lib"; do
    if [ -e "${dir}/libssl.so.3" ] && [ -e "${dir}/libcrypto.so.3" ]; then
      printf '%s\n' "$dir"
      return 0
    fi
  done
  return 1
}

openssl_libdir="$(find_openssl_libdir)" || die "private OpenSSL 3 libraries not found under ${REAL_OPENSSL_PREFIX}."
[ -r "${REAL_OPENSSL_PREFIX}/include/openssl/ssl.h" ] || die "OpenSSL 3 headers missing under ${REAL_OPENSSL_PREFIX}."
[ -x "${REAL_OPENSSL_PREFIX}/bin/openssl" ] || die "OpenSSL 3 CLI missing under ${REAL_OPENSSL_PREFIX}."
"${REAL_OPENSSL_PREFIX}/bin/openssl" version 2>/dev/null | grep -Fq 'OpenSSL 3.5.7' || \
  die "expected OpenSSL 3.5.7 at ${REAL_OPENSSL_PREFIX}."

# PHP 5.3's legacy explicit-prefix detector looks in $prefix/lib, while the
# AlmaLinux OpenSSL build installs into lib64. Build through a disposable view
# instead of modifying the real OpenSSL prefix or using --with-libdir=lib64
# (which would break curl/libmcrypt prefixes that legitimately use lib).
log "creating OpenSSL 3.5 build-prefix view"
rm -rf "$OPENSSL_VIEW"
mkdir -p "$OPENSSL_VIEW"
ln -s "${REAL_OPENSSL_PREFIX}/include" "${OPENSSL_VIEW}/include"
ln -s "$openssl_libdir" "${OPENSSL_VIEW}/lib"
ln -s "${REAL_OPENSSL_PREFIX}/bin" "${OPENSSL_VIEW}/bin"
for item in openssl.cnf cert.pem certs private; do
  if [ -e "${REAL_OPENSSL_PREFIX}/${item}" ] || [ -L "${REAL_OPENSSL_PREFIX}/${item}" ]; then
    ln -s "${REAL_OPENSSL_PREFIX}/${item}" "${OPENSSL_VIEW}/${item}"
  fi
done

mkdir -p "$BUILD_ROOT"
cp "$BASE_BUILD" "$GENERATED_BUILD"
chmod +x "$GENERATED_BUILD"

# Transform only the disposable build driver. The checked-out php53 source and
# normal build-php53.sh remain unchanged until the OpenSSL 3.5 port is proven.
python3 - "$GENERATED_BUILD" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")

def once(old, new, label):
    global text
    count = text.count(old)
    if count != 1:
        raise SystemExit("%s: expected one match, found %d" % (label, count))
    text = text.replace(old, new, 1)

once('OPENSSL_VERSION="1.1.1w"', 'OPENSSL_VERSION="3.5.7"', 'OpenSSL version')
text = text.replace("'libssl.so.1.1'", "'libssl.so.3'")
once('*"OpenSSL 1.1.1w"*) ;;', '*"OpenSSL 3.5.7"*) ;;', 'OpenSSL runtime version check')

old_guard = '''  if grep -Eq 'lib(ssl|crypto)\\.so\\.3([[:space:]]|$)' <<<"$ldd_text"; then
    printf '%s\\n' "$ldd_text" | grep -E 'lib(curl|ssl|crypto)\\.so' >&2 || true
    die "OpenSSL 3 is still loaded; refusing an unsafe mixed-ABI PHP build."
  fi'''
new_guard = '''  if grep -Eq 'lib(ssl|crypto)\\.so\\.1\\.1([[:space:]]|$)' <<<"$ldd_text"; then
    printf '%s\\n' "$ldd_text" | grep -E 'lib(curl|ssl|crypto)\\.so' >&2 || true
    die "OpenSSL 1.1 is also loaded; refusing a mixed-ABI PHP build."
  fi'''
once(old_guard, new_guard, 'mixed OpenSSL ABI guard')

marker = 'source_has_generated_files() {'
patch_func = r'''patch_openssl35_source() {
  log "applying temporary OpenSSL 3.5 source compatibility patch"
  python3 - "${SRC_DIR}/ext/openssl/openssl.c" <<'PY_OPENSSL35'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
old = '\tREGISTER_LONG_CONSTANT("OPENSSL_SSLV23_PADDING", RSA_SSLV23_PADDING, CONST_CS|CONST_PERSISTENT);'
new = '#ifdef RSA_SSLV23_PADDING\n' + old + '\n#endif'
if new not in text:
    count = text.count(old)
    if count != 1:
        raise SystemExit("expected one OPENSSL_SSLV23_PADDING registration, found %d" % count)
    text = text.replace(old, new, 1)
    path.write_text(text, encoding="utf-8")
PY_OPENSSL35
}

'''
once(marker, patch_func + marker, 'source patch function insertion')
once('  fetch_php_source\n', '  fetch_php_source\n  patch_openssl35_source\n', 'source patch invocation')

# PHP 5.3 make install can leave only the FPM template. Promote it in this
# disposable install so the runtime probe can validate php-fpm -t.
needle = '''    if [ ! -f "${PREFIX}/etc/php.ini" ]; then
      cp php.ini-production "${PREFIX}/etc/php.ini"
    fi'''
replacement = needle + r'''

    if [ ! -f "${PREFIX}/etc/php-fpm.conf" ] && [ -f "${PREFIX}/etc/php-fpm.conf.default" ]; then
      cp "${PREFIX}/etc/php-fpm.conf.default" "${PREFIX}/etc/php-fpm.conf"
    fi'''
once(needle, replacement, 'FPM config promotion')

path.write_text(text, encoding="utf-8")
PY

log "starting isolated PHP 5.3.29 + OpenSSL 3.5.7 probe"
log "PHP prefix: ${PREFIX}"
log "OpenSSL: ${REAL_OPENSSL_PREFIX}"

# OPENSSL_PREFIX points at the disposable lib/lib64 compatibility view only for
# configure/link discovery. The loaded library itself retains its real compiled
# OPENSSLDIR (/opt/ngm/php/openssl-3.5) for config/providers/CA trust.
OPENSSL_PREFIX="$OPENSSL_VIEW" \
PREFIX="$PREFIX" \
BUILD_ROOT="$BUILD_ROOT" \
JOBS="$JOBS" \
FORCE="$FORCE" \
FORCE_DEPS=0 \
bash "$GENERATED_BUILD"

log "OpenSSL 3.5 development build driver completed"
