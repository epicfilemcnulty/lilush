// SPDX-FileCopyrightText: © 2024 Vladimir Zorin <vladimir@deviant.guru>
// SPDX-License-Identifier: GPL-3.0-or-later
#include <string.h>

#include <wolfssl/options.h>
#include <wolfssl/ssl.h>
#include <wolfssl/wolfcrypt/asn.h>
#include <wolfssl/wolfcrypt/coding.h>
#include <wolfssl/wolfcrypt/ecc.h>
#include <wolfssl/wolfcrypt/ed25519.h>
#include <wolfssl/wolfcrypt/error-crypt.h>
#include <wolfssl/wolfcrypt/hash.h>
#include <wolfssl/wolfcrypt/hmac.h>
#include <wolfssl/wolfcrypt/settings.h>
#include <wolfssl/wolfcrypt/sha256.h>
#include <wolfssl/wolfcrypt/signature.h>

#include <lauxlib.h>
#include <lua.h>

#define RETURN_CUSTOM_ERR(L, msg) \
    do {                          \
        lua_pushnil(L);           \
        lua_pushstring(L, msg);   \
        return 2;                 \
    } while (0)

int lua_base64_decode(lua_State *L) {
    size_t inLen;
    const char *in = lua_tolstring(L, 1, &inLen);
    word32 outLen  = inLen * 3 / 4; // Approximate output length
    byte *out      = (byte *)malloc(outLen);
    if (out == NULL) {
        RETURN_CUSTOM_ERR(L, "memory allocation failed");
    }
    int ret = Base64_Decode((byte *)in, inLen, out, &outLen);
    if (ret != 0) {
        free(out);
        RETURN_CUSTOM_ERR(L, "failed to decode base64");
    }
    lua_pushlstring(L, (char *)out, outLen);
    free(out);
    return 1;
}

int lua_base64_encode(lua_State *L) {
    size_t inLen;
    const char *in = lua_tolstring(L, 1, &inLen);
    word32 outLen  = (inLen / 3) * 4 + 128;      // Conservative output length
    byte *out      = (byte *)malloc(outLen + 1); // Add space for null terminator
    if (out == NULL) {
        RETURN_CUSTOM_ERR(L, "memory allocation failed");
    }
    int ret = Base64_Encode_NoNl((byte *)in, inLen, out, &outLen);
    if (ret != 0) {
        free(out);
        RETURN_CUSTOM_ERR(L, "failed to encode base64");
    }
    out[outLen] = '\0'; // Add null terminator
    lua_pushstring(L, (char *)out);
    free(out);
    return 1;
}

int lua_sha256(lua_State *L) {

    size_t data_size;
    const char *data = lua_tolstring(L, 1, &data_size);
    byte hash[WC_SHA256_DIGEST_SIZE];
    int ret = -1;
    ret     = wc_Sha256Hash((byte *)data, data_size, hash);
    if (ret != 0) {
        RETURN_CUSTOM_ERR(L, "failed to calculate sha256 hash");
    }
    lua_pushlstring(L, (char *)hash, WC_SHA256_DIGEST_SIZE);
    return 1;
}

int lua_hmac(lua_State *L) {

    size_t secret_size, msg_size;
    const char *secret = lua_tolstring(L, 1, &secret_size);
    const char *msg    = lua_tolstring(L, 2, &msg_size);
    Hmac hmac;
    if (wc_HmacSetKey(&hmac, WC_SHA256, (byte *)secret, secret_size) != 0) {
        RETURN_CUSTOM_ERR(L, "failed to set HMAC key");
    }
    if (wc_HmacUpdate(&hmac, (byte *)msg, msg_size) != 0) {
        RETURN_CUSTOM_ERR(L, "failed to update HMAC");
    }
    byte hash[WC_SHA256_DIGEST_SIZE];
    if (wc_HmacFinal(&hmac, hash) != 0) {
        RETURN_CUSTOM_ERR(L, "error computing HASH");
    }
    lua_pushlstring(L, (char *)hash, WC_SHA256_DIGEST_SIZE);
    return 1;
}

