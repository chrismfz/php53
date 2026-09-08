#!/usr/bin/env bash
#
# build-php53.sh — build PHP 5.3.29 for NGM on Debian trixie / AlmaLinux 10
#
# Installs the FPM binary where NGM auto-discovers it:
#
#   /opt/ngm/php/5.3/sbin/php-fpm
#
# PHP 5.3 carries source compatibility backports for modern OpenSSL and
# targets the private OpenSSL 3.5 LTS runtime used by the maintained NGM builds.
# Compatibility/security changes live in the tracked PHP source.
#
# The host libcurl must not be used: it may bind the process to distro OpenSSL 3
# instead of NGM's private OpenSSL 3.5 and undermine runtime isolation. A private
# current libcurl is built with GnuTLS instead, so ext/curl cannot introduce a
# second OpenSSL implementation into the PHP process.
#
# The php53 repository is a raw git tree and may have no generated
# configure/parser/scanner files. PHP 5.3 also requires Autoconf <= 2.59 and only
# accepts specific Bison releases. A private, isolated build toolchain is used:
# Autoconf 2.59, Bison 2.6.4 and re2c 0.16.
#
# Usage:
#   sudo ./build-php53.sh
#   sudo FORCE=1 ./build-php53.sh
#   sudo JOBS=4 ./build-php53.sh
#   sudo PHP_GIT_REF=<commit-or-branch> FORCE=1 ./build-php53.sh
#
# FORCE=1 rebuilds/reinstalls PHP even when php-fpm already exists.
# FORCE_DEPS=1 additionally rebuilds the private dependency/toolchain prefixes.
# RUN_REGRESSION_TESTS=0 skips the post-build regression suite.
# RUNTIME_ONLY=1 only provisions runtime config and runs verification/tests.
# ENABLE_LEGACY_PROVIDER=0 disables the private OpenSSL legacy provider.
# ENABLE_IONCUBE=0 skips installing/enabling the bundled ionCube Loader.
# PHP_LIBDIR_NAME=... overrides the system library directory used by configure.

set -Eeuo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Versions and paths ───────────────────────────────────────────────────────
PHP_SERIES="5.3"
PHP_RELEASE="5.3.29"
PHP_GIT_URL="${PHP_GIT_URL:-https://github.com/chrismfz/php53.git}"
PHP_GIT_REF="${PHP_GIT_REF:-main}"

NGM_ROOT="${NGM_ROOT:-/opt/ngm/php}"
PREFIX="${PREFIX:-${NGM_ROOT}/${PHP_SERIES}}"
BUILD_ROOT="${BUILD_ROOT:-/usr/local/src/ngm-php-build}"
SRC_DIR="${BUILD_ROOT}/php-${PHP_RELEASE}"

# Keep incompatible components isolated from the host and other PHP builds.
OPENSSL_VERSION="${OPENSSL_VERSION:-3.5.7}"
OPENSSL_PREFIX="${OPENSSL_PREFIX:-${NGM_ROOT}/openssl-3.5}"
CURL_VERSION="8.21.0"
CURL_PREFIX="${CURL_PREFIX:-${NGM_ROOT}/curl-gnutls}"
MCRYPT_VERSION="2.5.8"
MCRYPT_PREFIX="${MCRYPT_PREFIX:-${NGM_ROOT}/libmcrypt}"
TOOLCHAIN="${TOOLCHAIN:-${NGM_ROOT}/.toolchain-php53}"
AUTOCONF_VERSION="2.59"
BISON_VERSION="2.6.4"
RE2C_VERSION="0.16"

JOBS="${JOBS:-$(nproc 2>/dev/null || echo 2)}"
FORCE="${FORCE:-0}"
FORCE_DEPS="${FORCE_DEPS:-0}"
RUN_REGRESSION_TESTS="${RUN_REGRESSION_TESTS:-1}"
ENABLE_LEGACY_PROVIDER="${ENABLE_LEGACY_PROVIDER:-1}"
ENABLE_IONCUBE="${ENABLE_IONCUBE:-1}"
RUNTIME_ONLY="${RUNTIME_ONLY:-0}"
APPLY_PATCHES="${APPLY_PATCHES:-1}"   # apply patches/series (CloudLinux security backports); 0 = pristine build
PHP_LIBDIR_NAME="${PHP_LIBDIR_NAME:-}"
IONCUBE_LOADER="${REPO_DIR}/ioncube/ioncube_loader_lin_${PHP_SERIES}.so"

FPM_USER="${FPM_USER:-nobody}"
if getent group nogroup >/dev/null 2>&1; then
  FPM_GROUP="${FPM_GROUP:-nogroup}"
else
  FPM_GROUP="${FPM_GROUP:-nobody}"
fi

# ── Logging/helpers ──────────────────────────────────────────────────────────
log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

on_error() {
  local rc=$?
  printf '\033[1;31mERROR:\033[0m command failed at line %s (exit %s): %s\n' \
    "${BASH_LINENO[0]:-?}" "$rc" "${BASH_COMMAND:-?}" >&2
  exit "$rc"
}
trap on_error ERR

need_root() {
  [ "$(id -u)" -eq 0 ] || die "run as root (installs packages and writes under ${NGM_ROOT})."
}

need_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

fetch() { # URL DEST
  local url="$1" dest="$2"
  if [ -s "$dest" ]; then
    log "cached $(basename "$dest")"
    return
  fi
  log "download ${url}"
  curl -fL --retry 3 --retry-delay 2 --connect-timeout 20 -o "${dest}.part" "$url"
  mv -f "${dest}.part" "$dest"
}

find_libdir() { # PREFIX LIBRARY_GLOB
  local prefix="$1" pattern="$2" dir
  for dir in "${prefix}/lib" "${prefix}/lib64"; do
    if compgen -G "${dir}/${pattern}" >/dev/null 2>&1; then
      printf '%s\n' "$dir"
      return 0
    fi
  done
  return 1
}

