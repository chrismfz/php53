#!/usr/bin/env python3
"""Apply the staged PHP 5.6 OpenSSL 1.1 compatibility backport to PHP 5.3.

This is intentionally a deterministic source transformer while the port is
being developed.  It runs against the disposable build checkout, never against
the operator's working tree.  Once the port is stable, the resulting source
changes can be folded into ext/openssl directly and this helper removed.
"""

from __future__ import print_function

import os
import sys
from pathlib import Path


def die(message):
    raise SystemExit("OpenSSL 1.1 compat transform: " + message)


def replace_once(text, old, new, label):
    if new in text:
        return text
    count = text.count(old)
    if count != 1:
        die("expected exactly one %s block, found %d" % (label, count))
    return text.replace(old, new, 1)


def replace_between(text, start, end, replacement, label):
    start_pos = text.find(start)
    if start_pos < 0:
        if replacement in text:
            return text
        die("start marker not found for %s" % label)
    end_pos = text.find(end, start_pos)
    if end_pos < 0:
        die("end marker not found for %s" % label)
    return text[:start_pos] + replacement.rstrip() + "\n\n" + text[end_pos:]


src_dir = Path(sys.argv[1] if len(sys.argv) > 1 else os.environ.get(
    "SRC_DIR", "/usr/local/src/ngm-php-build/php-5.3.29"
))
openssl_c = src_dir / "ext" / "openssl" / "openssl.c"

if not openssl_c.is_file():
    die("source file not found: %s" % openssl_c)

text = openssl_c.read_text(encoding="utf-8")
original = text

# X509_EXTENSION and X509 became opaque in OpenSSL 1.1.
text = replace_once(
    text,
    "\tGENERAL_NAMES *names;\n\tconst X509V3_EXT_METHOD *method = NULL;\n\tlong i, length, num;",
    "\tGENERAL_NAMES *names;\n\tconst X509V3_EXT_METHOD *method = NULL;\n\tASN1_OCTET_STRING *extension_data;\n\tlong i, length, num;",
    "subjectAltName declarations",
)
text = replace_once(
    text,
    "\tp = extension->value->data;\n\tlength = extension->value->length;",
    "\textension_data = X509_EXTENSION_get_data(extension);\n\tp = extension_data->data;\n\tlength = extension_data->length;",
    "subjectAltName extension data",
)
text = replace_once(
    text,
    "\tX509_EXTENSION *extension;\n\tchar *extname;",
    "\tX509_EXTENSION *extension;\n\tX509_NAME *subject_name;\n\tchar *cert_name;\n\tchar *extname;",
    "X509 parse declarations",
)
text = replace_once(
    text,
    "\tif (cert->name) {\n\t\tadd_assoc_string(return_value, \"name\", cert->name, 1);\n\t}\n/*\tadd_assoc_bool(return_value, \"valid\", cert->valid); */\n\n\tadd_assoc_name_entry(return_value, \"subject\", \t\tX509_get_subject_name(cert), useshortnames TSRMLS_CC);",
    "\tsubject_name = X509_get_subject_name(cert);\n\tcert_name = X509_NAME_oneline(subject_name, NULL, 0);\n\tif (cert_name) {\n\t\tadd_assoc_string(return_value, \"name\", cert_name, 1);\n\t\tOPENSSL_free(cert_name);\n\t}\n/*\tadd_assoc_bool(return_value, \"valid\", cert->valid); */\n\n\tadd_assoc_name_entry(return_value, \"subject\", \t\tsubject_name, useshortnames TSRMLS_CC);",
    "X509 parse certificate name",
)

