#!/usr/bin/env bash
set -Eeuo pipefail

NGM_ROOT="${NGM_ROOT:-/opt/ngm/php}"
PHP_PREFIX="${PHP_PREFIX:-${NGM_ROOT}/5.3-openssl35-dev}"
OPENSSL_PREFIX="${OPENSSL_PREFIX:-${NGM_ROOT}/openssl-3.5}"
PHP_BIN="${PHP_PREFIX}/bin/php"
OPENSSL_BIN="${OPENSSL_PREFIX}/bin/openssl"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

find_openssl_libdir() {
  local dir
  for dir in "${OPENSSL_PREFIX}/lib64" "${OPENSSL_PREFIX}/lib"; do
    if [ -e "${dir}/libssl.so.3" ] && [ -e "${dir}/libcrypto.so.3" ]; then
      printf '%s\n' "$dir"
      return 0
    fi
  done
  return 1
}

find_modules_dir() {
  local dir
  for dir in \
    "${OPENSSL_PREFIX}/lib64/ossl-modules" \
    "${OPENSSL_PREFIX}/lib/ossl-modules"; do
    if [ -e "${dir}/legacy.so" ]; then
      printf '%s\n' "$dir"
      return 0
    fi
  done
  return 1
}

[ -x "$PHP_BIN" ] || die "PHP binary missing: ${PHP_BIN}"
[ -x "$OPENSSL_BIN" ] || die "OpenSSL binary missing: ${OPENSSL_BIN}"
[ -r "${OPENSSL_PREFIX}/openssl.cnf" ] || die "base OpenSSL config missing: ${OPENSSL_PREFIX}/openssl.cnf"
openssl_libdir="$(find_openssl_libdir)" || die "private OpenSSL 3 library directory not found"
modules_dir="$(find_modules_dir)" || die "OpenSSL legacy provider module not found"

tmpdir="$(mktemp -d /tmp/php53-openssl35-legacy.XXXXXX)"
trap 'rm -rf "$tmpdir"' EXIT

# Copy the complete known-good OpenSSL config, then reopen its existing
# [openssl_init] section to add provider activation without losing req/CSR data.
cp "${OPENSSL_PREFIX}/openssl.cnf" "${tmpdir}/openssl-legacy.cnf"
cat >> "${tmpdir}/openssl-legacy.cnf" <<'EOF'

[openssl_init]
providers = provider_sect_php53_legacy

[provider_sect_php53_legacy]
default = default_sect_php53_legacy
legacy = legacy_sect_php53_legacy

[default_sect_php53_legacy]
activate = 1

[legacy_sect_php53_legacy]
activate = 1
EOF

export OPENSSL_CONF="${tmpdir}/openssl-legacy.cnf"
export OPENSSL_MODULES="$modules_dir"
export LD_LIBRARY_PATH="${openssl_libdir}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"

log "OpenSSL provider modules"
printf '    config:  %s\n' "$OPENSSL_CONF"
printf '    modules: %s\n' "$OPENSSL_MODULES"
providers="$($OPENSSL_BIN list -providers)"
printf '%s\n' "$providers" | grep -Eq '^[[:space:]]+default$' || die "default provider did not load"
printf '%s\n' "$providers" | grep -Eq '^[[:space:]]+legacy$' || die "legacy provider did not load"

log "MD4 digest via legacy provider"
"$PHP_BIN" -n -r '
$d = openssl_digest("abc", "md4");
var_dump($d === "a448017aaf21d8525fc10ae87aa6729d");
if ($d !== "a448017aaf21d8525fc10ae87aa6729d") {
    while ($e = openssl_error_string()) fwrite(STDERR, $e."\n");
    exit(1);
}
'

log "RC4 encrypt / decrypt"
"$PHP_BIN" -n -r '
$plain = "php53-openssl35-rc4";
$key = "legacy-rc4-key";
$enc = openssl_encrypt($plain, "rc4", $key, true);
if ($enc === false) { while ($e=openssl_error_string()) fwrite(STDERR,$e."\n"); exit(1); }
$dec = openssl_decrypt($enc, "rc4", $key, true);
var_dump($dec === $plain);
if ($dec !== $plain) exit(2);
'

log "RC2-CBC encrypt / decrypt"
"$PHP_BIN" -n -r '
$plain = "php53-openssl35-rc2";
$key = "legacy-rc2-key";
$ivlen = openssl_cipher_iv_length("rc2-cbc");
if ($ivlen <= 0) exit(1);
$iv = str_repeat("R", $ivlen);
$enc = openssl_encrypt($plain, "rc2-cbc", $key, true, $iv);
if ($enc === false) { while ($e=openssl_error_string()) fwrite(STDERR,$e."\n"); exit(2); }
$dec = openssl_decrypt($enc, "rc2-cbc", $key, true, $iv);
var_dump($dec === $plain);
if ($dec !== $plain) exit(3);
'