find_ca_bundle() {
  local file
  for file in \
    /etc/pki/tls/certs/ca-bundle.crt \
    /etc/ssl/certs/ca-certificates.crt \
    /etc/ssl/ca-bundle.pem; do
    if [ -s "$file" ]; then
      printf '%s\n' "$file"
      return 0
    fi
  done
  return 1
}

detect_php_libdir_name() {
  if [ -n "$PHP_LIBDIR_NAME" ]; then
    return
  fi

  if command -v dnf >/dev/null 2>&1; then
    PHP_LIBDIR_NAME="lib64"
  elif command -v dpkg-architecture >/dev/null 2>&1; then
    PHP_LIBDIR_NAME="lib/$(dpkg-architecture -qDEB_HOST_MULTIARCH)"
  else
    PHP_LIBDIR_NAME="lib"
  fi

  log "PHP configure library directory: ${PHP_LIBDIR_NAME}"
}

ensure_configure_lib_alias() {
  local prefix="$1" pattern="$2" actual expected
  actual="$(find_libdir "$prefix" "$pattern")" || die "library ${pattern} not found under ${prefix}."
  expected="${prefix}/${PHP_LIBDIR_NAME}"

  [ "$actual" = "$expected" ] && return
  if compgen -G "${expected}/${pattern}" >/dev/null 2>&1; then
    return
  fi
  if [ -e "$expected" ] || [ -L "$expected" ]; then
    die "${expected} exists but does not expose ${pattern}; refusing to replace it."
  fi

  mkdir -p "$(dirname "$expected")"
  ln -s "$actual" "$expected"
  log "created configure-only library alias ${expected} -> ${actual}"
}

# ── Host dependencies ────────────────────────────────────────────────────────
install_deps() {
  local pm
  if command -v apt-get >/dev/null 2>&1; then
    pm=apt
  elif command -v dnf >/dev/null 2>&1; then
    pm=dnf
  else
    die "unsupported package manager; expected apt-get or dnf."
  fi

  log "installing build dependencies via ${pm}"
  case "$pm" in
    apt)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -y
      apt-get install -y --no-install-recommends \
        build-essential ca-certificates curl git patch pkg-config \
        perl m4 tar gzip bzip2 xz-utils \
        libxml2-dev libgnutls28-dev nettle-dev libjpeg-dev libpng-dev \
        libfreetype6-dev libbz2-dev libreadline-dev libxslt1-dev \
        libgmp-dev libsqlite3-dev zlib1g-dev libgettextpo-dev libcrypt-dev \
        libpq-dev libldap2-dev libsasl2-dev libtidy-dev libaspell-dev
      ;;
    dnf)
      dnf install -y 'dnf-command(config-manager)' || true
      dnf config-manager --set-enabled crb 2>/dev/null || true
      dnf install -y epel-release 2>/dev/null || true
      dnf install -y \
        gcc gcc-c++ make ca-certificates curl git patch pkgconf-pkg-config \
        perl perl-FindBin perl-IPC-Cmd perl-File-Compare perl-Data-Dumper \
        m4 tar gzip bzip2 xz \
        libxml2-devel gnutls-devel nettle-devel libjpeg-turbo-devel libpng-devel \
        freetype-devel bzip2-devel readline-devel libxslt-devel \
        gmp-devel sqlite-devel zlib-devel gettext-devel libxcrypt-devel \
        libpq-devel openldap-devel cyrus-sasl-devel libtidy-devel aspell-devel
      ;;
  esac
}

# ── Private OpenSSL 3.5 LTS ─────────────────────────────────────────────────
build_openssl() {
  local existing_lib="" tarball="${BUILD_ROOT}/openssl-${OPENSSL_VERSION}.tar.gz"
  mkdir -p "$BUILD_ROOT"

  fetch "https://www.openssl.org/source/openssl-${OPENSSL_VERSION}.tar.gz" "$tarball"

  existing_lib="$(find_libdir "$OPENSSL_PREFIX" 'libssl.so.3' || true)"
  if [ -n "$existing_lib" ] && [ -x "${OPENSSL_PREFIX}/bin/openssl" ] && [ "$FORCE_DEPS" != "1" ]; then
    if LD_LIBRARY_PATH="$existing_lib" "${OPENSSL_PREFIX}/bin/openssl" version 2>/dev/null | grep -Fq "OpenSSL ${OPENSSL_VERSION}"; then
      log "OpenSSL ${OPENSSL_VERSION} already at ${OPENSSL_PREFIX}"
      return
    fi
  fi

  rm -rf "${BUILD_ROOT}/openssl-${OPENSSL_VERSION}"
  tar -xzf "$tarball" -C "$BUILD_ROOT"

  pushd "${BUILD_ROOT}/openssl-${OPENSSL_VERSION}" >/dev/null
    log "building OpenSSL ${OPENSSL_VERSION} -> ${OPENSSL_PREFIX}"
    ./config \
      --prefix="${OPENSSL_PREFIX}" \
      --openssldir="${OPENSSL_PREFIX}" \
      shared zlib -fPIC
    make -j"$JOBS"
    make install_sw
  popd >/dev/null

  find_libdir "$OPENSSL_PREFIX" 'libssl.so.3' >/dev/null || \
    die "OpenSSL installed, but libssl.so.3 was not found under ${OPENSSL_PREFIX}."
}