# EVP_PKEY, RSA, DSA and DH structures became opaque.  This block is adapted
# from chrismfz/php56 commit 5ea00691370359e015402a70eae5d73cf92f6074,
# while retaining PHP 5.3's Zend resource API.
pkey_block = r'''/* {{{ php_openssl_is_private_key
	Check whether the supplied key is a private key by checking if the secret prime factors are set */
static int php_openssl_is_private_key(EVP_PKEY* pkey TSRMLS_DC)
{
	assert(pkey != NULL);

	switch (EVP_PKEY_id(pkey)) {
#ifndef NO_RSA
		case EVP_PKEY_RSA:
		case EVP_PKEY_RSA2:
		{
			const RSA *rsa = EVP_PKEY_get0_RSA(pkey);
			const BIGNUM *p = NULL, *q = NULL;
			if (rsa == NULL) {
				return 0;
			}
			RSA_get0_factors(rsa, &p, &q);
			if (p == NULL || q == NULL) {
				return 0;
			}
			break;
		}
#endif
#ifndef NO_DSA
		case EVP_PKEY_DSA:
		case EVP_PKEY_DSA1:
		case EVP_PKEY_DSA2:
		case EVP_PKEY_DSA3:
		case EVP_PKEY_DSA4:
		{
			const DSA *dsa = EVP_PKEY_get0_DSA(pkey);
			const BIGNUM *p = NULL, *q = NULL, *g = NULL;
			const BIGNUM *pub_key = NULL, *priv_key = NULL;
			if (dsa == NULL) {
				return 0;
			}
			DSA_get0_pqg(dsa, &p, &q, &g);
			DSA_get0_key(dsa, &pub_key, &priv_key);
			if (p == NULL || q == NULL || priv_key == NULL) {
				return 0;
			}
			break;
		}
#endif
#ifndef NO_DH
		case EVP_PKEY_DH:
		{
			const DH *dh = EVP_PKEY_get0_DH(pkey);
			const BIGNUM *p = NULL, *q = NULL, *g = NULL;
			const BIGNUM *pub_key = NULL, *priv_key = NULL;
			if (dh == NULL) {
				return 0;
			}
			DH_get0_pqg(dh, &p, &q, &g);
			DH_get0_key(dh, &pub_key, &priv_key);
			if (p == NULL || priv_key == NULL) {
				return 0;
			}
			break;
		}
#endif
#ifdef EVP_PKEY_EC
		case EVP_PKEY_EC:
		{
			const EC_KEY *ec = EVP_PKEY_get0_EC_KEY(pkey);
			if (ec == NULL || EC_KEY_get0_private_key(ec) == NULL) {
				return 0;
			}
			break;
		}
#endif
		default:
			php_error_docref(NULL TSRMLS_CC, E_WARNING, "key type not supported in this PHP build!");
			break;
	}
	return 1;
}
/* }}} */

#define OPENSSL_GET_BN(_array, _bn, _name) do {                              \
		if ((_bn) != NULL) {                                                     \
			int len = BN_num_bytes((_bn));                                         \
			char *str = emalloc(len + 1);                                          \
			BN_bn2bin((_bn), (unsigned char*)str);                                 \
			str[len] = 0;                                                          \
			add_assoc_stringl((_array), #_name, str, len, 0);                      \
		}                                                                        \
	} while (0)

#define OPENSSL_PKEY_GET_BN(_array, _name) OPENSSL_GET_BN((_array), (_name), _name)

#define OPENSSL_PKEY_SET_BN(_data, _name) do {                               \
		zval **bn;                                                               \
		if (zend_hash_find(Z_ARRVAL_P((_data)), #_name, sizeof(#_name),          \
				(void**)&bn) == SUCCESS && Z_TYPE_PP(bn) == IS_STRING) {             \
			(_name) = BN_bin2bn((unsigned char*)Z_STRVAL_PP(bn),                  \
				Z_STRLEN_PP(bn), NULL);                                              \
		} else {                                                                 \
			(_name) = NULL;                                                       \
		}                                                                        \
	} while (0)

static int php_openssl_pkey_init_and_assign_rsa(EVP_PKEY *pkey, RSA *rsa, zval *data)
{
	BIGNUM *n, *e, *d, *p, *q, *dmp1, *dmq1, *iqmp;

	OPENSSL_PKEY_SET_BN(data, n);
	OPENSSL_PKEY_SET_BN(data, e);
	OPENSSL_PKEY_SET_BN(data, d);
	if (!n || !d || !RSA_set0_key(rsa, n, e, d)) {
		return 0;
	}

	OPENSSL_PKEY_SET_BN(data, p);
	OPENSSL_PKEY_SET_BN(data, q);
	if ((p || q) && !RSA_set0_factors(rsa, p, q)) {
		return 0;
	}

	OPENSSL_PKEY_SET_BN(data, dmp1);
	OPENSSL_PKEY_SET_BN(data, dmq1);
	OPENSSL_PKEY_SET_BN(data, iqmp);
	if ((dmp1 || dmq1 || iqmp) && !RSA_set0_crt_params(rsa, dmp1, dmq1, iqmp)) {
		return 0;
	}

	return EVP_PKEY_assign_RSA(pkey, rsa);
}

static int php_openssl_pkey_init_dsa(DSA *dsa, zval *data)
{
	BIGNUM *p, *q, *g, *priv_key, *pub_key;
	const BIGNUM *pub_key_check = NULL, *priv_key_check = NULL;

	OPENSSL_PKEY_SET_BN(data, p);
	OPENSSL_PKEY_SET_BN(data, q);
	OPENSSL_PKEY_SET_BN(data, g);
	if (!p || !q || !g || !DSA_set0_pqg(dsa, p, q, g)) {
		return 0;
	}

	OPENSSL_PKEY_SET_BN(data, pub_key);
	OPENSSL_PKEY_SET_BN(data, priv_key);
	if (pub_key) {
		return DSA_set0_key(dsa, pub_key, priv_key);
	}

	if (!DSA_generate_key(dsa)) {
		return 0;
	}
	DSA_get0_key(dsa, &pub_key_check, &priv_key_check);
	return pub_key_check != NULL && !BN_is_zero(pub_key_check);
}

static BIGNUM *php_openssl_dh_pub_from_priv(BIGNUM *priv_key, BIGNUM *g, BIGNUM *p)
{
	BIGNUM *pub_key = NULL, *priv_key_const_time = NULL;
	BN_CTX *ctx = NULL;

	pub_key = BN_new();
	priv_key_const_time = BN_new();
	ctx = BN_CTX_new();
	if (!pub_key || !priv_key_const_time || !ctx) {
		BN_free(pub_key);
		BN_free(priv_key_const_time);
		BN_CTX_free(ctx);
		return NULL;
	}
	BN_with_flags(priv_key_const_time, priv_key, BN_FLG_CONSTTIME);
	if (!BN_mod_exp_mont(pub_key, g, priv_key_const_time, p, ctx, NULL)) {
		BN_free(pub_key);
		pub_key = NULL;
	}
	BN_free(priv_key_const_time);
	BN_CTX_free(ctx);
	return pub_key;
}

static int php_openssl_pkey_init_dh(DH *dh, zval *data)
{
	BIGNUM *p, *q, *g, *priv_key, *pub_key;

	OPENSSL_PKEY_SET_BN(data, p);
	OPENSSL_PKEY_SET_BN(data, q);
	OPENSSL_PKEY_SET_BN(data, g);
	if (!p || !g || !DH_set0_pqg(dh, p, q, g)) {
		return 0;
	}

	OPENSSL_PKEY_SET_BN(data, priv_key);
	OPENSSL_PKEY_SET_BN(data, pub_key);
	if (pub_key) {
		return DH_set0_key(dh, pub_key, priv_key);
	}
	if (priv_key) {
		pub_key = php_openssl_dh_pub_from_priv(priv_key, g, p);
		if (!pub_key) {
			return 0;
		}
		return DH_set0_key(dh, pub_key, priv_key);
	}
	return DH_generate_key(dh);
}

/* {{{ proto resource openssl_pkey_new([array configargs])
   Generates a new private key */
PHP_FUNCTION(openssl_pkey_new)
{
	struct php_x509_request req;
	zval * args = NULL;
	zval **data;

	if (zend_parse_parameters(ZEND_NUM_ARGS() TSRMLS_CC, "|a!", &args) == FAILURE) {
		return;
	}
	RETVAL_FALSE;

	if (args && Z_TYPE_P(args) == IS_ARRAY) {
		EVP_PKEY *pkey;

		if (zend_hash_find(Z_ARRVAL_P(args), "rsa", sizeof("rsa"), (void**)&data) == SUCCESS &&
		    Z_TYPE_PP(data) == IS_ARRAY) {
			pkey = EVP_PKEY_new();
			if (pkey) {
				RSA *rsa = RSA_new();
				if (rsa && php_openssl_pkey_init_and_assign_rsa(pkey, rsa, *data)) {
					RETURN_RESOURCE(zend_list_insert(pkey, le_key));
				}
				RSA_free(rsa);
				EVP_PKEY_free(pkey);
			}
			RETURN_FALSE;
		} else if (zend_hash_find(Z_ARRVAL_P(args), "dsa", sizeof("dsa"), (void**)&data) == SUCCESS &&
		           Z_TYPE_PP(data) == IS_ARRAY) {
			pkey = EVP_PKEY_new();
			if (pkey) {
				DSA *dsa = DSA_new();
				if (dsa && php_openssl_pkey_init_dsa(dsa, *data) && EVP_PKEY_assign_DSA(pkey, dsa)) {
					RETURN_RESOURCE(zend_list_insert(pkey, le_key));
				}
				DSA_free(dsa);
				EVP_PKEY_free(pkey);
			}
			RETURN_FALSE;
		} else if (zend_hash_find(Z_ARRVAL_P(args), "dh", sizeof("dh"), (void**)&data) == SUCCESS &&
		           Z_TYPE_PP(data) == IS_ARRAY) {
			pkey = EVP_PKEY_new();
			if (pkey) {
				DH *dh = DH_new();
				if (dh && php_openssl_pkey_init_dh(dh, *data) && EVP_PKEY_assign_DH(pkey, dh)) {
					RETURN_RESOURCE(zend_list_insert(pkey, le_key));
				}
				DH_free(dh);
				EVP_PKEY_free(pkey);
			}
			RETURN_FALSE;
		}
	}

	PHP_SSL_REQ_INIT(&req);
	if (PHP_SSL_REQ_PARSE(&req, args) == SUCCESS) {
		if (php_openssl_generate_private_key(&req TSRMLS_CC)) {
			RETVAL_RESOURCE(zend_list_insert(req.priv_key, le_key));
			req.priv_key = NULL;
		}
	}
	PHP_SSL_REQ_DISPOSE(&req);
}
/* }}} */'''

