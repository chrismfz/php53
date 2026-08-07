from pathlib import Path
import re

p = Path("build-php53.sh")
t = p.read_text(encoding="utf-8")


def once(old, new, label):
    global t
    count = t.count(old)
    if count != 1:
        raise SystemExit("%s: expected one match, found %d" % (label, count))
    t = t.replace(old, new, 1)


def sub_once(pattern, replacement, label, flags=0):
    global t
    t2, count = re.subn(pattern, replacement, t, count=1, flags=flags)
    if count != 1:
        raise SystemExit("%s: expected one match, found %d" % (label, count))
    t = t2


# Documentation and defaults.
once("# PHP 5.3 needs source compatibility backports for OpenSSL 1.1 because its", "# PHP 5.3 carries source compatibility backports for modern OpenSSL and", "header line 1")
once("# OpenSSL extension accesses structures that became opaque in 1.1. This script", "# targets the private OpenSSL 3.5 LTS runtime used by the maintained NGM builds.", "header line 2")
once("# now targets private OpenSSL 1.1.1w, matching the PHP 5.6 legacy runtime.", "# Compatibility/security changes live in the tracked PHP source.", "header line 3")
once("# The host libcurl must not be used: on current distributions it loads OpenSSL 3,", "# The host libcurl must not be used: it may bind the process to distro OpenSSL 3", "curl comment 1")
once("# which must not be mixed with PHP's private OpenSSL in the same process and can cause", "# instead of NGM's private OpenSSL 3.5 and undermine runtime isolation. A private", "curl comment 2")
once("# curl_exec() to segfault. A private current libcurl is built with GnuTLS instead,", "# current libcurl is built with GnuTLS instead, so ext/curl cannot introduce a", "curl comment 3")
once("# so PHP has only one OpenSSL ABI loaded while HTTPS through ext/curl remains safe.", "# second OpenSSL implementation into the PHP process.", "curl comment 4")
once('OPENSSL_VERSION="1.1.1w"', 'OPENSSL_VERSION="${OPENSSL_VERSION:-3.5.7}"', "OpenSSL version")
once('OPENSSL_PREFIX="${OPENSSL_PREFIX:-${NGM_ROOT}/openssl-1.1}"', 'OPENSSL_PREFIX="${OPENSSL_PREFIX:-${NGM_ROOT}/openssl-3.5}"', "OpenSSL prefix")

# Replace the complete private OpenSSL dependency section.
new_openssl = '''# ── Private OpenSSL 3.5 LTS ─────────────────────────────────────────────────
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
    ./config \\
      --prefix="${OPENSSL_PREFIX}" \\
      --openssldir="${OPENSSL_PREFIX}" \\
      shared zlib -fPIC
    make -j"$JOBS"
    make install_sw
  popd >/dev/null

  find_libdir "$OPENSSL_PREFIX" 'libssl.so.3' >/dev/null || \\
    die "OpenSSL installed, but libssl.so.3 was not found under ${OPENSSL_PREFIX}."
}

provision_openssl_runtime_files() {
  local tarball="${BUILD_ROOT}/openssl-${OPENSSL_VERSION}.tar.gz" ca_bundle

  install -d -m 755 "${OPENSSL_PREFIX}/certs"
  install -d -m 700 "${OPENSSL_PREFIX}/private"

  if [ ! -s "${OPENSSL_PREFIX}/openssl.cnf" ]; then
    [ -s "$tarball" ] || die "OpenSSL source tarball missing; cannot provision openssl.cnf."
    log "installing OpenSSL ${OPENSSL_VERSION} configuration"
    tar -xOf "$tarball" "openssl-${OPENSSL_VERSION}/apps/openssl.cnf" > "${OPENSSL_PREFIX}/openssl.cnf"
    chmod 644 "${OPENSSL_PREFIX}/openssl.cnf"
  fi

  ca_bundle="$(find_ca_bundle)" || die "could not locate the system CA bundle."
  ln -sfn "$ca_bundle" "${OPENSSL_PREFIX}/cert.pem"

  [ -r "${OPENSSL_PREFIX}/openssl.cnf" ] || die "OpenSSL configuration is not readable."
  [ -r "${OPENSSL_PREFIX}/cert.pem" ] || die "OpenSSL CA bundle link is not readable."
}

'''
sub_once(r"# ── Private OpenSSL 1\.1\.1.*?(?=# ── Private libcurl with GnuTLS)", lambda m: new_openssl, "OpenSSL dependency section", re.S)