provision_openssl_runtime_files() {
  local tarball="${BUILD_ROOT}/openssl-${OPENSSL_VERSION}.tar.gz" ca_bundle
  local tmp_config openssl_libdir providers modules_dir=""

  install -d -m 755 "${OPENSSL_PREFIX}/certs"
  install -d -m 700 "${OPENSSL_PREFIX}/private"

  if [ ! -s "${OPENSSL_PREFIX}/openssl.cnf" ]; then
    [ -s "$tarball" ] || die "OpenSSL source tarball missing; cannot provision openssl.cnf."
    log "installing OpenSSL ${OPENSSL_VERSION} configuration"
    tar -xOf "$tarball" "openssl-${OPENSSL_VERSION}/apps/openssl.cnf" > "${OPENSSL_PREFIX}/openssl.cnf"
  fi

  # Keep the OpenSSL configuration deterministic and idempotent. The private
  # OpenSSL tree is dedicated to the maintained PHP 5.3/5.6 runtimes, so the
  # legacy provider is enabled here for old application compatibility without
  # weakening the host/system OpenSSL configuration or global TLS SECLEVEL.
  tmp_config="${OPENSSL_PREFIX}/openssl.cnf.tmp.$$"
  awk '
    /^# BEGIN NGM OPENSSL35 LEGACY PROVIDER$/ { skip=1; next }
    /^# END NGM OPENSSL35 LEGACY PROVIDER$/   { skip=0; next }
    !skip { print }
  ' "${OPENSSL_PREFIX}/openssl.cnf" > "$tmp_config"

  if [ "$ENABLE_LEGACY_PROVIDER" = "1" ]; then
    cat >> "$tmp_config" <<'EOF'

# BEGIN NGM OPENSSL35 LEGACY PROVIDER
# Compatibility policy for isolated legacy PHP runtimes only.
[openssl_init]
providers = ngm_provider_sect

[ngm_provider_sect]
default = ngm_default_sect
legacy = ngm_legacy_sect

[ngm_default_sect]
activate = 1

[ngm_legacy_sect]
activate = 1
# END NGM OPENSSL35 LEGACY PROVIDER
EOF
  else
    log "OpenSSL legacy provider compatibility disabled"
  fi

  mv -f "$tmp_config" "${OPENSSL_PREFIX}/openssl.cnf"
  chmod 644 "${OPENSSL_PREFIX}/openssl.cnf"

  ca_bundle="$(find_ca_bundle)" || die "could not locate the system CA bundle."
  ln -sfn "$ca_bundle" "${OPENSSL_PREFIX}/cert.pem"

  [ -r "${OPENSSL_PREFIX}/openssl.cnf" ] || die "OpenSSL configuration is not readable."
  [ -r "${OPENSSL_PREFIX}/cert.pem" ] || die "OpenSSL CA bundle link is not readable."

  if [ "$ENABLE_LEGACY_PROVIDER" = "1" ]; then
    for modules_dir in "${OPENSSL_PREFIX}/lib64/ossl-modules" "${OPENSSL_PREFIX}/lib/ossl-modules"; do
      [ -e "${modules_dir}/legacy.so" ] && break
      modules_dir=""
    done
    [ -n "$modules_dir" ] || die "OpenSSL legacy provider module was not found."

    openssl_libdir="$(find_libdir "$OPENSSL_PREFIX" 'libssl.so.3')" || die "private OpenSSL library directory not found."
    providers="$(OPENSSL_CONF="${OPENSSL_PREFIX}/openssl.cnf" OPENSSL_MODULES="$modules_dir" LD_LIBRARY_PATH="$openssl_libdir" "${OPENSSL_PREFIX}/bin/openssl" list -providers)"
    grep -Eq '^[[:space:]]+default$' <<<"$providers" || die "private OpenSSL default provider did not load."
    grep -Eq '^[[:space:]]+legacy$' <<<"$providers" || die "private OpenSSL legacy provider did not load."
    log "private OpenSSL default + legacy providers enabled"
  fi
}

# ── Private libcurl with GnuTLS ──────────────────────────────────────────────
build_curl() {
  local existing_lib="" ca_bundle
  existing_lib="$(find_libdir "$CURL_PREFIX" 'libcurl.so.4*' || true)"

  if [ -n "$existing_lib" ] && \
     [ -x "${CURL_PREFIX}/bin/curl-config" ] && \
     "${CURL_PREFIX}/bin/curl-config" --version 2>/dev/null | grep -Fq "libcurl ${CURL_VERSION}" && \
     "${CURL_PREFIX}/bin/curl-config" --ssl-backends 2>/dev/null | grep -qi 'GnuTLS' && \
     [ "$FORCE_DEPS" != "1" ]; then
    log "curl ${CURL_VERSION} (GnuTLS) already at ${CURL_PREFIX}"
    return
  fi

  ca_bundle="$(find_ca_bundle)" || die "could not locate the system CA bundle."

  local tarball="${BUILD_ROOT}/curl-${CURL_VERSION}.tar.xz"
  fetch "https://curl.se/download/curl-${CURL_VERSION}.tar.xz" "$tarball"
  rm -rf "${BUILD_ROOT}/curl-${CURL_VERSION}"
  tar -xJf "$tarball" -C "$BUILD_ROOT"

  pushd "${BUILD_ROOT}/curl-${CURL_VERSION}" >/dev/null
    log "building curl ${CURL_VERSION} with GnuTLS -> ${CURL_PREFIX}"
    CFLAGS="-O2 -fPIC" \
      ./configure \
        --prefix="${CURL_PREFIX}" \
        --enable-shared \
        --disable-static \
        --with-gnutls \
        --without-openssl \
        --with-zlib \
        --with-ca-bundle="${ca_bundle}" \
        --without-libpsl \
        --without-libidn2 \
        --without-brotli \
        --without-zstd \
        --without-nghttp2 \
        --without-nghttp3 \
        --without-ngtcp2 \
        --without-quiche \
        --without-libssh2 \
        --without-libssh \
        --disable-ldap \
        --disable-ldaps
    make -j"$JOBS"
    make install
  popd >/dev/null

  find_libdir "$CURL_PREFIX" 'libcurl.so.4*' >/dev/null || \
    die "curl installed, but libcurl.so.4 was not found under ${CURL_PREFIX}."
  "${CURL_PREFIX}/bin/curl-config" --ssl-backends 2>/dev/null | grep -qi 'GnuTLS' || \
    die "private curl was not built with GnuTLS."
}

