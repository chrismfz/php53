from pathlib import Path

p = Path("build-php53.sh")
t = p.read_text(encoding="utf-8")


def once(old, new, label):
    global t
    count = t.count(old)
    if count != 1:
        raise SystemExit("%s: expected one match, found %d" % (label, count))
    t = t.replace(old, new, 1)


once(
    """# PHP 5.3 needs source compatibility backports for OpenSSL 1.1 because its
# OpenSSL extension accesses structures that became opaque in 1.1. This script
# now targets private OpenSSL 1.1.1w, matching the PHP 5.6 legacy runtime.
#
# The host libcurl must not be used: on current distributions it loads OpenSSL 3,
# which must not be mixed with PHP's private OpenSSL in the same process and can cause
# curl_exec() to segfault. A private current libcurl is built with GnuTLS instead,
# so PHP has only one OpenSSL ABI loaded while HTTPS through ext/curl remains safe.""",
    """# PHP 5.3 carries source compatibility backports for modern OpenSSL and now
# targets the private OpenSSL 3.5 LTS runtime used by the maintained NGM builds.
#
# The host libcurl must not be used: on current distributions it may bind the PHP
# process to the distro OpenSSL 3 runtime instead of NGM's private OpenSSL 3.5.
# A private current libcurl is built with GnuTLS so ext/curl cannot introduce a
# second OpenSSL implementation into the process.""",
    "header OpenSSL comments",
)

once('OPENSSL_VERSION="1.1.1w"', 'OPENSSL_VERSION="${OPENSSL_VERSION:-3.5.7}"', "OpenSSL version")
once('OPENSSL_PREFIX="${OPENSSL_PREFIX:-${NGM_ROOT}/openssl-1.1}"', 'OPENSSL_PREFIX="${OPENSSL_PREFIX:-${NGM_ROOT}/openssl-3.5}"', "OpenSSL prefix")

section_start = t.index("# ── Private OpenSSL 1.1.1")
section_end = t.index("# ── Private libcurl with GnuTLS", section_start)
new_section = '''# ── Private OpenSSL 3.5 LTS ─────────────────────────────────────────────────
build_openssl() {
  local existing_lib="" tarball="${BUILD_ROOT}/openssl-${OPENSSL_VERSION}.tar.gz"
  mkdir -p "$BUILD_ROOT"

  # Keep the matching source tarball even when OpenSSL is already installed;
  # provisioning openssl.cnf uses the release's canonical configuration.
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
t = t[:section_start] + new_section + t[section_end:]

once(
    "  local openssl_libdir curl_libdir mcrypt_libdir\n",
    "  local openssl_libdir curl_libdir mcrypt_libdir openssl_pc_prefix\n",
    "build_php locals",
)
once(
    """  openssl_libdir="$(find_libdir "$OPENSSL_PREFIX" 'libssl.so.1.1')" || \
    die "private OpenSSL library directory not found."""",
    """  openssl_libdir="$(find_libdir "$OPENSSL_PREFIX" 'libssl.so.3')" || \
    die "private OpenSSL library directory not found."""",
    "build_php OpenSSL lib lookup",
)

pkg_anchor = '  export LDFLAGS="-L${curl_libdir} -L${openssl_libdir} -L${mcrypt_libdir} -Wl,-rpath,${curl_libdir} -Wl,-rpath,${openssl_libdir} -Wl,-rpath,${mcrypt_libdir} ${LDFLAGS:-}"\n'
pkg_block = pkg_anchor + '''
  pkg-config --exists openssl || die "private OpenSSL pkg-config metadata not found."
  openssl_pc_prefix="$(pkg-config --variable=prefix openssl)"
  [ "$openssl_pc_prefix" = "$OPENSSL_PREFIX" ] || \
    die "pkg-config resolved OpenSSL from ${openssl_pc_prefix}, expected ${OPENSSL_PREFIX}."
