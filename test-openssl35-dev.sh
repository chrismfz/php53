#!/usr/bin/env bash
set -Eeuo pipefail

NGM_ROOT="${NGM_ROOT:-/opt/ngm/php}"
PHP_PREFIX="${PHP_PREFIX:-${NGM_ROOT}/5.3-openssl35-dev}"
OPENSSL_PREFIX="${OPENSSL_PREFIX:-${NGM_ROOT}/openssl-3.5}"
CURL_PREFIX="${CURL_PREFIX:-${NGM_ROOT}/curl-gnutls}"
PHP_BIN="${PHP_PREFIX}/bin/php"
FPM_BIN="${PHP_PREFIX}/sbin/php-fpm"

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

find_curl_libdir() {
  local dir
  for dir in "${CURL_PREFIX}/lib" "${CURL_PREFIX}/lib64"; do
    if compgen -G "${dir}/libcurl.so.4*" >/dev/null 2>&1; then
      printf '%s\n' "$dir"
      return 0
    fi
  done
  return 1
}

resolved_ldd_target() {
  local name="$1" line target
  line="$(ldd "$PHP_BIN" 2>/dev/null | grep -m1 -E "^[[:space:]]*${name}[[:space:]]+=>" || true)"
  [ -n "$line" ] || return 1
  target="$(printf '%s\n' "$line" | awk '{print $3}')"
  [ -n "$target" ] || return 1
  readlink -f "$target"
}

[ -x "$PHP_BIN" ] || die "PHP binary missing: ${PHP_BIN}"
[ -x "$FPM_BIN" ] || die "PHP-FPM binary missing: ${FPM_BIN}"
[ -r "${OPENSSL_PREFIX}/cert.pem" ] || die "OpenSSL CA bundle missing: ${OPENSSL_PREFIX}/cert.pem"
openssl_libdir="$(find_openssl_libdir)" || die "private OpenSSL 3 library directory not found"
curl_libdir="$(find_curl_libdir)" || die "private curl library directory not found"

log "PHP / OpenSSL versions"
"$PHP_BIN" -n -r '
echo PHP_VERSION, "\n";
echo OPENSSL_VERSION_TEXT, "\n";
if (PHP_VERSION !== "5.3.29") exit(1);
if (strpos(OPENSSL_VERSION_TEXT, "OpenSSL 3.5.") !== 0) exit(2);
'