# ── Private libmcrypt ────────────────────────────────────────────────────────
build_libmcrypt() {
  local existing_lib=""
  existing_lib="$(find_libdir "$MCRYPT_PREFIX" 'libmcrypt.so*' || true)"
  if [ -n "$existing_lib" ] && [ "$FORCE_DEPS" != "1" ]; then
    log "libmcrypt already at ${MCRYPT_PREFIX}"
    return
  fi

  local tarball="${BUILD_ROOT}/libmcrypt-${MCRYPT_VERSION}.tar.gz"
  fetch "https://sourceforge.net/projects/mcrypt/files/Libmcrypt/${MCRYPT_VERSION}/libmcrypt-${MCRYPT_VERSION}.tar.gz/download" "$tarball"

  rm -rf "${BUILD_ROOT}/libmcrypt-${MCRYPT_VERSION}"
  tar -xzf "$tarball" -C "$BUILD_ROOT"

  pushd "${BUILD_ROOT}/libmcrypt-${MCRYPT_VERSION}" >/dev/null
    log "building libmcrypt ${MCRYPT_VERSION} -> ${MCRYPT_PREFIX}"
    CFLAGS="-O2 -fPIC -fcommon -Wno-error=implicit-function-declaration -Wno-error=implicit-int" \
    CPPFLAGS="-D_DEFAULT_SOURCE" \
      ./configure --prefix="${MCRYPT_PREFIX}" --disable-posix-threads
    make -j"$JOBS"
    make install
  popd >/dev/null

  find_libdir "$MCRYPT_PREFIX" 'libmcrypt.so*' >/dev/null || \
    die "libmcrypt installed, but its shared library was not found under ${MCRYPT_PREFIX}."
}

# ── Private PHP 5.3 generator toolchain ──────────────────────────────────────
build_autoconf() {
  if [ -x "${TOOLCHAIN}/bin/autoconf" ] && \
     "${TOOLCHAIN}/bin/autoconf" --version 2>/dev/null | sed -n '1p' | grep -q ' 2\.59$' && \
     [ "$FORCE_DEPS" != "1" ]; then
    log "autoconf ${AUTOCONF_VERSION} already at ${TOOLCHAIN}"
    return
  fi

  local tarball="${BUILD_ROOT}/autoconf-${AUTOCONF_VERSION}.tar.gz"
  fetch "https://ftp.gnu.org/gnu/autoconf/autoconf-${AUTOCONF_VERSION}.tar.gz" "$tarball"
  rm -rf "${BUILD_ROOT}/autoconf-${AUTOCONF_VERSION}"
  tar -xzf "$tarball" -C "$BUILD_ROOT"

  pushd "${BUILD_ROOT}/autoconf-${AUTOCONF_VERSION}" >/dev/null
    log "building autoconf ${AUTOCONF_VERSION} -> ${TOOLCHAIN}"
    ./configure --prefix="$TOOLCHAIN"
    make -j"$JOBS"
    make install
  popd >/dev/null
}

build_bison() {
  if [ -x "${TOOLCHAIN}/bin/bison" ] && \
     "${TOOLCHAIN}/bin/bison" --version 2>/dev/null | sed -n '1p' | grep -q ' 2\.6\.4$' && \
     [ "$FORCE_DEPS" != "1" ]; then
    log "bison ${BISON_VERSION} already at ${TOOLCHAIN}"
    return
  fi

  local tarball="${BUILD_ROOT}/bison-${BISON_VERSION}.tar.gz"
  fetch "https://ftp.gnu.org/gnu/bison/bison-${BISON_VERSION}.tar.gz" "$tarball"
  rm -rf "${BUILD_ROOT}/bison-${BISON_VERSION}"
  tar -xzf "$tarball" -C "$BUILD_ROOT"

  pushd "${BUILD_ROOT}/bison-${BISON_VERSION}" >/dev/null
    log "building bison ${BISON_VERSION} -> ${TOOLCHAIN}"
    # Old bundled gnulib declares gets(), which disappeared from modern libc.
    if [ -f lib/stdio.in.h ]; then
      sed -i '/_GL_WARN_ON_USE *(gets/d' lib/stdio.in.h
    fi

    # glibc 2.28+ removed _IO_ftrylockfile. _IO_EOF_SEEN is the replacement
    # compatibility check used by newer gnulib versions.
    if [ -f lib/fseterr.c ] && \
       grep -q 'defined _IO_ftrylockfile || __GNU_LIBRARY__ == 1' lib/fseterr.c; then
      sed -i \
        's/defined _IO_ftrylockfile || __GNU_LIBRARY__ == 1/defined _IO_EOF_SEEN || defined _IO_ftrylockfile || __GNU_LIBRARY__ == 1/' \
        lib/fseterr.c
    fi

    CFLAGS="-O2 -fPIC -fcommon -Wno-error=implicit-function-declaration -Wno-error=implicit-int -Wno-error=incompatible-pointer-types" \
    CPPFLAGS="-D_DEFAULT_SOURCE" \
      ./configure --prefix="$TOOLCHAIN"
    make -j"$JOBS"
    make install
  popd >/dev/null
}

