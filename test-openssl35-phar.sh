#!/usr/bin/env bash
set -Eeuo pipefail

NGM_ROOT="${NGM_ROOT:-/opt/ngm/php}"
PHP_PREFIX="${PHP_PREFIX:-${NGM_ROOT}/5.3-openssl35-candidate}"
PHP_BIN="${PHP_PREFIX}/bin/php"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

[ -x "$PHP_BIN" ] || die "PHP binary missing: ${PHP_BIN}"

tmpdir="$(mktemp -d /tmp/php53-openssl35-phar.XXXXXX)"
trap 'rm -rf "$tmpdir"' EXIT

log "OpenSSL-signed PHAR create / verify"

"$PHP_BIN" -n -d phar.readonly=0 -r '
$dir = $argv[1];
$pharPath = $dir . "/signed.phar";

$key = openssl_pkey_new(array("private_key_bits" => 2048, "private_key_type" => OPENSSL_KEYTYPE_RSA));
if ($key === false) {
    fwrite(STDERR, "openssl_pkey_new failed\n");
    exit(1);
}

$privatePem = "";
if (!openssl_pkey_export($key, $privatePem)) {
    fwrite(STDERR, "openssl_pkey_export failed\n");
    exit(2);
}

$details = openssl_pkey_get_details($key);
if (!is_array($details) || empty($details["key"])) {
    fwrite(STDERR, "openssl_pkey_get_details failed\n");
    exit(3);
}
$publicPem = $details["key"];

$p = new Phar($pharPath);
$p->startBuffering();
$p["payload.txt"] = "php53-openssl35-phar-ok";
$p->setStub("<?php __HALT_COMPILER(); ?>");
$p->setSignatureAlgorithm(Phar::OPENSSL, $privatePem);
$p->stopBuffering();
unset($p);

if (file_put_contents($pharPath . ".pubkey", $publicPem) === false) {
    fwrite(STDERR, "could not write PHAR public key\n");
    exit(4);
}

/* Re-opening forces the PHAR parser through OpenSSL signature verification. */
$p = new Phar($pharPath);
$sig = $p->getSignature();
if (!is_array($sig) || !isset($sig["hash_type"]) || $sig["hash_type"] !== "OpenSSL") {
    fwrite(STDERR, "unexpected PHAR signature metadata\n");
    exit(5);
}

$data = file_get_contents("phar://" . $pharPath . "/payload.txt");
var_dump($data === "php53-openssl35-phar-ok");
if ($data !== "php53-openssl35-phar-ok") {
    exit(6);
}
' "$tmpdir"

log "OpenSSL-signed PHAR tamper rejection"

# Corrupt one byte in a copy while retaining the original public key. Opening
# the copy must fail signature verification instead of silently accepting it.
cp "$tmpdir/signed.phar" "$tmpdir/tampered.phar"
cp "$tmpdir/signed.phar.pubkey" "$tmpdir/tampered.phar.pubkey"
printf 'X' | dd of="$tmpdir/tampered.phar" bs=1 seek=32 count=1 conv=notrunc status=none

set +e
"$PHP_BIN" -n -r '
try {
    $p = new Phar($argv[1]);
    file_get_contents("phar://" . $argv[1] . "/payload.txt");
    exit(0);
} catch (Exception $e) {
    fwrite(STDERR, $e->getMessage() . "\n");
    exit(7);
}
' "$tmpdir/tampered.phar" >/dev/null 2>&1
rc=$?
set -e

# A successful open (0) means signature verification did not reject tampering.
[ "$rc" -ne 0 ] || die "tampered OpenSSL-signed PHAR was accepted."

log "PHP 5.3 PHAR OpenSSL signature regression probe passed"