#define POINT_SIZE 32

int lua_ecc_generate_key(lua_State *L) {
    WC_RNG rng;
    ecc_key key;
    byte private_key[2048];
    byte public_key[1024];
    word32 key_size     = sizeof(private_key);
    word32 pub_key_size = sizeof(public_key);
    int ret;

    uint8_t Qx[POINT_SIZE], Qy[POINT_SIZE];
    uint32_t qxlen = POINT_SIZE, qylen = POINT_SIZE;

    ret = wc_InitRng(&rng);
    if (ret != 0) {
        RETURN_CUSTOM_ERR(L, "failed to initialize RNG");
    }

    ret = wc_ecc_init(&key);
    if (ret != 0) {
        wc_FreeRng(&rng);
        RETURN_CUSTOM_ERR(L, "failed to initialize ECC key");
    }

    ret = wc_ecc_make_key_ex(&rng, 32, &key, ECC_SECP256R1);
    if (ret != 0) {
        wc_ecc_free(&key);
        wc_FreeRng(&rng);
        RETURN_CUSTOM_ERR(L, "failed to generate ECC key");
    }

    ret = wc_ecc_export_private_only(&key, private_key, &key_size);
    if (ret != 0) {
        wc_ecc_free(&key);
        wc_FreeRng(&rng);
        RETURN_CUSTOM_ERR(L, "failed to export private key");
    }

    ret = wc_ecc_export_x963(&key, public_key, &pub_key_size);
    if (ret != 0) {
        wc_ecc_free(&key);
        wc_FreeRng(&rng);
        RETURN_CUSTOM_ERR(L, "failed to export public key");
    }

    ret = wc_ecc_export_public_raw(&key, Qx, &qxlen, Qy, &qylen);
    if (ret != 0) {
        wc_ecc_free(&key);
        wc_FreeRng(&rng);
        RETURN_CUSTOM_ERR(L, "failed to export X and Y");
    }

    lua_pushlstring(L, (char *)private_key, key_size);
    lua_pushlstring(L, (char *)public_key, pub_key_size);
    lua_pushlstring(L, (char *)Qx, qxlen);
    lua_pushlstring(L, (char *)Qy, qylen);
    wc_ecc_free(&key);
    wc_FreeRng(&rng);
    return 4;
}

int lua_ecc_sign(lua_State *L) {
    size_t key_size, pub_key_size, msg_size;
    const char *private_key = lua_tolstring(L, 1, &key_size);
    const char *public_key  = lua_tolstring(L, 2, &pub_key_size);
    const char *msg         = lua_tolstring(L, 3, &msg_size);
    WC_RNG rng;
    ecc_key key;
    byte hash[WC_SHA256_DIGEST_SIZE];
    int ret, idx = 0;

    ret = wc_InitRng(&rng);
    if (ret != 0) {
        RETURN_CUSTOM_ERR(L, "failed to initialize RNG");
    }

    ret = wc_ecc_init(&key);
    if (ret != 0) {
        wc_FreeRng(&rng);
        RETURN_CUSTOM_ERR(L, "failed to initialize ECC key");
    }

    ret = wc_ecc_import_private_key((byte *)private_key, (word32)key_size, (byte *)public_key, (word32)pub_key_size,
                                    &key);
    if (ret != 0) {
        wc_ecc_free(&key);
        wc_FreeRng(&rng);
        RETURN_CUSTOM_ERR(L, "failed to decode ECC private key");
    }

    ret = wc_Sha256Hash((byte *)msg, msg_size, hash);
    if (ret != 0) {
        wc_ecc_free(&key);
        wc_FreeRng(&rng);
        RETURN_CUSTOM_ERR(L, "failed to calculate SHA256 hash");
    }

    mp_int r, s;
    mp_init(&r);
    mp_init(&s);

    ret = wc_ecc_sign_hash_ex(hash, sizeof(hash), &rng, &key, &r, &s);
    if (ret != 0) {
        mp_free(&r);
        mp_free(&s);
        wc_ecc_free(&key);
        wc_FreeRng(&rng);
        RETURN_CUSTOM_ERR(L, "failed to sign hash");
    }

    byte raw_sig[64]; // 32 bytes for r + 32 bytes for s
    int r_size = mp_unsigned_bin_size(&r);
    int s_size = mp_unsigned_bin_size(&s);
    // Pad with zeros if needed
    memset(raw_sig, 0, 64);
    mp_to_unsigned_bin(&r, raw_sig + (32 - r_size));
    mp_to_unsigned_bin(&s, raw_sig + 32 + (32 - s_size));

    mp_free(&r);
    mp_free(&s);
    wc_ecc_free(&key);
    wc_FreeRng(&rng);

    lua_pushlstring(L, (char *)raw_sig, 64);
    return 1;
}