build_re2c() {
  if [ -x "${TOOLCHAIN}/bin/re2c" ] && \
     [ "$("${TOOLCHAIN}/bin/re2c" --vernum 2>/dev/null || echo 0)" -ge 1304 ] && \
     [ "$FORCE_DEPS" != "1" ]; then
    log "re2c already at ${TOOLCHAIN}"
    return
  fi

  local tarball="${BUILD_ROOT}/re2c-${RE2C_VERSION}.tar.gz"
  fetch "https://github.com/skvadrik/re2c/releases/download/${RE2C_VERSION}/re2c-${RE2C_VERSION}.tar.gz" "$tarball"
  rm -rf "${BUILD_ROOT}/re2c-${RE2C_VERSION}"
  tar -xzf "$tarball" -C "$BUILD_ROOT"

  pushd "${BUILD_ROOT}/re2c-${RE2C_VERSION}" >/dev/null
    log "building re2c ${RE2C_VERSION} -> ${TOOLCHAIN}"
    CXXFLAGS="-O2 -fPIC -std=gnu++98 -Wno-error" \
      ./configure --prefix="$TOOLCHAIN"
    make -j"$JOBS"
    make install
  popd >/dev/null
}

build_toolchain() {
  mkdir -p "$TOOLCHAIN"
  build_autoconf
  build_bison
  build_re2c

  "${TOOLCHAIN}/bin/autoconf" --version | sed -n '1p' | grep -q ' 2\.59$' || \
    die "private autoconf is not 2.59."
  "${TOOLCHAIN}/bin/bison" --version | sed -n '1p' | grep -q ' 2\.6\.4$' || \
    die "private bison is not 2.6.4."
  [ "$("${TOOLCHAIN}/bin/re2c" --vernum 2>/dev/null || echo 0)" -ge 1304 ] || \
    die "private re2c is too old."
}

# ── PHP source checkout ──────────────────────────────────────────────────────
fetch_php_source() {
  if [ ! -d "${SRC_DIR}/.git" ]; then
    rm -rf "$SRC_DIR"
    mkdir -p "$SRC_DIR"
    git -C "$SRC_DIR" init -q
    git -C "$SRC_DIR" remote add origin "$PHP_GIT_URL"
  else
    git -C "$SRC_DIR" remote set-url origin "$PHP_GIT_URL"
  fi

  log "fetching ${PHP_GIT_URL} @ ${PHP_GIT_REF}"
  git -C "$SRC_DIR" fetch --depth 1 origin "$PHP_GIT_REF"
  git -C "$SRC_DIR" checkout -q -f --detach FETCH_HEAD
  # This is a disposable build checkout. Remove stale configure/Makefile/object
  # output from earlier runs, while keeping the repository itself.
  git -C "$SRC_DIR" clean -q -f -d -x

  # ZIP imports can lose Unix modes. Keep the checkout self-healing even though
  # the repository now stores the correct modes.
  chmod +x \
    "${SRC_DIR}/buildconf" \
    "${SRC_DIR}/build/buildcheck.sh" \
    "${SRC_DIR}/build/config-stubs" \
    "${SRC_DIR}/build/shtool" \
    "${SRC_DIR}/vcsclean" 2>/dev/null || true
}

source_has_generated_files() {
  local file
  for file in \
    configure \
    main/php_config.h.in \
    Zend/zend_language_parser.c Zend/zend_language_parser.h \
    Zend/zend_language_scanner.c \
    Zend/zend_ini_parser.c Zend/zend_ini_parser.h \
    Zend/zend_ini_scanner.c; do
    [ -f "${SRC_DIR}/${file}" ] || return 1
  done
}

