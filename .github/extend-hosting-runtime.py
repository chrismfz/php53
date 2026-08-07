from pathlib import Path

p = Path('build-php53.sh')
t = p.read_text(encoding='utf-8')

def once(old, new, label):
    global t
    count = t.count(old)
    if count != 1:
        raise SystemExit(f'{label}: expected one match, found {count}')
    t = t.replace(old, new, 1)

once(
'''RUN_REGRESSION_TESTS="${RUN_REGRESSION_TESTS:-1}"
ENABLE_LEGACY_PROVIDER="${ENABLE_LEGACY_PROVIDER:-1}"
RUNTIME_ONLY="${RUNTIME_ONLY:-0}"
''',
'''RUN_REGRESSION_TESTS="${RUN_REGRESSION_TESTS:-1}"
ENABLE_LEGACY_PROVIDER="${ENABLE_LEGACY_PROVIDER:-1}"
ENABLE_IONCUBE="${ENABLE_IONCUBE:-1}"
RUNTIME_ONLY="${RUNTIME_ONLY:-0}"
PHP_LIBDIR_NAME="${PHP_LIBDIR_NAME:-}"
IONCUBE_LOADER="${REPO_DIR}/ioncube/ioncube_loader_lin_${PHP_SERIES}.so"
''', 'runtime variables')

once(
'''find_ca_bundle() {
  local file
  for file in \\
    /etc/pki/tls/certs/ca-bundle.crt \\
    /etc/ssl/certs/ca-certificates.crt \\
    /etc/ssl/ca-bundle.pem; do
    if [ -s "$file" ]; then
      printf '%s\\n' "$file"
      return 0
    fi
  done
  return 1
}
''',
'''find_ca_bundle() {
  local file
  for file in \\
    /etc/pki/tls/certs/ca-bundle.crt \\
    /etc/ssl/certs/ca-certificates.crt \\
    /etc/ssl/ca-bundle.pem; do
    if [ -s "$file" ]; then
      printf '%s\\n' "$file"
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
''', 'libdir helpers')

once(
'''        libfreetype6-dev libbz2-dev libreadline-dev libxslt1-dev \\
        libgmp-dev libsqlite3-dev zlib1g-dev libgettextpo-dev libcrypt-dev
''',
'''        libfreetype6-dev libbz2-dev libreadline-dev libxslt1-dev \\
        libgmp-dev libsqlite3-dev zlib1g-dev libgettextpo-dev libcrypt-dev \\
        libpq-dev libldap2-dev libsasl2-dev libtidy-dev libaspell-dev libsnmp-dev
''', 'apt dependencies')

once(
'''        freetype-devel bzip2-devel readline-devel libxslt-devel \\
        gmp-devel sqlite-devel zlib-devel gettext-devel libxcrypt-devel
''',
'''        freetype-devel bzip2-devel readline-devel libxslt-devel \\
        gmp-devel sqlite-devel zlib-devel gettext-devel libxcrypt-devel \\
        libpq-devel openldap-devel cyrus-sasl-devel libtidy-devel aspell-devel \\
        net-snmp-devel net-snmp-utils
''', 'dnf dependencies')

once(
'''      --with-config-file-path="${PREFIX}/etc" \\
      --with-config-file-scan-dir="${PREFIX}/etc/conf.d" \\
      --enable-fpm \\
''',
'''      --with-config-file-path="${PREFIX}/etc" \\
      --with-config-file-scan-dir="${PREFIX}/etc/conf.d" \\
      --with-libdir="${PHP_LIBDIR_NAME}" \\
      --enable-fpm \\
''', 'configure libdir')

once(
'''      --with-mysql=mysqlnd \\
      --with-mysqli=mysqlnd \\
      --with-pdo-mysql=mysqlnd \\
      --with-readline \\
''',
'''      --with-mysql=mysqlnd \\
      --with-mysqli=mysqlnd \\
      --with-pdo-mysql=mysqlnd \\
      --with-pgsql \\
      --with-pdo-pgsql \\
      --with-ldap=/usr \\
      --with-ldap-sasl=/usr \\
      --with-tidy=/usr \\
      --with-pspell=/usr \\
      --with-snmp \\
      --with-sqlite3=/usr \\
      --with-pdo-sqlite=/usr \\
      --with-readline \\
''', 'hosting configure extensions')

marker = '''verify() {
'''
install_fn = r'''install_runtime_extensions() {
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

'''
once(marker, install_fn + marker, 'runtime extension installer')

once(
'''  for module in openssl curl gd mbstring mcrypt mysql mysqli PDO pdo_mysql zip; do
''',
'''  for module in openssl curl gd mbstring mcrypt mysql mysqli PDO pdo_mysql pgsql pdo_pgsql ldap tidy pspell snmp sqlite3 pdo_sqlite zip; do
''', 'module verification list')

once(
'''  curl_version="$("$php_bin" -n -r '$v=curl_version(); echo $v["version"];' 2>/dev/null)"
''',
'''  if [ "$ENABLE_IONCUBE" = "1" ]; then
    log "testing ionCube Loader through production PHP configuration"
    "$php_bin" -r 'if (!function_exists("ioncube_loader_version")) { fwrite(STDERR,"ionCube Loader is not active\\n"); exit(1); } echo ioncube_loader_version(),"\\n";'
  fi

  curl_version="$("$php_bin" -n -r '$v=curl_version(); echo $v["version"];' 2>/dev/null)"
''', 'ioncube verification')

once(
'''    provision_openssl_runtime_files
    verify
''',
'''    provision_openssl_runtime_files
    install_runtime_extensions
    verify
''', 'runtime-only install')

once(
'''  build_openssl
  provision_openssl_runtime_files
  build_curl
  build_libmcrypt
  fetch_php_source
''',
'''  build_openssl
  provision_openssl_runtime_files
  build_curl
  build_libmcrypt
  detect_php_libdir_name
  ensure_configure_lib_alias "$OPENSSL_PREFIX" 'libssl.so.3'
  ensure_configure_lib_alias "$CURL_PREFIX" 'libcurl.so.4*'
  ensure_configure_lib_alias "$MCRYPT_PREFIX" 'libmcrypt.so*'
  fetch_php_source
''', 'full build libdir setup')

once(
'''  build_php
  verify
  run_regression_tests
''',
'''  build_php
  install_runtime_extensions
  verify
  run_regression_tests
''', 'full build runtime extensions')

# Document the additional toggles.
once(
'''# ENABLE_LEGACY_PROVIDER=0 disables the private OpenSSL legacy provider.
''',
'''# ENABLE_LEGACY_PROVIDER=0 disables the private OpenSSL legacy provider.
# ENABLE_IONCUBE=0 skips installing/enabling the bundled ionCube Loader.
# PHP_LIBDIR_NAME=... overrides the system library directory used by configure.
''', 'usage docs')

p.write_text(t, encoding='utf-8')