int lua_ecc_verify(lua_State *L) {
    size_t public_size, msg_size, sig_size;
    const char *public = lua_tolstring(L, 1, &public_size);
    const char *msg    = lua_tolstring(L, 2, &msg_size);
    const char *sig    = lua_tolstring(L, 3, &sig_size);
    ecc_key key;
    byte hash[WC_SHA256_DIGEST_SIZE];
    int ret, is_valid_sig, idx = 0;

    ret = wc_ecc_init(&key);
    if (ret != 0) {
        RETURN_CUSTOM_ERR(L, "failed to initialize ECC key");
    }

    ret = wc_ecc_import_x963((byte *)public, (word32)public_size, &key);
    if (ret != 0) {
        wc_ecc_free(&key);
        RETURN_CUSTOM_ERR(L, "failed to decode ECC public key");
    }

    ret = wc_Sha256Hash((byte *)msg, msg_size, hash);
    if (ret != 0) {
        wc_ecc_free(&key);
        RETURN_CUSTOM_ERR(L, "failed to calculate SHA256 hash");
    }
    // Initialize mp_int for r and s
    mp_int r, s;
    ret = mp_init(&r);
    if (ret != 0) {
        wc_ecc_free(&key);
        RETURN_CUSTOM_ERR(L, "failed to initialize r");
    }
    ret = mp_init(&s);
    if (ret != 0) {
        mp_free(&r);
        wc_ecc_free(&key);
        RETURN_CUSTOM_ERR(L, "failed to initialize s");
    }

    // Convert first 32 bytes to r
    ret = mp_read_unsigned_bin(&r, (byte *)sig, 32);
    if (ret != 0) {
        mp_free(&r);
        mp_free(&s);
        wc_ecc_free(&key);
        RETURN_CUSTOM_ERR(L, "failed to read r value");
    }

    // Convert last 32 bytes to s
    ret = mp_read_unsigned_bin(&s, (byte *)sig + 32, 32);
    if (ret != 0) {
        mp_free(&r);
        mp_free(&s);
        wc_ecc_free(&key);
        RETURN_CUSTOM_ERR(L, "failed to read s value");
    }

    ret = wc_ecc_verify_hash_ex(&r, &s, hash, sizeof(hash), &is_valid_sig, &key);

    mp_free(&r);
    mp_free(&s);
    wc_ecc_free(&key);

    if (ret != 0) {
        RETURN_CUSTOM_ERR(L, "failed to verify signature");
    }

    lua_pushboolean(L, is_valid_sig);
    return 1;
}