log "private OpenSSL + curl linkage"
ssl_target="$(resolved_ldd_target 'libssl\.so\.3')" || die "libssl.so.3 not loaded"
crypto_target="$(resolved_ldd_target 'libcrypto\.so\.3')" || die "libcrypto.so.3 not loaded"
curl_target="$(resolved_ldd_target 'libcurl\.so\.4')" || die "libcurl.so.4 not loaded"
case "$ssl_target" in "${openssl_libdir}"/*) ;; *) die "libssl.so.3 resolves outside private OpenSSL: ${ssl_target}" ;; esac
case "$crypto_target" in "${openssl_libdir}"/*) ;; *) die "libcrypto.so.3 resolves outside private OpenSSL: ${crypto_target}" ;; esac
case "$curl_target" in "${curl_libdir}"/*) ;; *) die "libcurl.so.4 resolves outside private curl: ${curl_target}" ;; esac
if ldd "$PHP_BIN" 2>/dev/null | grep -Eq 'lib(ssl|crypto)\.so\.1\.1'; then
  die "PHP also loaded OpenSSL 1.1"
fi

log "curl HTTPS through private GnuTLS libcurl"
"$PHP_BIN" -n -r '
$v = curl_version();
if (strpos($v["ssl_version"], "GnuTLS/") !== 0) { fwrite(STDERR, $v["ssl_version"]."\n"); exit(1); }
$c = curl_init("https://example.com/");
curl_setopt($c, CURLOPT_RETURNTRANSFER, true);
curl_setopt($c, CURLOPT_TIMEOUT, 15);
$d = curl_exec($c);
if ($d === false) { fwrite(STDERR, curl_error($c)."\n"); curl_close($c); exit(2); }
curl_close($c);
var_dump(true);
'

log "HTTPS stream + explicit CA / peer verification"
OPENSSL_CAFILE="${OPENSSL_PREFIX}/cert.pem" "$PHP_BIN" -n -r '
$ctx = stream_context_create(array(
    "ssl" => array(
        "verify_peer" => true,
        "cafile" => getenv("OPENSSL_CAFILE"),
        "CN_match" => "example.com"
    )
));
$d = file_get_contents("https://example.com/", false, $ctx);
var_dump($d !== false);
if ($d === false) exit(1);
'

log "RSA SHA-256 sign / verify"
"$PHP_BIN" -n -r '
$k = openssl_pkey_new(array("private_key_bits"=>2048,"private_key_type"=>OPENSSL_KEYTYPE_RSA));
if ($k === false) exit(1);
if (!openssl_sign("php53-openssl35", $sig, $k, "sha256")) exit(2);
$d = openssl_pkey_get_details($k);
$pub = openssl_pkey_get_public($d["key"]);
$v = openssl_verify("php53-openssl35", $sig, $pub, "sha256");
var_dump($v === 1);
if ($v !== 1) exit(3);
'

log "RSA OAEP encrypt / decrypt"
"$PHP_BIN" -n -r '
$k = openssl_pkey_new(array("private_key_bits"=>2048,"private_key_type"=>OPENSSL_KEYTYPE_RSA));
if ($k === false) exit(1);
$d = openssl_pkey_get_details($k);
$pub = openssl_pkey_get_public($d["key"]);
$plain = "php53-openssl35-rsa";
if (!openssl_public_encrypt($plain, $enc, $pub, OPENSSL_PKCS1_OAEP_PADDING)) exit(2);
if (!openssl_private_decrypt($enc, $dec, $k, OPENSSL_PKCS1_OAEP_PADDING)) exit(3);
var_dump($dec === $plain);
if ($dec !== $plain) exit(4);
'

log "AES-256-CBC encrypt / decrypt"
"$PHP_BIN" -n -r '
$plain = "php53-openssl35-aes";
$key = hash("sha256", "test-key", true);
$iv = str_repeat("A", 16);
$enc = openssl_encrypt($plain, "aes-256-cbc", $key, true, $iv);
if ($enc === false) exit(1);
$dec = openssl_decrypt($enc, "aes-256-cbc", $key, true, $iv);
var_dump($dec === $plain);
if ($dec !== $plain) exit(2);
'

log "CSR + self-signed X509"
"$PHP_BIN" -n -r '
$dn = array("commonName"=>"php53-openssl35.local", "organizationName"=>"NGM test");
$k = openssl_pkey_new(array("private_key_bits"=>2048,"private_key_type"=>OPENSSL_KEYTYPE_RSA));
if ($k === false) exit(1);
$csr = openssl_csr_new($dn, $k, array("digest_alg"=>"sha256"));
if ($csr === false) exit(2);
$crt = openssl_csr_sign($csr, null, $k, 1, array("digest_alg"=>"sha256"));
if ($crt === false) exit(3);
if (!openssl_x509_export($crt, $pem)) exit(4);
var_dump(strpos($pem, "BEGIN CERTIFICATE") !== false);
if (strpos($pem, "BEGIN CERTIFICATE") === false) exit(5);
'

log "PKCS#12 export / read"
"$PHP_BIN" -n -r '
$dn = array("commonName"=>"php53-openssl35.local");
$k = openssl_pkey_new(array("private_key_bits"=>2048,"private_key_type"=>OPENSSL_KEYTYPE_RSA));
if ($k === false) exit(1);
$csr = openssl_csr_new($dn, $k, array("digest_alg"=>"sha256"));
if ($csr === false) exit(2);
$crt = openssl_csr_sign($csr, null, $k, 1, array("digest_alg"=>"sha256"));
if ($crt === false) exit(3);
if (!openssl_pkcs12_export($crt, $p12, $k, "test-pass")) exit(4);
$out = array();
if (!openssl_pkcs12_read($p12, $out, "test-pass")) exit(5);
var_dump(isset($out["cert"]), isset($out["pkey"]));
if (!isset($out["cert"]) || !isset($out["pkey"])) exit(6);
'

if [ -f "${PHP_PREFIX}/etc/php-fpm.conf" ]; then
  log "FPM configuration"
  "$FPM_BIN" -t
else
  die "active php-fpm.conf missing: ${PHP_PREFIX}/etc/php-fpm.conf"
fi

log "all PHP 5.3 / OpenSSL 3.5 runtime regression probes passed"
