#!/usr/bin/env bash
#
# build-php53.sh — build PHP 5.3.29 for NGM on Debian trixie / AlmaLinux 10
#
# Installs the FPM binary where NGM auto-discovers it:
#
#   /opt/ngm/php/5.3/sbin/php-fpm
#
# PHP 5.3 cannot use OpenSSL 1.1+ without a large source backport: its OpenSSL
# extension accesses structures that became opaque in 1.1. This script therefore
# builds a private OpenSSL 1.0.2u under a separate prefix.
#
# The host libcurl must not be used: on current distributions it loads OpenSSL 3,
# which conflicts with PHP's private OpenSSL 1.0.2 in the same process and causes
# curl_exec() to segfault. A private current libcurl is built with GnuTLS instead,
# so PHP has only one OpenSSL ABI loaded while HTTPS through ext/curl remains safe.
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

set -Eeuo pipefail

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
OPENSSL_VERSION="1.0.2u"
OPENSSL_PREFIX="${OPENSSL_PREFIX:-${NGM_ROOT}/openssl-1.0.2}"
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
        libgmp-dev libsqlite3-dev zlib1g-dev libgettextpo-dev libcrypt-dev
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
        gmp-devel sqlite-devel zlib-devel gettext-devel libxcrypt-devel
      ;;
  esac
}

# ── Private OpenSSL 1.0.2 ────────────────────────────────────────────────────
build_openssl() {
  local existing_lib=""
  existing_lib="$(find_libdir "$OPENSSL_PREFIX" 'libssl.so.1.0.0' || true)"
  if [ -n "$existing_lib" ] && [ "$FORCE_DEPS" != "1" ]; then
    log "OpenSSL ${OPENSSL_VERSION} already at ${OPENSSL_PREFIX}"
    return
  fi

  local tarball="${BUILD_ROOT}/openssl-${OPENSSL_VERSION}.tar.gz"
  fetch "https://www.openssl.org/source/old/1.0.2/openssl-${OPENSSL_VERSION}.tar.gz" "$tarball"

  rm -rf "${BUILD_ROOT}/openssl-${OPENSSL_VERSION}"
  tar -xzf "$tarball" -C "$BUILD_ROOT"

  pushd "${BUILD_ROOT}/openssl-${OPENSSL_VERSION}" >/dev/null
    log "building OpenSSL ${OPENSSL_VERSION} -> ${OPENSSL_PREFIX}"
    # Do not disable SSLv3 here: PHP 5.3 references SSLv3_* methods without
    # OPENSSL_NO_SSL3 guards. Protocol policy belongs in application/FPM config.
    ./config \
      --prefix="${OPENSSL_PREFIX}" \
      --openssldir="${OPENSSL_PREFIX}" \
      shared zlib -fPIC
    make depend
    make -j"$JOBS"
    make install_sw
  popd >/dev/null

  find_libdir "$OPENSSL_PREFIX" 'libssl.so.1.0.0' >/dev/null || \
    die "OpenSSL installed, but libssl.so.1.0.0 was not found under ${OPENSSL_PREFIX}."
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

  local openssl_libdir curl_libdir mcrypt_libdir
  openssl_libdir="$(find_libdir "$OPENSSL_PREFIX" 'libssl.so.1.0.0')" || \
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
      --enable-fpm \
      --with-fpm-user="${FPM_USER}" \
      --with-fpm-group="${FPM_GROUP}" \
      --with-openssl="${OPENSSL_PREFIX}" \
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
  popd >/dev/null
}

verify() {
  local php_bin="${PREFIX}/bin/php"
  local fpm_bin="${PREFIX}/sbin/php-fpm"
  local modules module actual_version openssl_text
  local curl_version curl_tls curl_libdir ldd_text smoke_rc

  [ -x "$php_bin" ] || die "expected CLI binary missing: ${php_bin}"
  [ -x "$fpm_bin" ] || die "expected FPM binary missing: ${fpm_bin}"

  actual_version="$("$php_bin" -n -r 'echo PHP_VERSION;' 2>/dev/null)"
  [ "$actual_version" = "$PHP_RELEASE" ] || \
    die "built PHP reports ${actual_version}, expected ${PHP_RELEASE}."

  openssl_text="$("$php_bin" -n -r 'echo OPENSSL_VERSION_TEXT;' 2>/dev/null)"
  case "$openssl_text" in
    *"OpenSSL 1.0.2u"*) ;;
    *) die "PHP loaded an unexpected OpenSSL: ${openssl_text:-unknown}" ;;
  esac

  modules="$("$php_bin" -n -m 2>/dev/null)"
  for module in openssl curl gd mbstring mcrypt mysql mysqli PDO pdo_mysql zip; do
    grep -Fxq "$module" <<<"$modules" || die "expected PHP module missing: ${module}"
  done

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
  ldd_text="$(ldd "$php_bin" 2>/dev/null)"

  grep -F "libcurl.so.4 => ${curl_libdir}/" <<<"$ldd_text" >/dev/null || \
    die "PHP is not loading the private libcurl from ${curl_libdir}."
  if grep -Eq 'lib(ssl|crypto)\.so\.3([[:space:]]|$)' <<<"$ldd_text"; then
    printf '%s\n' "$ldd_text" | grep -E 'lib(curl|ssl|crypto)\.so' >&2 || true
    die "OpenSSL 3 is still loaded; refusing an unsafe mixed-ABI PHP build."
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

  log "installed: $("$php_bin" -n -v | sed -n '1p')"
  log "FPM: $("$fpm_bin" -v 2>&1 | sed -n '1p')"
  log "OpenSSL: ${openssl_text}"
  log "libcurl: ${curl_version} (${curl_tls})"
  log "dynamic TLS libraries:"
  printf '%s\n' "$ldd_text" | grep -E 'lib(curl|ssl|crypto|gnutls)\.so' | sed 's/^/    /' || true

  cat <<EOF

Build complete. NGM will auto-discover:

  ${fpm_bin}

Enable it in the NGM configuration with:

  phpfpm:
    versions:
      "${PHP_SERIES}": {}
EOF
}

main() {
  need_root
  mkdir -p "$BUILD_ROOT" "$NGM_ROOT"

  log "building PHP ${PHP_RELEASE} -> ${PREFIX} (jobs=${JOBS})"
  install_deps
  need_command curl
  need_command git
  need_command make

  build_openssl
  build_curl
  build_libmcrypt
  fetch_php_source

  if source_has_generated_files; then
    log "source contains all generated files; private generator toolchain is not required"
  else
    log "raw git source detected; building PHP 5.3 generator toolchain"
    build_toolchain
  fi

  build_php
  verify
}

main "$@"