int lua_ed25519_generate_key(lua_State *L) {
    WC_RNG rng;
    ed25519_key key;
    byte private_key[ED25519_KEY_SIZE];
    byte public_key[ED25519_PUB_KEY_SIZE];
    word32 key_size     = sizeof(private_key);
    word32 pub_key_size = sizeof(public_key);
    int ret;

    ret = wc_InitRng(&rng);
    if (ret != 0) {
        RETURN_CUSTOM_ERR(L, "failed to initialize RNG");
    }

    ret = wc_ed25519_init(&key);
    if (ret != 0) {
        wc_FreeRng(&rng);
        RETURN_CUSTOM_ERR(L, "failed to initialize Ed25519 key");
    }

    ret = wc_ed25519_make_key(&rng, 32, &key);
    if (ret != 0) {
        wc_ed25519_free(&key);
        wc_FreeRng(&rng);
        RETURN_CUSTOM_ERR(L, "failed to generate Ed25519 key");
    }

    ret = wc_ed25519_export_private_only(&key, private_key, &key_size);
    if (ret < 0) {
        wc_ed25519_free(&key);
        wc_FreeRng(&rng);
        RETURN_CUSTOM_ERR(L, "failed to export Ed25519 private key to DER");
    }

    ret = wc_ed25519_export_public(&key, public_key, &pub_key_size);
    if (ret < 0) {
        wc_ed25519_free(&key);
        wc_FreeRng(&rng);
        RETURN_CUSTOM_ERR(L, "failed to export Ed25519 public key");
    }

    lua_pushlstring(L, (char *)private_key, key_size);
    lua_pushlstring(L, (char *)public_key, pub_key_size);
    wc_ed25519_free(&key);
    wc_FreeRng(&rng);
    return 2;
}

int lua_ed25519_sign(lua_State *L) {
    size_t key_size, msg_size;
    const char *private_key = lua_tolstring(L, 1, &key_size);
    const char *msg         = lua_tolstring(L, 2, &msg_size);
    byte public_key[ED25519_PUB_KEY_SIZE];
    word32 pub_key_size = sizeof(public_key);
    ed25519_key key;
    byte sig[ED25519_SIG_SIZE];
    word32 sigLen = sizeof(sig);
    int ret, idx = 0;

    ret = wc_ed25519_init(&key);
    if (ret != 0) {
        RETURN_CUSTOM_ERR(L, "failed to initialize Ed25519 key");
    }

    ret = wc_ed25519_import_private_only((byte *)private_key, (word32)key_size, &key);
    if (ret != 0) {
        wc_ed25519_free(&key);
        RETURN_CUSTOM_ERR(L, "failed to decode Ed25519 private key");
    }

    ret = wc_ed25519_make_public(&key, public_key, pub_key_size);
    if (ret != 0) {
        wc_ed25519_free(&key);
        RETURN_CUSTOM_ERR(L, "failed to deduce public key");
    }

    ret = wc_ed25519_import_public(public_key, pub_key_size, &key);
    if (ret != 0) {
        wc_ed25519_free(&key);
        RETURN_CUSTOM_ERR(L, "failed to import public key");
    }

    ret = wc_ed25519_sign_msg((byte *)msg, (word32)msg_size, sig, &sigLen, &key);
    if (ret != 0) {
        wc_ed25519_free(&key);
        RETURN_CUSTOM_ERR(L, "failed to sign message");
    }

    lua_pushlstring(L, (char *)sig, sigLen);
    wc_ed25519_free(&key);
    return 1;
}

int lua_ed25519_verify(lua_State *L) {
    size_t pub_key_size, msg_size, sig_size;
    const char *public_key = lua_tolstring(L, 1, &pub_key_size);
    const char *msg        = lua_tolstring(L, 2, &msg_size);
    const char *sig        = lua_tolstring(L, 3, &sig_size);
    ed25519_key key;
    int ret, is_valid_sig = 0;
    int idx = 0;

    ret = wc_ed25519_init(&key);
    if (ret != 0) {
        RETURN_CUSTOM_ERR(L, "failed to initialize Ed25519 key");
    }

    ret = wc_ed25519_import_public((byte *)public_key, (word32)pub_key_size, &key);
    if (ret != 0) {
        wc_ed25519_free(&key);
        RETURN_CUSTOM_ERR(L, "failed to decode Ed25519 public key");
    }

    ret = wc_ed25519_verify_msg((byte *)sig, (word32)sig_size, (byte *)msg, (word32)msg_size, &is_valid_sig, &key);
    if (ret != 0) {
        wc_ed25519_free(&key);
        RETURN_CUSTOM_ERR(L, "failed to verify signature");
    }
    lua_pushboolean(L, is_valid_sig);
    wc_ed25519_free(&key);
    return 1;
}

