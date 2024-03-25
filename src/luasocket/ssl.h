#pragma once

/*--------------------------------------------------------------------------
 * LuaSec 1.2.0
 *
 * Copyright (C) 2006-2022 Bruno Silvestre
 *
 *--------------------------------------------------------------------------*/

#include <lua.h>

#include "buffer.h"
#include "io.h"
#include "socket.h"
#include "timeout.h"
#include "usocket.h"

#include "common.h"
#include "context.h"

#define LSEC_STATE_NEW       1
#define LSEC_STATE_CONNECTED 2
#define LSEC_STATE_CLOSED    3

#define LSEC_IO_SSL -100

typedef struct t_ssl_ {
    t_socket sock;
    t_io io;
    t_buffer buf;
    t_timeout tm;
    WOLFSSL *ssl;
    int state;
    int error;
} t_ssl;
typedef t_ssl *p_ssl;

LSEC_API int luaopen_ssl_core(lua_State *L);