# ── PHP 5.3 build ────────────────────────────────────────────────────────────
build_php() {
  if [ -x "${PREFIX}/sbin/php-fpm" ] && [ "$FORCE" != "1" ]; then
    die "PHP ${PHP_SERIES} already exists at ${PREFIX}/sbin/php-fpm (use FORCE=1 to rebuild)."
  fi

  local openssl_libdir curl_libdir mcrypt_libdir openssl_pc_prefix
  openssl_libdir="$(find_libdir "$OPENSSL_PREFIX" 'libssl.so.3')" || \
    die "private OpenSSL library directory not found."
  curl_libdir="$(find_libdir "$CURL_PREFIX" 'libcurl.so.4*')" || \
    die "private curl library directory not found."
  mcrypt_libdir="$(find_libdir "$MCRYPT_PREFIX" 'libmcrypt.so*')" || \
    die "private libmcrypt library directory not found."

  export PATH="${TOOLCHAIN}/bin:${CURL_PREFIX}/bin:${PATH}"
  export PHP_AUTOCONF="${TOOLCHAIN}/bin/autoconf"
  export PHP_AUTOHEADER="${TOOLCHAIN}/bin/autoheader"
  export PKG_CONFIG_PATH="${curl_libdir}/pkgconfig:${openssl_libdir}/pkgconfig:${mcrypt_libdir}/pkgconfig:${PKG_CONFIG_PATH:-}"
  export LD_LIBRARY_PATH="${curl_libdir}:${openssl_libdir}:${mcrypt_libdir}:${LD_LIBRARY_PATH:-}"

  # GCC 10+ defaults to -fno-common; GCC 14 promotes several old-C diagnostics
  # to errors. These flags preserve the historical compiler behaviour expected
  # by PHP 5.3 without weakening the host compiler globally.
  export CFLAGS="-O2 -fPIC -fcommon -Wno-error=incompatible-pointer-types -Wno-error=implicit-function-declaration -Wno-error=implicit-int -Wno-error=int-conversion ${CFLAGS:-}"
  export CPPFLAGS="-D_DEFAULT_SOURCE -I${CURL_PREFIX}/include -I${OPENSSL_PREFIX}/include -I${MCRYPT_PREFIX}/include ${CPPFLAGS:-}"
  export LDFLAGS="-L${curl_libdir} -L${openssl_libdir} -L${mcrypt_libdir} -Wl,-rpath,${curl_libdir} -Wl,-rpath,${openssl_libdir} -Wl,-rpath,${mcrypt_libdir} ${LDFLAGS:-}"

  pkg-config --exists openssl || die "private OpenSSL pkg-config metadata not found."
  openssl_pc_prefix="$(pkg-config --variable=prefix openssl)"
  [ "$openssl_pc_prefix" = "$OPENSSL_PREFIX" ] || \
    die "pkg-config resolved OpenSSL from ${openssl_pc_prefix}, expected ${OPENSSL_PREFIX}."

  pushd "$SRC_DIR" >/dev/null
    if source_has_generated_files; then
      log "complete generated build files found; skipping buildconf"
      # Git does not preserve mtimes. Keep make from regenerating tracked parser
      # output merely because a .y/.l file happened to be checked out later.
      touch \
        Zend/zend_language_parser.c Zend/zend_language_parser.h \
        Zend/zend_language_scanner.c \
        Zend/zend_ini_parser.c Zend/zend_ini_parser.h Zend/zend_ini_scanner.c
    else
      log "generating configure and parser/scanner sources"
      ./buildconf --force
      [ -x configure ] || die "buildconf did not generate ./configure."
      [ -f main/php_config.h.in ] || die "buildconf did not generate main/php_config.h.in."
    fi

    # Deliberately omitted:
    #   intl: PHP 5.3's ext/intl is incompatible with current ICU.
    #   system libzip: --enable-zip uses PHP's bundled compatible copy.
    # mysql/mysqlnd is intentionally enabled because PHP 5.3 applications often
    # still call the removed mysql_* API in addition to mysqli/PDO.
    log "configure PHP ${PHP_RELEASE} -> ${PREFIX}"
    ./configure \
      --prefix="${PREFIX}" \
      --exec-prefix="${PREFIX}" \
      --with-config-file-path="${PREFIX}/etc" \
      --with-config-file-scan-dir="${PREFIX}/etc/conf.d" \
      --with-libdir="${PHP_LIBDIR_NAME}" \
      --enable-fpm \
      --with-fpm-user="${FPM_USER}" \
      --with-fpm-group="${FPM_GROUP}" \
      --with-openssl \
      --with-zlib \
      --enable-pdo \
      --enable-mbstring \
      --enable-bcmath \
      --enable-calendar \
      --enable-exif \
      --enable-ftp \
      --enable-pcntl \
      --enable-shmop \
      --enable-soap \
      --enable-sockets \
      --enable-sysvmsg --enable-sysvsem --enable-sysvshm \
      --enable-zip \
      --with-bz2 \
      --with-curl="${CURL_PREFIX}" \
      --with-gd --with-jpeg-dir=/usr --with-png-dir=/usr --with-freetype-dir=/usr \
      --with-gettext \
      --with-gmp \
      --with-iconv \
      --with-mcrypt="${MCRYPT_PREFIX}" \
      --with-mhash \
      --with-mysql=mysqlnd \
      --with-mysqli=mysqlnd \
      --with-pdo-mysql=mysqlnd \
      --with-pgsql \
      --with-pdo-pgsql \
      --with-ldap=/usr \
      --with-ldap-sasl=/usr \
      --with-tidy=/usr \
      --with-pspell=/usr \
      --with-sqlite3=/usr \
      --with-pdo-sqlite=/usr \
      --with-readline \
      --with-xsl \
      --without-pear

    log "make -j${JOBS}"
    make -j"$JOBS"
    make install

    install -d "${PREFIX}/etc" "${PREFIX}/etc/conf.d"
    if [ ! -f "${PREFIX}/etc/php.ini" ]; then
      cp php.ini-production "${PREFIX}/etc/php.ini"
    fi

    if [ ! -f "${PREFIX}/etc/php-fpm.conf" ] && [ -f "${PREFIX}/etc/php-fpm.conf.default" ]; then
      cp "${PREFIX}/etc/php-fpm.conf.default" "${PREFIX}/etc/php-fpm.conf"
    fi
  popd >/dev/null
}

install_runtime_extensions() {
  local ioncube_dir="${PREFIX}/ioncube"
  local ioncube_target="${ioncube_dir}/ioncube_loader_lin_${PHP_SERIES}.so"
  local ioncube_ini="${PREFIX}/etc/conf.d/00-ioncube.ini"

  install -d -m 755 "${PREFIX}/etc/conf.d"

  if [ "$ENABLE_IONCUBE" = "1" ]; then
    [ -r "$IONCUBE_LOADER" ] || die "ionCube loader missing from repository: ${IONCUBE_LOADER}"
    install -d -m 755 "$ioncube_dir"
    install -m 755 "$IONCUBE_LOADER" "$ioncube_target"
    cat > "$ioncube_ini" <<EOF
; Managed by build-php53.sh. ionCube must be the first Zend extension.
zend_extension=${ioncube_target}
EOF
    chmod 644 "$ioncube_ini"
    log "installed ionCube Loader for PHP ${PHP_SERIES}"
  else
    rm -f "$ioncube_ini"
    log "ionCube Loader disabled"
  fi
}