# PHP configure/link settings. PHP 5.3 supports pkg-config when --with-openssl
# is supplied without an explicit path, which correctly handles lib64.
once("  local openssl_libdir curl_libdir mcrypt_libdir\n", "  local openssl_libdir curl_libdir mcrypt_libdir openssl_pc_prefix\n", "build locals")
once("'libssl.so.1.1'", "'libssl.so.3'", "OpenSSL lib lookup")
ldflags = '  export LDFLAGS="-L${curl_libdir} -L${openssl_libdir} -L${mcrypt_libdir} -Wl,-rpath,${curl_libdir} -Wl,-rpath,${openssl_libdir} -Wl,-rpath,${mcrypt_libdir} ${LDFLAGS:-}"\n'
once(ldflags, ldflags + '''\n  pkg-config --exists openssl || die "private OpenSSL pkg-config metadata not found."\n  openssl_pc_prefix="$(pkg-config --variable=prefix openssl)"\n  [ "$openssl_pc_prefix" = "$OPENSSL_PREFIX" ] || \\\n    die "pkg-config resolved OpenSSL from ${openssl_pc_prefix}, expected ${OPENSSL_PREFIX}."\n''', "pkg-config verification")
once('      --with-openssl="${OPENSSL_PREFIX}" \\\n', '      --with-openssl \\\n', "configure OpenSSL")

# Promote the installed FPM template for a directly runnable NGM prefix.
ini = '''    if [ ! -f "${PREFIX}/etc/php.ini" ]; then
      cp php.ini-production "${PREFIX}/etc/php.ini"
    fi'''
once(ini, ini + '''\n\n    if [ ! -f "${PREFIX}/etc/php-fpm.conf" ] && [ -f "${PREFIX}/etc/php-fpm.conf.default" ]; then\n      cp "${PREFIX}/etc/php-fpm.conf.default" "${PREFIX}/etc/php-fpm.conf"\n    fi''', "FPM config promotion")

# Runtime verification: version, direct OpenSSL 3.5 linkage, reject 1.1.
once("  local curl_version curl_tls curl_libdir ldd_text smoke_rc\n", "  local curl_version curl_tls curl_libdir openssl_libdir ldd_text smoke_rc\n", "verify locals")
once('*"OpenSSL 1.1.1w"*) ;;', '*"OpenSSL ${OPENSSL_VERSION}"*) ;;', "runtime OpenSSL version")

ldd = '''  curl_libdir="$(find_libdir "$CURL_PREFIX" 'libcurl.so.4*')" || \\
    die "private curl library directory not found during verification."
  ldd_text="$(ldd "$php_bin" 2>/dev/null)"'''
once(ldd, '''  curl_libdir="$(find_libdir "$CURL_PREFIX" 'libcurl.so.4*')" || \\
    die "private curl library directory not found during verification."
  openssl_libdir="$(find_libdir "$OPENSSL_PREFIX" 'libssl.so.3')" || \\
    die "private OpenSSL library directory not found during verification."
  ldd_text="$(ldd "$php_bin" 2>/dev/null)"

  grep -F "libssl.so.3 => ${openssl_libdir}/" <<<"$ldd_text" >/dev/null || \\
    die "PHP is not loading private libssl.so.3 from ${openssl_libdir}."
  grep -F "libcrypto.so.3 => ${openssl_libdir}/" <<<"$ldd_text" >/dev/null || \\
    die "PHP is not loading private libcrypto.so.3 from ${openssl_libdir}."''', "direct OpenSSL linkage")
once("lib(ssl|crypto)\\.so\\.3([[:space:]]|$)", "lib(ssl|crypto)\\.so\\.1\\.1([[:space:]]|$)", "mixed ABI regex")
once("OpenSSL 3 is still loaded; refusing an unsafe mixed-ABI PHP build.", "OpenSSL 1.1 is also loaded; refusing a mixed-ABI PHP build.", "mixed ABI message")

install_log = '  log "installed: $("$php_bin" -n -v | sed -n \'1p\')"'
once(install_log, '''  if [ -f "${PREFIX}/etc/php-fpm.conf" ]; then
    log "testing FPM configuration"
    "$fpm_bin" -t
  else
    warn "FPM binary built, but no active php-fpm.conf was produced."
  fi

''' + install_log, "FPM runtime verification")
once("  build_openssl\n  build_curl", "  build_openssl\n  provision_openssl_runtime_files\n  build_curl", "OpenSSL runtime provisioning")

p.write_text(t, encoding="utf-8")
