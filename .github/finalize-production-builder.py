from pathlib import Path

p = Path("build-php53.sh")
t = p.read_text(encoding="utf-8")


def once(old, new, label):
    global t
    count = t.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected one match, found {count}")
    t = t.replace(old, new, 1)


once(
    "# FORCE_DEPS=1 additionally rebuilds the private dependency/toolchain prefixes.\n",
    "# FORCE_DEPS=1 additionally rebuilds the private dependency/toolchain prefixes.\n"
    "# RUN_REGRESSION_TESTS=0 skips the post-build regression suite.\n"
    "# ENABLE_LEGACY_PROVIDER=0 disables the private OpenSSL legacy provider.\n",
    "usage controls",
)

once(
    "set -Eeuo pipefail\n\n# ── Versions and paths",
    "set -Eeuo pipefail\n\nREPO_DIR=\"$(cd \"$(dirname \"${BASH_SOURCE[0]}\")\" && pwd)\"\n\n# ── Versions and paths",
    "repo dir",
)

once(
    'FORCE_DEPS="${FORCE_DEPS:-0}"\n',
    'FORCE_DEPS="${FORCE_DEPS:-0}"\nRUN_REGRESSION_TESTS="${RUN_REGRESSION_TESTS:-1}"\nENABLE_LEGACY_PROVIDER="${ENABLE_LEGACY_PROVIDER:-1}"\n',
    "runtime controls",
)

start = t.index("provision_openssl_runtime_files() {\n")
end = t.index("\n# ── Private libcurl with GnuTLS", start)
new_provision = r'''provision_openssl_runtime_files() {
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
'''
t = t[:start] + new_provision + t[end:]

verify_anchor = '''  log "dynamic TLS libraries:"
  printf '%s\\n' "$ldd_text" | grep -E 'lib(curl|ssl|crypto|gnutls)\\.so' | sed 's/^/    /' || true

  cat <<EOF
'''
verify_replacement = '''  log "dynamic TLS libraries:"
  printf '%s\\n' "$ldd_text" | grep -E 'lib(curl|ssl|crypto|gnutls)\\.so' | sed 's/^/    /' || true

  if [ "$ENABLE_LEGACY_PROVIDER" = "1" ]; then
    log "testing installed OpenSSL legacy provider through default PHP config"
    "$php_bin" -n -r '$d=openssl_digest("abc","md4"); var_dump($d === "a448017aaf21d8525fc10ae87aa6729d"); if ($d !== "a448017aaf21d8525fc10ae87aa6729d") exit(1);'
  fi

  cat <<EOF
'''
once(verify_anchor, verify_replacement, "installed provider smoke test")

main_anchor = '''main() {
'''
regression_fn = r'''run_regression_tests() {
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

main() {
'''
once(main_anchor, regression_fn, "regression function")

once(
    "  build_php\n  verify\n}\n\nmain \"$@\"",
    "  build_php\n  verify\n  run_regression_tests\n}\n\nmain \"$@\"",
    "run regressions",
)

p.write_text(t, encoding="utf-8")