verify() {
  local php_bin="${PREFIX}/bin/php"
  local fpm_bin="${PREFIX}/sbin/php-fpm"
  local modules module actual_version openssl_text
  local curl_version curl_tls curl_libdir openssl_libdir ldd_text smoke_rc

  [ -x "$php_bin" ] || die "expected CLI binary missing: ${php_bin}"
  [ -x "$fpm_bin" ] || die "expected FPM binary missing: ${fpm_bin}"

  actual_version="$("$php_bin" -n -r 'echo PHP_VERSION;' 2>/dev/null)"
  [ "$actual_version" = "$PHP_RELEASE" ] || \
    die "built PHP reports ${actual_version}, expected ${PHP_RELEASE}."

  openssl_text="$("$php_bin" -n -r 'echo OPENSSL_VERSION_TEXT;' 2>/dev/null)"
  case "$openssl_text" in
    *"OpenSSL ${OPENSSL_VERSION}"*) ;;
    *) die "PHP loaded an unexpected OpenSSL: ${openssl_text:-unknown}" ;;
  esac

  modules="$("$php_bin" -n -m 2>/dev/null)"
  for module in openssl curl gd mbstring mcrypt mysql mysqli PDO pdo_mysql pgsql pdo_pgsql ldap tidy pspell sqlite3 pdo_sqlite zip; do
    grep -Fxq "$module" <<<"$modules" || die "expected PHP module missing: ${module}"
  done

  if [ "$ENABLE_IONCUBE" = "1" ]; then
    log "testing ionCube Loader through production PHP configuration"
    "$php_bin" -r 'if (!function_exists("ioncube_loader_version")) { fwrite(STDERR,"ionCube Loader is not active\n"); exit(1); } echo ioncube_loader_version(),"\n";'
  fi

  curl_version="$("$php_bin" -n -r '$v=curl_version(); echo $v["version"];' 2>/dev/null)"
  curl_tls="$("$php_bin" -n -r '$v=curl_version(); echo $v["ssl_version"];' 2>/dev/null)"
  [ "$curl_version" = "$CURL_VERSION" ] || \
    die "PHP loaded libcurl ${curl_version:-unknown}, expected ${CURL_VERSION}."
  case "$curl_tls" in
    *GnuTLS*) ;;
    *) die "PHP's libcurl uses an unexpected TLS backend: ${curl_tls:-unknown}" ;;
  esac

  curl_libdir="$(find_libdir "$CURL_PREFIX" 'libcurl.so.4*')" || \
    die "private curl library directory not found during verification."
  openssl_libdir="$(find_libdir "$OPENSSL_PREFIX" 'libssl.so.3')" || \
    die "private OpenSSL library directory not found during verification."
  ldd_text="$(ldd "$php_bin" 2>/dev/null)"

  grep -F "libssl.so.3 => ${openssl_libdir}/" <<<"$ldd_text" >/dev/null || \
    die "PHP is not loading private libssl.so.3 from ${openssl_libdir}."
  grep -F "libcrypto.so.3 => ${openssl_libdir}/" <<<"$ldd_text" >/dev/null || \
    die "PHP is not loading private libcrypto.so.3 from ${openssl_libdir}."

  grep -F "libcurl.so.4 => ${curl_libdir}/" <<<"$ldd_text" >/dev/null || \
    die "PHP is not loading the private libcurl from ${curl_libdir}."
  if grep -Eq 'lib(ssl|crypto)\.so\.1\.1([[:space:]]|$)' <<<"$ldd_text"; then
    printf '%s\n' "$ldd_text" | grep -E 'lib(curl|ssl|crypto)\.so' >&2 || true
    die "OpenSSL 1.1 is also loaded; refusing a mixed-ABI PHP build."
  fi

  # This catches the exact mixed-OpenSSL regression that previously caused
  # curl_exec() to segfault. Network/TLS policy failures warn, signals fail.
  if "$php_bin" -n -r '
    $c = curl_init("https://example.com/");
    curl_setopt($c, CURLOPT_RETURNTRANSFER, true);
    curl_setopt($c, CURLOPT_TIMEOUT, 15);
    $data = curl_exec($c);
    if ($data === false) {
        fwrite(STDERR, curl_error($c));
        curl_close($c);
        exit(2);
    }
    curl_close($c);
  ' >/dev/null; then
    log "HTTPS curl smoke test passed"
  else
    smoke_rc=$?
    case "$smoke_rc" in
      134|139) die "HTTPS curl smoke test crashed (exit ${smoke_rc})." ;;
      *) warn "HTTPS curl smoke test could not complete (exit ${smoke_rc}); build linkage is otherwise valid." ;;
    esac
  fi

  if [ -f "${PREFIX}/etc/php-fpm.conf" ]; then
    log "testing FPM configuration"
    "$fpm_bin" -t
  else
    warn "FPM binary built, but no active php-fpm.conf was produced."
  fi

  log "installed: $("$php_bin" -n -v | sed -n '1p')"
  log "FPM: $("$fpm_bin" -v 2>&1 | sed -n '1p')"
  log "OpenSSL: ${openssl_text}"
  log "libcurl: ${curl_version} (${curl_tls})"
  log "dynamic TLS libraries:"
  printf '%s\n' "$ldd_text" | grep -E 'lib(curl|ssl|crypto|gnutls)\.so' | sed 's/^/    /' || true

  if [ "$ENABLE_LEGACY_PROVIDER" = "1" ]; then
    log "testing installed OpenSSL legacy provider through default PHP config"
    "$php_bin" -n -r '$d=openssl_digest("abc","md4"); var_dump($d === "a448017aaf21d8525fc10ae87aa6729d"); if ($d !== "a448017aaf21d8525fc10ae87aa6729d") exit(1);'
  fi

  cat <<EOF

Build complete. NGM will auto-discover:

  ${fpm_bin}

Enable it in the NGM configuration with:

  phpfpm:
    versions:
      "${PHP_SERIES}": {}
EOF
}

run_regression_tests() {
  local test

  if [ "$RUN_REGRESSION_TESTS" != "1" ]; then
    log "post-build regression suite disabled"
    return
  fi

  for test in \
    test-openssl35-dev.sh \
    test-openssl35-legacy.sh \
    test-openssl35-phar.sh; do
    [ -r "${REPO_DIR}/${test}" ] || die "required regression test missing: ${REPO_DIR}/${test}"
    log "running ${test} against ${PREFIX}"
    PHP_PREFIX="$PREFIX" OPENSSL_PREFIX="$OPENSSL_PREFIX" bash "${REPO_DIR}/${test}"
  done

  log "all PHP ${PHP_SERIES} production regression suites passed"
}

