#pragma once

/*--------------------------------------------------------------------------
 * LuaSec 1.2.0
 *
 * Copyright (C) 2006-2022 Bruno Silvestre
 *
 *--------------------------------------------------------------------------*/

#include <lua.h>
#include <wolfssl/options.h>
#include <wolfssl/ssl.h>

#include "common.h"

#define LSEC_MODE_INVALID 0
#define LSEC_MODE_SERVER  1
#define LSEC_MODE_CLIENT  2

#define LSEC_VERIFY_CONTINUE       1
#define LSEC_VERIFY_IGNORE_PURPOSE 2

typedef struct t_context_ {
    WOLFSSL_CTX *context;
    lua_State *L;
    int mode;
} t_context;
typedef t_context *p_context;

/* Retrieve the SSL context from the Lua stack */
WOLFSSL_CTX *lsec_checkcontext(lua_State *L, int idx);
WOLFSSL_CTX *lsec_testcontext(lua_State *L, int idx);

/* Retrieve the mode from the context in the Lua stack */
int lsec_getmode(lua_State *L, int idx);

/* Registre the module. */
LSEC_API int luaopen_ssl_context(lua_State *L);