log "DES-CBC encrypt / decrypt"
"$PHP_BIN" -n -r '
$plain = "php53-openssl35-des";
$key = "12345678";
$ivlen = openssl_cipher_iv_length("des-cbc");
if ($ivlen <= 0) exit(1);
$iv = str_repeat("D", $ivlen);
$enc = openssl_encrypt($plain, "des-cbc", $key, true, $iv);
if ($enc === false) { while ($e=openssl_error_string()) fwrite(STDERR,$e."\n"); exit(2); }
$dec = openssl_decrypt($enc, "des-cbc", $key, true, $iv);
var_dump($dec === $plain);
if ($dec !== $plain) exit(3);
'

log "3DES-CBC encrypt / decrypt"
"$PHP_BIN" -n -r '
$plain = "php53-openssl35-3des";
$key = "0123456789abcdefghijklmn";
$ivlen = openssl_cipher_iv_length("des-ede3-cbc");
if ($ivlen <= 0) exit(1);
$iv = str_repeat("T", $ivlen);
$enc = openssl_encrypt($plain, "des-ede3-cbc", $key, true, $iv);
if ($enc === false) { while ($e=openssl_error_string()) fwrite(STDERR,$e."\n"); exit(2); }
$dec = openssl_decrypt($enc, "des-ede3-cbc", $key, true, $iv);
var_dump($dec === $plain);
if ($dec !== $plain) exit(3);
'

log "openssl_seal / openssl_open default RC4 compatibility"
"$PHP_BIN" -n -r '
$k = openssl_pkey_new(array("private_key_bits"=>2048,"private_key_type"=>OPENSSL_KEYTYPE_RSA));
if ($k === false) exit(1);
$d = openssl_pkey_get_details($k);
$pub = openssl_pkey_get_public($d["key"]);
$plain = "php53-openssl35-seal";
$ekeys = array();
$len = openssl_seal($plain, $sealed, $ekeys, array($pub));
if ($len === false || $len <= 0 || !isset($ekeys[0])) {
    while ($e=openssl_error_string()) fwrite(STDERR,$e."\n");
    exit(2);
}
$ok = openssl_open($sealed, $opened, $ekeys[0], $k);
var_dump($ok === true && $opened === $plain);
if ($ok !== true || $opened !== $plain) exit(3);
'

log "legacy PKCS#12 generation + PHP read"
LEGACY_KEY_FILE="${tmpdir}/key.pem" \
LEGACY_CERT_FILE="${tmpdir}/cert.pem" \
"$PHP_BIN" -n -d display_errors=1 -r '
function dump_errors($where) {
    fwrite(STDERR, $where." failed\n");
    while ($e=openssl_error_string()) fwrite(STDERR,$e."\n");
}
$dn = array("commonName"=>"php53-openssl35-legacy.local");
$k = openssl_pkey_new(array("private_key_bits"=>2048,"private_key_type"=>OPENSSL_KEYTYPE_RSA));
if ($k === false) { dump_errors("openssl_pkey_new"); exit(1); }
$csr = openssl_csr_new($dn, $k, array("digest_alg"=>"sha256"));
if ($csr === false) { dump_errors("openssl_csr_new"); exit(2); }
$crt = openssl_csr_sign($csr, null, $k, 1, array("digest_alg"=>"sha256"));
if ($crt === false) { dump_errors("openssl_csr_sign"); exit(3); }
if (!openssl_pkey_export_to_file($k, getenv("LEGACY_KEY_FILE"))) { dump_errors("openssl_pkey_export_to_file"); exit(4); }
if (!openssl_x509_export_to_file($crt, getenv("LEGACY_CERT_FILE"))) { dump_errors("openssl_x509_export_to_file"); exit(5); }
'

[ -s "${tmpdir}/key.pem" ] || die "legacy PKCS#12 fixture private key was not created"
[ -s "${tmpdir}/cert.pem" ] || die "legacy PKCS#12 fixture certificate was not created"

if ! "$OPENSSL_BIN" pkcs12 -export -legacy \
  -inkey "${tmpdir}/key.pem" \
  -in "${tmpdir}/cert.pem" \
  -out "${tmpdir}/legacy.p12" \
  -passout pass:test-pass; then
  die "OpenSSL CLI failed to generate legacy PKCS#12"
fi

[ -s "${tmpdir}/legacy.p12" ] || die "legacy PKCS#12 output was not created"

LEGACY_P12_FILE="${tmpdir}/legacy.p12" "$PHP_BIN" -n -r '
$p12 = file_get_contents(getenv("LEGACY_P12_FILE"));
if ($p12 === false) exit(1);
$out = array();
$ok = openssl_pkcs12_read($p12, $out, "test-pass");
var_dump($ok === true && isset($out["cert"]) && isset($out["pkey"]));
if (!$ok || !isset($out["cert"]) || !isset($out["pkey"])) {
    while ($e=openssl_error_string()) fwrite(STDERR,$e."\n");
    exit(2);
}
'

log "all PHP 5.3 / OpenSSL 3.5 legacy-provider regression probes passed"