text = replace_between(
    text,
    "/* {{{ php_openssl_is_private_key",
    "/* {{{ proto bool openssl_pkey_export_to_file",
    pkey_block,
    "EVP_PKEY private-key and constructor block",
)

# pkey details: use public accessor APIs for all BIGNUM components.
pkey_details = r'''/* {{{ proto resource openssl_pkey_get_details(resource key)
	returns an array with the key details (bits, pkey, type)*/
PHP_FUNCTION(openssl_pkey_get_details)
{
	zval *key;
	EVP_PKEY *pkey;
	BIO *out;
	unsigned int pbio_len;
	char *pbio;
	long ktype;

	if (zend_parse_parameters(ZEND_NUM_ARGS() TSRMLS_CC, "r", &key) == FAILURE) {
		return;
	}
	ZEND_FETCH_RESOURCE(pkey, EVP_PKEY *, &key, -1, "OpenSSL key", le_key);
	if (!pkey) {
		RETURN_FALSE;
	}
	out = BIO_new(BIO_s_mem());
	PEM_write_bio_PUBKEY(out, pkey);
	pbio_len = BIO_get_mem_data(out, &pbio);

	array_init(return_value);
	add_assoc_long(return_value, "bits", EVP_PKEY_bits(pkey));
	add_assoc_stringl(return_value, "key", pbio, pbio_len, 1);

	switch (EVP_PKEY_base_id(pkey)) {
		case EVP_PKEY_RSA:
		case EVP_PKEY_RSA2:
		{
			const RSA *rsa = EVP_PKEY_get0_RSA(pkey);
			ktype = OPENSSL_KEYTYPE_RSA;
			if (rsa) {
				zval *z_rsa;
				const BIGNUM *n = NULL, *e = NULL, *d = NULL;
				const BIGNUM *p = NULL, *q = NULL;
				const BIGNUM *dmp1 = NULL, *dmq1 = NULL, *iqmp = NULL;
				RSA_get0_key(rsa, &n, &e, &d);
				RSA_get0_factors(rsa, &p, &q);
				RSA_get0_crt_params(rsa, &dmp1, &dmq1, &iqmp);
				ALLOC_INIT_ZVAL(z_rsa);
				array_init(z_rsa);
				OPENSSL_PKEY_GET_BN(z_rsa, n);
				OPENSSL_PKEY_GET_BN(z_rsa, e);
				OPENSSL_PKEY_GET_BN(z_rsa, d);
				OPENSSL_PKEY_GET_BN(z_rsa, p);
				OPENSSL_PKEY_GET_BN(z_rsa, q);
				OPENSSL_PKEY_GET_BN(z_rsa, dmp1);
				OPENSSL_PKEY_GET_BN(z_rsa, dmq1);
				OPENSSL_PKEY_GET_BN(z_rsa, iqmp);
				add_assoc_zval(return_value, "rsa", z_rsa);
			}
			break;
		}
		case EVP_PKEY_DSA:
		case EVP_PKEY_DSA1:
		case EVP_PKEY_DSA2:
		case EVP_PKEY_DSA3:
		case EVP_PKEY_DSA4:
		{
			const DSA *dsa = EVP_PKEY_get0_DSA(pkey);
			ktype = OPENSSL_KEYTYPE_DSA;
			if (dsa) {
				zval *z_dsa;
				const BIGNUM *p = NULL, *q = NULL, *g = NULL;
				const BIGNUM *priv_key = NULL, *pub_key = NULL;
				DSA_get0_pqg(dsa, &p, &q, &g);
				DSA_get0_key(dsa, &pub_key, &priv_key);
				ALLOC_INIT_ZVAL(z_dsa);
				array_init(z_dsa);
				OPENSSL_PKEY_GET_BN(z_dsa, p);
				OPENSSL_PKEY_GET_BN(z_dsa, q);
				OPENSSL_PKEY_GET_BN(z_dsa, g);
				OPENSSL_PKEY_GET_BN(z_dsa, priv_key);
				OPENSSL_PKEY_GET_BN(z_dsa, pub_key);
				add_assoc_zval(return_value, "dsa", z_dsa);
			}
			break;
		}
		case EVP_PKEY_DH:
		{
			const DH *dh = EVP_PKEY_get0_DH(pkey);
			ktype = OPENSSL_KEYTYPE_DH;
			if (dh) {
				zval *z_dh;
				const BIGNUM *p = NULL, *q = NULL, *g = NULL;
				const BIGNUM *priv_key = NULL, *pub_key = NULL;
				DH_get0_pqg(dh, &p, &q, &g);
				DH_get0_key(dh, &pub_key, &priv_key);
				ALLOC_INIT_ZVAL(z_dh);
				array_init(z_dh);
				OPENSSL_PKEY_GET_BN(z_dh, p);
				OPENSSL_PKEY_GET_BN(z_dh, g);
				OPENSSL_PKEY_GET_BN(z_dh, priv_key);
				OPENSSL_PKEY_GET_BN(z_dh, pub_key);
				add_assoc_zval(return_value, "dh", z_dh);
			}
			break;
		}
#ifdef EVP_PKEY_EC
		case EVP_PKEY_EC:
			ktype = OPENSSL_KEYTYPE_EC;
			break;
#endif
		default:
			ktype = -1;
			break;
	}
	add_assoc_long(return_value, "type", ktype);
	BIO_free(out);
}
/* }}} */'''

text = replace_between(
    text,
    "/* {{{ proto resource openssl_pkey_get_details",
    "/* {{{ PKCS7 S/MIME functions */",
    pkey_details + "\n\n/* }}} */",
    "EVP_PKEY details block",
)

# RSA encrypt/decrypt helpers only read the RSA object, so the accessor is a
# direct replacement.  The cast matches the historical low-level RSA API.
text = text.replace("switch (pkey->type) {", "switch (EVP_PKEY_id(pkey)) {")
text = text.replace("pkey->pkey.rsa,", "(RSA *)EVP_PKEY_get0_RSA(pkey),")
text = text.replace("EVP_PKEY_type(key->type)", "EVP_PKEY_base_id(key)")

if text == original:
    print("OpenSSL 1.1 compatibility transform already applied")
else:
    openssl_c.write_text(text, encoding="utf-8")
    print("Applied staged OpenSSL 1.1 compatibility transforms to %s" % openssl_c)
