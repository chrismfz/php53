#!/usr/bin/env python3
# Second staged PHP 5.3 -> OpenSSL 1.1 compatibility transform.

from __future__ import print_function

import os
import sys
from pathlib import Path


def die(message):
    raise SystemExit("OpenSSL 1.1 compat stage 2: " + message)


def once(text, old, new, label):
    if new in text:
        return text
    count = text.count(old)
    if count != 1:
        die("expected one %s pattern, found %d" % (label, count))
    return text.replace(old, new, 1)


def exact(text, old, new, count, label):
    found = text.count(old)
    if found == 0 and text.count(new) >= count:
        return text
    if found != count:
        die("expected %d %s patterns, found %d" % (count, label, found))
    return text.replace(old, new)


src = Path(sys.argv[1] if len(sys.argv) > 1 else os.environ.get(
    "SRC_DIR", "/usr/local/src/ngm-php-build/php-5.3.29"
))
openssl_path = src / "ext" / "openssl" / "openssl.c"
xp_path = src / "ext" / "openssl" / "xp_ssl.c"

text = openssl_path.read_text(encoding="utf-8")
original = text

text = once(
    text,
    '''\tif (file == NULL) {
\t\tfile = RAND_file_name(buffer, sizeof(buffer));
\t} else if (RAND_egd(file) > 0) {
\t\t/* if the given filename is an EGD socket, don't
\t\t * write anything back to it */
\t\t*egdsocket = 1;
\t\treturn SUCCESS;
\t}''',
    '''\tif (file == NULL) {
\t\tfile = RAND_file_name(buffer, sizeof(buffer));
#ifdef HAVE_RAND_EGD
\t} else if (RAND_egd(file) > 0) {
\t\t/* if the given filename is an EGD socket, don't
\t\t * write anything back to it */
\t\t*egdsocket = 1;
\t\treturn SUCCESS;
#endif
\t}''',
    "RAND_egd guard",
)
text = text.replace("(EVP_MD *) EVP_dss1()", "(EVP_MD *) EVP_sha1()")

text = exact(text, "\tEVP_MD_CTX md_ctx;", "\tEVP_MD_CTX *md_ctx = NULL;", 2, "EVP_MD_CTX declaration")
text = once(text, "\tEVP_MD_CTX     md_ctx;", "\tEVP_MD_CTX *md_ctx = NULL;", "EVP verify context declaration")
text = exact(text, "&md_ctx", "md_ctx", 11, "EVP_MD_CTX address")
text = exact(text, "EVP_MD_CTX_cleanup(md_ctx);", "EVP_MD_CTX_destroy(md_ctx);", 2, "EVP_MD_CTX cleanup")

text = once(
    text,
    '''\tsigbuf = emalloc(siglen + 1);

\tEVP_SignInit(md_ctx, mdtype);''',
    '''\tsigbuf = emalloc(siglen + 1);
\tmd_ctx = EVP_MD_CTX_create();
\tif (md_ctx == NULL) {
\t\tefree(sigbuf);
\t\tif (keyresource == -1) {
\t\t\tEVP_PKEY_free(pkey);
\t\t}
\t\tRETURN_FALSE;
\t}

\tEVP_SignInit(md_ctx, mdtype);''',
    "sign context allocation",
)
text = once(
    text,
    '''\tEVP_VerifyInit   (md_ctx, mdtype);''',
    '''\tmd_ctx = EVP_MD_CTX_create();
\tif (md_ctx == NULL) {
\t\tif (keyresource == -1) {
\t\t\tEVP_PKEY_free(pkey);
\t\t}
\t\tRETURN_FALSE;
\t}
\tEVP_VerifyInit   (md_ctx, mdtype);''',
    "verify context allocation",
)
text = once(
    text,
    '''\tsigbuf = emalloc(siglen + 1);

\tEVP_DigestInit(md_ctx, mdtype);''',
    '''\tsigbuf = emalloc(siglen + 1);
\tmd_ctx = EVP_MD_CTX_create();
\tif (md_ctx == NULL) {
\t\tefree(sigbuf);
\t\tRETURN_FALSE;
\t}

\tEVP_DigestInit(md_ctx, mdtype);''',
    "digest context allocation",
)
text = once(
    text,
    '''\t} else {
\t\tefree(sigbuf);
\t\tRETVAL_FALSE;
\t}
}
/* }}} */

static zend_bool php_openssl_validate_iv''',
    '''\t} else {
\t\tefree(sigbuf);
\t\tRETVAL_FALSE;
\t}
\tEVP_MD_CTX_destroy(md_ctx);
}
/* }}} */

static zend_bool php_openssl_validate_iv''',
    "digest context free",
)