# ── CloudLinux security patch series ─────────────────────────────────────────
# Apply the security/bug backports imported from CloudLinux's public EA4 SRPM
# (see patches/README.md + tools/import-cloudlinux-patches.py) onto the freshly
# fetched source, before buildconf. patches/ is verbatim CloudLinux, in apply
# order; patches-local/ is our hand-maintained overlay that survives a refresh:
# `exclude` lists series entries we skip (with reasons), and patches-local/*.patch
# are our own adaptations, applied after the vendor series.
#
# Two file classes are expected to reject and are NOT failures: patch hunks under
# */tests/ (test fixtures, never built into the runtime), and the re2c-generated
# ext/date/lib/parse_date.c + ext/standard/var_unserializer.c — their .re source
# applies cleanly and re2c regenerates the .c during the build, so we drop the
# stale .c to force that. Any OTHER reject stops the build (never ship a security
# patch that silently half-applied).
apply_patches() {
  [ "$APPLY_PATCHES" = "1" ] || { log "APPLY_PATCHES=0 — building pristine (no security series)"; return; }
  local series="${SRC_DIR}/patches/series"
  [ -f "$series" ] || { warn "no patches/series in source — building without the security backports"; return; }

  pushd "$SRC_DIR" >/dev/null
    local excl="patches-local/exclude" applied=0 skipped=0
    log "applying CloudLinux security patch series"
    while read -r f rest; do
      [ -z "$f" ] && continue
      case "$f" in \#*) continue ;; esac
      if [ -f "$excl" ] && grep -vE '^[[:space:]]*#' "$excl" | grep -qxF "$f"; then
        skipped=$((skipped+1)); continue
      fi
      local pl=1; case "$rest" in *-p0*) pl=0 ;; *-p2*) pl=2 ;; esac
      patch -p"$pl" --no-backup-if-mismatch -s -i "patches/$f" || true
      applied=$((applied+1))
    done < "$series"

    if [ -d patches-local ]; then
      for lp in patches-local/*.patch; do
        [ -e "$lp" ] || continue
        log "  local adaptation: $lp"
        patch -p1 --no-backup-if-mismatch -s -i "$lp" || die "local patch failed to apply: $lp"
      done
    fi

    # Fail on any reject outside the two expected classes (tests + regenerated .c).
    local bad
    bad="$(find . -name '*.rej' | grep -vE '/tests/|/parse_date\.c\.rej$|/var_unserializer\.c\.rej$' || true)"
    if [ -n "$bad" ]; then
      warn "unexpected patch rejects:"; printf '%s\n' "$bad" >&2
      die "refusing to build with half-applied security patches (resolve via patches-local/)"
    fi

    # The generated .c hunks for these two files reject on purpose: their .re is
    # the source of truth and applies cleanly, but PHP 5.3 ships the .c pre-built
    # (re2c 0.13.5) with NO make rule to rebuild parse_date.c — so patching the
    # stale .c is both futile and version-fragile. Regenerate both from the patched
    # .re with the flags the pristine files carry (parse_date: -d -b; the
    # var_unserializer Makefile.frag uses -b), discarding the half-applied .c.
    local re2c="${TOOLCHAIN}/bin/re2c"
    [ -x "$re2c" ] || die "re2c missing at ${re2c} — toolchain must be built before apply_patches"
    log "  regenerating ext/date/lib/parse_date.c from patched .re (re2c -d -b)"
    "$re2c" -d -b -o ext/date/lib/parse_date.c ext/date/lib/parse_date.re
    log "  regenerating ext/standard/var_unserializer.c from patched .re (re2c -b)"
    "$re2c" -b -o ext/standard/var_unserializer.c ext/standard/var_unserializer.re
    local g
    for g in ext/date/lib/parse_date.c ext/standard/var_unserializer.c; do
      [ -s "$g" ] || die "re2c produced an empty ${g}"
    done
    find . -name '*.rej' -delete 2>/dev/null || true
    log "security series applied (${applied} patches, ${skipped} excluded; 2 generated files rebuilt)"
  popd >/dev/null
}

main() {
  need_root
  mkdir -p "$BUILD_ROOT" "$NGM_ROOT"

  if [ "$RUNTIME_ONLY" = "1" ]; then
    log "runtime-only provisioning / verification for PHP ${PHP_RELEASE} at ${PREFIX}"
    [ -x "${PREFIX}/bin/php" ] || die "existing PHP CLI binary missing: ${PREFIX}/bin/php"
    [ -x "${PREFIX}/sbin/php-fpm" ] || die "existing PHP FPM binary missing: ${PREFIX}/sbin/php-fpm"
    find_libdir "$OPENSSL_PREFIX" 'libssl.so.3' >/dev/null || die "private OpenSSL 3 runtime missing under ${OPENSSL_PREFIX}."
    provision_openssl_runtime_files
    install_runtime_extensions
    verify
    run_regression_tests
    return
  fi

  log "building PHP ${PHP_RELEASE} -> ${PREFIX} (jobs=${JOBS})"
  install_deps
  need_command curl
  need_command git
  need_command make

  build_openssl
  provision_openssl_runtime_files
  build_curl
  build_libmcrypt
  detect_php_libdir_name
  ensure_configure_lib_alias "$OPENSSL_PREFIX" 'libssl.so.3'
  ensure_configure_lib_alias "$CURL_PREFIX" 'libcurl.so.4*'
  ensure_configure_lib_alias "$MCRYPT_PREFIX" 'libmcrypt.so*'
  fetch_php_source

  if source_has_generated_files; then
    log "source contains all generated files; private generator toolchain is not required"
  else
    log "raw git source detected; building PHP 5.3 generator toolchain"
    build_toolchain
  fi

  apply_patches   # after the toolchain: needs re2c to regenerate parse_date.c/var_unserializer.c
  build_php
  install_runtime_extensions
  verify
  run_regression_tests
}

main "$@"