'''
once(pkg_anchor, pkg_block, "pkg-config verification")

once('      --with-openssl="${OPENSSL_PREFIX}" \\\n', '      --with-openssl \\\n', "configure OpenSSL selection")

ini_anchor = '''    if [ ! -f "${PREFIX}/etc/php.ini" ]; then
      cp php.ini-production "${PREFIX}/etc/php.ini"
    fi'''
ini_block = ini_anchor + '''

    if [ ! -f "${PREFIX}/etc/php-fpm.conf" ] && [ -f "${PREFIX}/etc/php-fpm.conf.default" ]; then
      cp "${PREFIX}/etc/php-fpm.conf.default" "${PREFIX}/etc/php-fpm.conf"
    fi'''
once(ini_anchor, ini_block, "FPM config promotion")

once(
    "  local curl_version curl_tls curl_libdir ldd_text smoke_rc\n",
    "  local curl_version curl_tls curl_libdir openssl_libdir ldd_text smoke_rc\n",
    "verify locals",
)
once(
    '''  case "$openssl_text" in
    *"OpenSSL 1.1.1w"*) ;;
    *) die "PHP loaded an unexpected OpenSSL: ${openssl_text:-unknown}" ;;
  esac''',
    '''  case "$openssl_text" in
    *"OpenSSL ${OPENSSL_VERSION}"*) ;;
    *) die "PHP loaded an unexpected OpenSSL: ${openssl_text:-unknown}" ;;
  esac''',
    "OpenSSL runtime version",
)

ldd_anchor = '''  curl_libdir="$(find_libdir "$CURL_PREFIX" 'libcurl.so.4*')" || \
    die "private curl library directory not found during verification."
  ldd_text="$(ldd "$php_bin" 2>/dev/null)"

  grep -F "libcurl.so.4 => ${curl_libdir}/" <<<"$ldd_text" >/dev/null || \
    die "PHP is not loading the private libcurl from ${curl_libdir}."'''
ldd_block = '''  curl_libdir="$(find_libdir "$CURL_PREFIX" 'libcurl.so.4*')" || \
    die "private curl library directory not found during verification."
  openssl_libdir="$(find_libdir "$OPENSSL_PREFIX" 'libssl.so.3')" || \
    die "private OpenSSL library directory not found during verification."
  ldd_text="$(ldd "$php_bin" 2>/dev/null)"

  grep -F "libssl.so.3 => ${openssl_libdir}/" <<<"$ldd_text" >/dev/null || \
    die "PHP is not loading private libssl.so.3 from ${openssl_libdir}."
  grep -F "libcrypto.so.3 => ${openssl_libdir}/" <<<"$ldd_text" >/dev/null || \
    die "PHP is not loading private libcrypto.so.3 from ${openssl_libdir}."
  grep -F "libcurl.so.4 => ${curl_libdir}/" <<<"$ldd_text" >/dev/null || \
    die "PHP is not loading the private libcurl from ${curl_libdir}."'''
once(ldd_anchor, ldd_block, "direct OpenSSL linkage checks")

once(
    '''  if grep -Eq 'lib(ssl|crypto)\\.so\\.3([[:space:]]|$)' <<<"$ldd_text"; then
    printf '%s\\n' "$ldd_text" | grep -E 'lib(curl|ssl|crypto)\\.so' >&2 || true
    die "OpenSSL 3 is still loaded; refusing an unsafe mixed-ABI PHP build."
  fi''',
    '''  if grep -Eq 'lib(ssl|crypto)\\.so\\.1\\.1([[:space:]]|$)' <<<"$ldd_text"; then
    printf '%s\\n' "$ldd_text" | grep -E 'lib(curl|ssl|crypto)\\.so' >&2 || true
    die "OpenSSL 1.1 is also loaded; refusing a mixed-ABI PHP build."
  fi''',
    "mixed ABI guard",
)

smoke_end = '''  fi

  log "installed: $("$php_bin" -n -v | sed -n '1p')"'''
smoke_new = '''  fi

  if [ -f "${PREFIX}/etc/php-fpm.conf" ]; then
    log "testing FPM configuration"
    "$fpm_bin" -t
  else
    warn "FPM binary built, but no active php-fpm.conf was produced."
  fi

  log "installed: $("$php_bin" -n -v | sed -n '1p')"'''
once(smoke_end, smoke_new, "FPM runtime verification")

once(
    "  build_openssl\n  build_curl",
    "  build_openssl\n  provision_openssl_runtime_files\n  build_curl",
    "OpenSSL runtime provisioning call",
)

p.write_text(t, encoding="utf-8")