text = exact(text, "\tEVP_CIPHER_CTX ctx;", "\tEVP_CIPHER_CTX *ctx = NULL;", 2, "EVP_CIPHER_CTX ctx declaration")
text = exact(text, "\tEVP_CIPHER_CTX cipher_ctx;", "\tEVP_CIPHER_CTX *cipher_ctx = NULL;", 2, "EVP_CIPHER_CTX cipher declaration")
text = exact(text, "&ctx", "ctx", 9, "EVP_CIPHER_CTX ctx address")
text = exact(text, "&cipher_ctx", "cipher_ctx", 12, "EVP_CIPHER_CTX cipher address")

text = once(
    text,
    '''\tif (!EVP_EncryptInit(ctx,cipher,NULL,NULL)) {''',
    '''\tctx = EVP_CIPHER_CTX_new();
\tif (ctx == NULL || !EVP_EncryptInit(ctx,cipher,NULL,NULL)) {''',
    "seal context allocation",
)
text = once(
    text,
    '''clean_exit:
\tfor (i=0; i<nkeys; i++) {''',
    '''clean_exit:
\tEVP_CIPHER_CTX_free(ctx);
\tfor (i=0; i<nkeys; i++) {''',
    "seal context free",
)
text = once(
    text,
    '''\tbuf = emalloc(data_len + 1);

\tif (EVP_OpenInit(ctx, cipher,''',
    '''\tbuf = emalloc(data_len + 1);
\tctx = EVP_CIPHER_CTX_new();

\tif (ctx != NULL && EVP_OpenInit(ctx, cipher,''',
    "open context allocation",
)
text = exact(
    text,
    '''\t\tefree(buf);
\t\tif (keyresource == -1) {''',
    '''\t\tefree(buf);
\t\tEVP_CIPHER_CTX_free(ctx);
\t\tif (keyresource == -1) {''',
    2,
    "open failure context free",
)
text = once(
    text,
    '''\tif (keyresource == -1) {
\t\tEVP_PKEY_free(pkey);
\t}
\tzval_dtor(opendata);''',
    '''\tEVP_CIPHER_CTX_free(ctx);
\tif (keyresource == -1) {
\t\tEVP_PKEY_free(pkey);
\t}
\tzval_dtor(opendata);''',
    "open success context free",
)

text = exact(
    text,
    '''\tkeylen = EVP_CIPHER_key_length(cipher_type);''',
    '''\tcipher_ctx = EVP_CIPHER_CTX_new();
\tif (cipher_ctx == NULL) {
\t\tphp_error_docref(NULL TSRMLS_CC, E_WARNING, "Failed to create cipher context");
\t\tRETURN_FALSE;
\t}

\tkeylen = EVP_CIPHER_key_length(cipher_type);''',
    2,
    "encrypt/decrypt context allocation",
)
text = exact(
    text,
    "EVP_CIPHER_CTX_cleanup(cipher_ctx);",
    "EVP_CIPHER_CTX_free(cipher_ctx);",
    2,
    "encrypt/decrypt context free",
)

text = once(
    text,
    '''\tEVP_PKEY *pkey;
\tBIGNUM *pub;''',
    '''\tEVP_PKEY *pkey;
\tDH *dh;
\tBIGNUM *pub;''',
    "DH declaration",
)
text = once(
    text,
    '''\tif (!pkey || EVP_PKEY_type(pkey->type) != EVP_PKEY_DH || !pkey->pkey.dh) {
\t\tRETURN_FALSE;
\t}

\tpub = BN_bin2bn((unsigned char*)pub_str, pub_len, NULL);

\tdata = emalloc(DH_size(pkey->pkey.dh) + 1);
\tlen = DH_compute_key((unsigned char*)data, pub, pkey->pkey.dh);''',
    '''\tif (!pkey || EVP_PKEY_base_id(pkey) != EVP_PKEY_DH) {
\t\tRETURN_FALSE;
\t}
\tdh = (DH *)EVP_PKEY_get0_DH(pkey);
\tif (!dh) {
\t\tRETURN_FALSE;
\t}

\tpub = BN_bin2bn((unsigned char*)pub_str, pub_len, NULL);
\tif (!pub) {
\t\tRETURN_FALSE;
\t}

\tdata = emalloc(DH_size(dh) + 1);
\tlen = DH_compute_key((unsigned char*)data, pub, dh);''',
    "DH accessor",
)

