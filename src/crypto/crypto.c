// SPDX-FileCopyrightText: © 2024 Vladimir Zorin <vladimir@deviant.guru>
// SPDX-License-Identifier: GPL-3.0-or-later
#include <string.h>

#include <wolfssl/options.h>
#include <wolfssl/ssl.h>
#include <wolfssl/wolfcrypt/coding.h>
#include <wolfssl/wolfcrypt/error-crypt.h>
#include <wolfssl/wolfcrypt/hash.h>
#include <wolfssl/wolfcrypt/settings.h>
#include <wolfssl/wolfcrypt/sha256.h>

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

static luaL_Reg funcs[] = {
    {"sha256",        lua_sha256       },
    {"hmac",          lua_hmac         },
    {"base64_decode", lua_base64_decode},
    {"base64_encode", lua_base64_encode},
    {NULL,            NULL             }
};

int luaopen_crypto_core(lua_State *L) {
    /* Return the module */
    luaL_newlib(L, funcs);
    return 1;
}
