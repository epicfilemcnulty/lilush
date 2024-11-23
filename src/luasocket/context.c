/*--------------------------------------------------------------------------
 * LuaSec 1.2.0
 *
 * Copyright (C) 2014-2022 Kim Alvefur, Paul Aurich, Tobias Markmann,
 *                         Matthew Wild.
 * Copyright (C) 2006-2022 Bruno Silvestre.
 *
 *--------------------------------------------------------------------------*/

#include <string.h>

#include <lauxlib.h>
#include <lua.h>

#include "context.h"

/*--------------------------- Auxiliary Functions ----------------------------*/

/**
 * Return the context.
 */
static p_context checkctx(lua_State *L, int idx) {
    return (p_context)luaL_checkudata(L, idx, "SSL:Context");
}

static p_context testctx(lua_State *L, int idx) {
    return (p_context)luaL_testudata(L, idx, "SSL:Context");
}

/*------------------------------ Lua Functions -------------------------------*/

/**
 * Create a SSL context.
 */
static int create(lua_State *L) {
    p_context ctx;
    const char *mode_str = luaL_optstring(L, 1, "client"); // Default to client mode

    ctx = (p_context)lua_newuserdata(L, sizeof(t_context));
    if (!ctx) {
        lua_pushnil(L);
        lua_pushstring(L, "error creating context");
        return 2;
    }
    memset(ctx, 0, sizeof(t_context));

    if (strcmp(mode_str, "server") == 0) {
        ctx->context = wolfSSL_CTX_new(wolfTLSv1_3_server_method());
        ctx->mode    = LSEC_MODE_SERVER;
    } else if (strcmp(mode_str, "client") == 0) {
        ctx->context = wolfSSL_CTX_new(wolfTLS_client_method());
        ctx->mode    = LSEC_MODE_CLIENT;
    } else {
        lua_pushnil(L);
        lua_pushstring(L, "invalid mode");
        return 2;
    }

    if (!ctx->context) {
        lua_pushnil(L);
        lua_pushfstring(L, "error creating context (%s)", "unknown");
        return 2;
    }

    ctx->L = L;
    luaL_getmetatable(L, "SSL:Context");
    lua_setmetatable(L, -2);
    return 1;
}

static int no_verify_mode(lua_State *L) {
    WOLFSSL_CTX *ctx = lsec_checkcontext(L, 1);
    int enable       = lua_toboolean(L, 2);
    if (enable) {
        wolfSSL_CTX_set_verify(ctx, SSL_VERIFY_NONE, 0);
    } else {
        wolfSSL_CTX_set_verify(ctx, SSL_VERIFY_PEER, 0);
    }
    lua_pushboolean(L, 1);
    return 1;
}

static int set_sni(lua_State *L) {
    int ret;
    WOLFSSL_CTX *ctx        = lsec_checkcontext(L, 1);
    const char *server_name = luaL_optstring(L, 2, NULL);
    ret                     = wolfSSL_CTX_UseSNI(ctx, WOLFSSL_SNI_HOST_NAME, server_name, strlen(server_name));
    if (ret != SSL_SUCCESS) {
        lua_pushboolean(L, 0);
        lua_pushstring(L, "Failed to set SNI");
        return 2;
    }
    lua_pushboolean(L, 1);
    return 1;
}
/**
 * Load the trusting certificates.
 */