int lua_generate_csr(lua_State *L) {
    size_t key_size, pub_key_size, domain_size;
    const char *private_key = lua_tolstring(L, 1, &key_size);
    const char *public_key  = lua_tolstring(L, 2, &pub_key_size);
    const char *domain      = lua_tolstring(L, 3, &domain_size);

    WC_RNG rng;
    ecc_key key;
    Cert req;
    byte der[4096];
    int ret, derSz;

    /* Initialize RNG */
    ret = wc_InitRng(&rng);
    if (ret != 0) {
        RETURN_CUSTOM_ERR(L, "failed to initialize RNG");
    }

    /* Initialize key */
    ret = wc_ecc_init(&key);
    if (ret != 0) {
        wc_FreeRng(&rng);
        RETURN_CUSTOM_ERR(L, "failed to initialize ECC key");
    }

    /* Import the private key */
    ret = wc_ecc_import_private_key((byte *)private_key, (word32)key_size, (byte *)public_key, (word32)pub_key_size,
                                    &key);
    if (ret != 0) {
        wc_ecc_free(&key);
        wc_FreeRng(&rng);
        RETURN_CUSTOM_ERR(L, "failed to import private key");
    }

    /* Initialize certificate request */
    ret = wc_InitCert(&req);
    if (ret != 0) {
        wc_ecc_free(&key);
        wc_FreeRng(&rng);
        RETURN_CUSTOM_ERR(L, "failed to initialize certificate request");
    }

    /* Set certificate request fields */
    strncpy(req.subject.commonName, domain, CTC_NAME_SIZE);
    req.sigType = CTC_SHA256wECDSA;

    /* Add alternative names if provided */
    if (lua_gettop(L) >= 4 && !lua_isnil(L, 4)) {
        if (!lua_istable(L, 4)) {
            wc_ecc_free(&key);
            wc_FreeRng(&rng);
            RETURN_CUSTOM_ERR(L, "alternative names must be a table");
        }

        byte alt_names[1024]; // Increased buffer size for multiple names
        int idx = 0;

        // Start SEQUENCE
        alt_names[idx++] = 0x30; // SEQUENCE
        alt_names[idx++] = 0x00; // Length (will be filled later)

        // Iterate through the table of alternative names
        lua_pushnil(L); // First key
        while (lua_next(L, 4) != 0) {
            size_t alt_name_size;
            const char *alt_name = lua_tolstring(L, -1, &alt_name_size);

            if (idx + alt_name_size + 4 > sizeof(alt_names)) { // Check buffer space
                lua_pop(L, 2);                                 // Remove key and value
                wc_ecc_free(&key);
                wc_FreeRng(&rng);
                RETURN_CUSTOM_ERR(L, "alternative names too long");
            }

            // Add DNS name
            alt_names[idx++] = 0x82; // DNSName tag
            alt_names[idx++] = (byte)alt_name_size;
            memcpy(&alt_names[idx], alt_name, alt_name_size);
            idx += alt_name_size;

            lua_pop(L, 1); // Remove value, keep key for next iteration
        }

        // Fill in the sequence length
        alt_names[1] = (byte)(idx - 2);

        // Copy to cert request
        memcpy(req.altNames, alt_names, idx);
        req.altNamesSz = idx;
    }

    /* Generate CSR */
    ret = wc_MakeCertReq_ex(&req, der, sizeof(der), ECC_TYPE, &key);
    if (ret <= 0) {
        wc_ecc_free(&key);
        wc_FreeRng(&rng);
        RETURN_CUSTOM_ERR(L, "failed to generate certificate request");
    }
    derSz = ret;

    /* Sign the CSR */
    ret = wc_SignCert_ex(req.bodySz, req.sigType, der, sizeof(der), ECC_TYPE, &key, &rng);
    if (ret <= 0) {
        wc_ecc_free(&key);
        wc_FreeRng(&rng);
        RETURN_CUSTOM_ERR(L, "failed to sign certificate request");
    }
    derSz = ret;

    lua_pushlstring(L, (char *)der, derSz);

    wc_ecc_free(&key);
    wc_FreeRng(&rng);
    return 1;
}