if text == original:
    die("no openssl.c changes applied")
openssl_path.write_text(text, encoding="utf-8")

xp = xp_path.read_text(encoding="utf-8")
xp_original = xp
xp = once(xp, "\tSSL_METHOD *method;", "\tconst SSL_METHOD *method;", "const SSL_METHOD")
xp = once(
    xp,
    '''\t\tcase STREAM_CRYPTO_METHOD_SSLv2_CLIENT:
#ifdef OPENSSL_NO_SSL2
\t\t\tphp_error_docref(NULL TSRMLS_CC, E_WARNING, "SSLv2 support is not compiled into the OpenSSL library PHP is linked against");
\t\t\treturn -1;
#else
\t\t\tsslsock->is_client = 1;
\t\t\tmethod = SSLv2_client_method();
\t\t\tbreak;
#endif''',
    '''\t\tcase STREAM_CRYPTO_METHOD_SSLv2_CLIENT:
\t\t\tphp_error_docref(NULL TSRMLS_CC, E_WARNING, "SSLv2 support is not compiled into the OpenSSL library PHP is linked against");
\t\t\treturn -1;''',
    "SSLv2 client",
)
xp = once(
    xp,
    '''\t\tcase STREAM_CRYPTO_METHOD_SSLv3_CLIENT:
\t\t\tsslsock->is_client = 1;
\t\t\tmethod = SSLv3_client_method();
\t\t\tbreak;''',
    '''\t\tcase STREAM_CRYPTO_METHOD_SSLv3_CLIENT:
#ifdef OPENSSL_NO_SSL3
\t\t\tphp_error_docref(NULL TSRMLS_CC, E_WARNING, "SSLv3 support is not compiled into the OpenSSL library PHP is linked against");
\t\t\treturn -1;
#else
\t\t\tsslsock->is_client = 1;
\t\t\tmethod = SSLv3_client_method();
\t\t\tbreak;
#endif''',
    "SSLv3 client",
)
xp = once(
    xp,
    '''\t\tcase STREAM_CRYPTO_METHOD_SSLv3_SERVER:
\t\t\tsslsock->is_client = 0;
\t\t\tmethod = SSLv3_server_method();
\t\t\tbreak;''',
    '''\t\tcase STREAM_CRYPTO_METHOD_SSLv3_SERVER:
#ifdef OPENSSL_NO_SSL3
\t\t\tphp_error_docref(NULL TSRMLS_CC, E_WARNING, "SSLv3 support is not compiled into the OpenSSL library PHP is linked against");
\t\t\treturn -1;
#else
\t\t\tsslsock->is_client = 0;
\t\t\tmethod = SSLv3_server_method();
\t\t\tbreak;
#endif''',
    "SSLv3 server",
)
xp = once(
    xp,
    '''\t\tcase STREAM_CRYPTO_METHOD_SSLv2_SERVER:
#ifdef OPENSSL_NO_SSL2
\t\t\tphp_error_docref(NULL TSRMLS_CC, E_WARNING, "SSLv2 support is not compiled into the OpenSSL library PHP is linked against");
\t\t\treturn -1;
#else
\t\t\tsslsock->is_client = 0;
\t\t\tmethod = SSLv2_server_method();
\t\t\tbreak;
#endif''',
    '''\t\tcase STREAM_CRYPTO_METHOD_SSLv2_SERVER:
\t\t\tphp_error_docref(NULL TSRMLS_CC, E_WARNING, "SSLv2 support is not compiled into the OpenSSL library PHP is linked against");
\t\t\treturn -1;''',
    "SSLv2 server",
)
if xp == xp_original:
    die("no xp_ssl.c changes applied")
xp_path.write_text(xp, encoding="utf-8")

print("Applied OpenSSL 1.1 compatibility stage 2 to %s" % src)
