// SPDX-FileCopyrightText: © 2024 Vladimir Zorin <vladimir@deviant.guru>
// SPDX-License-Identifier: GPL-3.0-or-later
#include <string.h>

#include <wolfssl/options.h>
#include <wolfssl/ssl.h>
#include <wolfssl/wolfcrypt/coding.h>
#include <wolfssl/wolfcrypt/ecc.h>
#include <wolfssl/wolfcrypt/error-crypt.h>
#include <wolfssl/wolfcrypt/hash.h>
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

// Lua interface for Base64_Encode
int lua_base64_encode(lua_State *L) {
    size_t inLen;
    const char *in = lua_tolstring(L, 1, &inLen);
    word32 outLen  = (inLen / 3) * 4 + 128;      // Conservative output length
    byte *out      = (byte *)malloc(outLen + 1); // Add space for null terminator
    if (out == NULL) {
        RETURN_CUSTOM_ERR(L, "memory allocation failed");
    }
    int ret = Base64_Encode((byte *)in, inLen, out, &outLen);
    if (ret != 0) {
        free(out);
        RETURN_CUSTOM_ERR(L, "failed to encode base64");
    }
    out[outLen] = '\0'; // Add null terminator
    lua_pushstring(L, (char *)out);
    free(out);
    return 1;
}

int lua_base64url_encode(lua_State *L) {
    size_t inLen;
    const char *in = lua_tolstring(L, 1, &inLen);
    word32 outLen  = (inLen / 3) * 4 + 128;      // Conservative output length
    byte *out      = (byte *)malloc(outLen + 1); // Add space for null terminator
    if (out == NULL) {
        RETURN_CUSTOM_ERR(L, "memory allocation failed");
    }
    int ret = Base64_Encode((byte *)in, inLen, out, &outLen);
    if (ret != 0) {
        free(out);
        RETURN_CUSTOM_ERR(L, "failed to encode base64");
    }
    out[outLen] = '\0'; // Add null terminator

    // Replace '+' with '-', '/' with '_', and remove '='
    for (word32 i = 0; i < outLen; i++) {
        if (out[i] == '+') {
            out[i] = '-';
        } else if (out[i] == '/') {
            out[i] = '_';
        } else if (out[i] == '=') {
            out[i] = '\0';
            outLen--;
            break;
        }
    }
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

int lua_ecc_generate_key(lua_State *L) {
    WC_RNG rng;
    ecc_key key;
    byte der[2048];
    byte pub_der[1024];
    word32 derSz;
    word32 pub_derSz;
    int ret;

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

    memset(der, 0, sizeof(der));
    ret = wc_EccKeyToDer(&key, der, sizeof(der));
    if (ret < 0) {
        wc_ecc_free(&key);
        wc_FreeRng(&rng);
        RETURN_CUSTOM_ERR(L, "failed to export ECC key to DER");
    }
    derSz = ret;

    memset(pub_der, 0, sizeof(pub_der));
    ret = wc_EccPublicKeyToDer(&key, pub_der, sizeof(pub_der), 1);
    if (ret < 0) {
        wc_ecc_free(&key);
        wc_FreeRng(&rng);
        RETURN_CUSTOM_ERR(L, "failed to export public ECC key to DER");
    }
    pub_derSz = ret;

    lua_pushlstring(L, (char *)der, derSz);
    lua_pushlstring(L, (char *)pub_der, pub_derSz);
    wc_ecc_free(&key);
    wc_FreeRng(&rng);
    return 2;
}
int lua_ecc_sign(lua_State *L) {
    size_t secret_size, msg_size;
    const char *secret = lua_tolstring(L, 1, &secret_size);
    const char *msg    = lua_tolstring(L, 2, &msg_size);
    WC_RNG rng;
    ecc_key key;
    byte hash[WC_SHA256_DIGEST_SIZE];
    byte sig[ECC_MAX_SIG_SIZE];
    word32 sigLen = ECC_MAX_SIG_SIZE;
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

    ret = wc_EccPrivateKeyDecode((byte *)secret, &idx, &key, (word32)secret_size);
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

    ret = wc_ecc_sign_hash(hash, sizeof(hash), sig, &sigLen, &rng, &key);
    if (ret != 0) {
        wc_ecc_free(&key);
        wc_FreeRng(&rng);
        RETURN_CUSTOM_ERR(L, "failed to sign hash");
    }

    lua_pushlstring(L, (char *)sig, sigLen);
    wc_ecc_free(&key);
    wc_FreeRng(&rng);
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

    ret = wc_EccPublicKeyDecode((byte *)public, &idx, &key, (word32)public_size);
    if (ret != 0) {
        wc_ecc_free(&key);
        RETURN_CUSTOM_ERR(L, "failed to decode ECC public key");
    }

    ret = wc_Sha256Hash((byte *)msg, msg_size, hash);
    if (ret != 0) {
        wc_ecc_free(&key);
        RETURN_CUSTOM_ERR(L, "failed to calculate SHA256 hash");
    }

    ret = wc_ecc_verify_hash((byte *)sig, sig_size, hash, sizeof(hash), &is_valid_sig, &key);
    if (ret != 0) {
        wc_ecc_free(&key);
        RETURN_CUSTOM_ERR(L, "failed to verify signature");
    }

    lua_pushboolean(L, is_valid_sig);
    wc_ecc_free(&key);
    return 1;
}
static luaL_Reg funcs[] = {
    {"sha256",           lua_sha256          },
    {"hmac",             lua_hmac            },
    {"base64_decode",    lua_base64_decode   },
    {"base64_encode",    lua_base64_encode   },
    {"base64url_encode", lua_base64url_encode},
    {"ecc_generate_key", lua_ecc_generate_key},
    {"ecc_sign",         lua_ecc_sign        },
    {"ecc_verify",       lua_ecc_verify      },
    {NULL,               NULL                }
};

int luaopen_crypto_core(lua_State *L) {
    /* Return the module */
    luaL_newlib(L, funcs);
    return 1;
}