static int load_locations(lua_State *L) {
    WOLFSSL_CTX *ctx     = lsec_checkcontext(L, 1);
    const char *cafile   = luaL_optstring(L, 2, NULL);
    const char *capath   = luaL_optstring(L, 3, NULL);
    const char *certfile = luaL_optstring(L, 4, NULL);
    const char *keyfile  = luaL_optstring(L, 5, NULL);

    if (certfile && keyfile) {
        int ret = wolfSSL_CTX_use_certificate_file(ctx, certfile, WOLFSSL_FILETYPE_PEM);
        if (ret != 1) {
            const char *err = wolfSSL_ERR_reason_error_string(wolfSSL_get_error(ctx, ret));
            lua_pushboolean(L, 0);
            lua_pushfstring(L, "error loading server certificate (%s): %s", certfile, err);
            return 2;
        }
        ret = wolfSSL_CTX_use_PrivateKey_file(ctx, keyfile, WOLFSSL_FILETYPE_PEM);
        if (ret != 1) {
            const char *err = wolfSSL_ERR_reason_error_string(wolfSSL_get_error(ctx, ret));
            lua_pushboolean(L, 0);
            lua_pushfstring(L, "error loading server key (%s): %s", keyfile, err);
            return 2;
        }
    }

    if (cafile || capath) {
        if (wolfSSL_CTX_load_verify_locations(ctx, cafile, capath) != 1) {
            lua_pushboolean(L, 0);
            lua_pushfstring(L, "error loading CA locations (%s)", "unknown");
            return 2;
        }
    }
    lua_pushboolean(L, 1);
    return 1;
}

/**
 * Set the context mode.
 */
static int set_mode(lua_State *L) {
    p_context ctx   = checkctx(L, 1);
    const char *str = luaL_checkstring(L, 2);
    if (!strcmp("server", str)) {
        ctx->mode = LSEC_MODE_SERVER;
        lua_pushboolean(L, 1);
        return 1;
    }
    if (!strcmp("client", str)) {
        ctx->mode = LSEC_MODE_CLIENT;
        lua_pushboolean(L, 1);
        return 1;
    }
    lua_pushboolean(L, 0);
    lua_pushfstring(L, "invalid mode (%s)", str);
    return 2;
}

/**
 * Package functions
 */
static luaL_Reg funcs[] = {
    {"create",         create        },
    {"locations",      load_locations},
    {"setmode",        set_mode      },
    {"sni",            set_sni       },
    {"no_verify_mode", no_verify_mode},
    {NULL,             NULL          }
};

/*-------------------------------- Metamethods -------------------------------*/

/**
 * Collect SSL context -- GC metamethod.
 */
static int meth_destroy(lua_State *L) {
    p_context ctx = checkctx(L, 1);
    if (ctx->context) {
        wolfSSL_CTX_free(ctx->context);
        ctx->context = NULL;
    }
    return 0;
}

/**
 * Object information -- tostring metamethod.
 */
static int meth_tostring(lua_State *L) {
    p_context ctx = checkctx(L, 1);
    lua_pushfstring(L, "SSL context: %p", ctx);
    return 1;
}

/**
 * Context metamethods.
 */
static luaL_Reg meta[] = {
    {"__close",    meth_destroy },
    {"__gc",       meth_destroy },
    {"__tostring", meth_tostring},
    {NULL,         NULL         }
};

static int meth_set_verify_ext(lua_State *L) {
    /* Ok */
    lua_pushboolean(L, 1);
    return 1;
}
/**
 * Index metamethods.
 */
static luaL_Reg meta_index[] = {
    {"setverifyext", meth_set_verify_ext},
    {NULL,           NULL               }
};

/*----------------------------- Public Functions  ---------------------------*/

/**
 * Retrieve the SSL context from the Lua stack.
 */
WOLFSSL_CTX *lsec_checkcontext(lua_State *L, int idx) {
    p_context ctx = checkctx(L, idx);
    return ctx->context;
}

WOLFSSL_CTX *lsec_testcontext(lua_State *L, int idx) {
    p_context ctx = testctx(L, idx);
    return (ctx) ? ctx->context : NULL;
}

/**
 * Retrieve the mode from the context in the Lua stack.
 */
int lsec_getmode(lua_State *L, int idx) {
    p_context ctx = checkctx(L, idx);
    return ctx->mode;
}

/*------------------------------ Initialization ------------------------------*/

/**
 * Registre the module.
 */
LSEC_API int luaopen_ssl_context(lua_State *L) {
    luaL_newmetatable(L, "SSL:Context");
    luaL_setfuncs(L, meta, 0);

    /* Create __index metamethods for context */
    luaL_newlib(L, meta_index);
    lua_setfield(L, -2, "__index");

    /* Return the module */
    luaL_newlib(L, funcs);

    return 1;
}