int lua_der_to_pem_ecc_key(lua_State *L) {
    size_t key_size, pub_key_size;
    const char *private_key = lua_tolstring(L, 1, &key_size);
    const char *public_key  = lua_tolstring(L, 2, &pub_key_size);

    ecc_key key;
    byte der[4096];
    byte pem[4096];
    word32 derSz;
    int ret;

    /* Initialize key */
    ret = wc_ecc_init(&key);
    if (ret != 0) {
        RETURN_CUSTOM_ERR(L, "failed to initialize ECC key");
    }

    /* Import the private key */
    ret = wc_ecc_import_private_key((byte *)private_key, (word32)key_size, (byte *)public_key, (word32)pub_key_size,
                                    &key);
    if (ret != 0) {
        wc_ecc_free(&key);
        RETURN_CUSTOM_ERR(L, "failed to import private key");
    }

    /* Convert key to DER */
    ret = wc_EccKeyToDer(&key, der, sizeof(der));
    if (ret <= 0) {
        wc_ecc_free(&key);
        RETURN_CUSTOM_ERR(L, "failed to convert key to DER");
    }
    derSz = ret;

    /* Convert DER to PEM */
    ret = wc_DerToPem(der, derSz, pem, sizeof(pem), ECC_PRIVATEKEY_TYPE);
    if (ret <= 0) {
        wc_ecc_free(&key);
        RETURN_CUSTOM_ERR(L, "failed to convert DER to PEM");
    }

    lua_pushlstring(L, (char *)pem, ret);
    wc_ecc_free(&key);
    return 1;
}

int lua_parse_x509_cert(lua_State *L) {
    size_t cert_der_size;
    const char *cert_der = lua_tolstring(L, 1, &cert_der_size);

    if (!cert_der) {
        RETURN_CUSTOM_ERR(L, "no certificate provided");
    }

    DecodedCert cert;
    wc_InitDecodedCert(&cert, cert_der, cert_der_size, NULL);

    int ret = wc_ParseCert(&cert, CERT_TYPE, NO_VERIFY, NULL);
    if (ret != 0) {
        wc_FreeDecodedCert(&cert);
        RETURN_CUSTOM_ERR(L, "failed to parse certificate");
    }

    // Create result table
    lua_createtable(L, 0, 3);

    // Add common name
    if (cert.subjectCN && cert.subjectCNLen > 0) {
        lua_pushstring(L, "common_name");
        lua_pushlstring(L, cert.subjectCN, cert.subjectCNLen);
        lua_settable(L, -3);
    }

    // Add validity dates
    if (cert.beforeDate && cert.beforeDateLen > 0) {
        lua_pushstring(L, "not_before");
        lua_pushlstring(L, (const char *)cert.beforeDate, cert.beforeDateLen);
        lua_settable(L, -3);
    }

    if (cert.afterDate && cert.afterDateLen > 0) {
        lua_pushstring(L, "not_after");
        lua_pushlstring(L, (const char *)cert.afterDate, cert.afterDateLen);
        lua_settable(L, -3);
    }

    wc_FreeDecodedCert(&cert);
    return 1;
}

static luaL_Reg funcs[] = {
    {"sha256",               lua_sha256              },
    {"hmac",                 lua_hmac                },
    {"base64_decode",        lua_base64_decode       },
    {"base64_encode",        lua_base64_encode       },
    {"ecc_generate_key",     lua_ecc_generate_key    },
    {"ecc_sign",             lua_ecc_sign            },
    {"ecc_verify",           lua_ecc_verify          },
    {"ed25519_generate_key", lua_ed25519_generate_key},
    {"ed25519_sign",         lua_ed25519_sign        },
    {"ed25519_verify",       lua_ed25519_verify      },
    {"generate_csr",         lua_generate_csr        },
    {"der_to_pem_ecc_key",   lua_der_to_pem_ecc_key  },
    {"parse_x509_cert",      lua_parse_x509_cert     },
    {NULL,                   NULL                    }
};

int luaopen_crypto_core(lua_State *L) {
    /* Return the module */
    luaL_newlib(L, funcs);
    return 1;
}
