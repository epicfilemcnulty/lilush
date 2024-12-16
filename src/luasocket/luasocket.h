#pragma once
/*=========================================================================*\
* LuaSocket toolkit
* Networking support for the Lua language
* Diego Nehab
* 9/11/1999
\*=========================================================================*/

/*-------------------------------------------------------------------------* \
* Current socket library version
\*-------------------------------------------------------------------------*/
#define LUASOCKET_VERSION "LuaSocketWolfSSL 0.5.6-19-g56e5e39"
#define LUASOCKET_COPYRIGHT "Copyright (C) 1999-2013 Diego Nehab"

/*-------------------------------------------------------------------------*\
* This macro prefixes all exported API functions
\*-------------------------------------------------------------------------*/
#ifndef LUASOCKET_API
#define LUASOCKET_API __attribute__((visibility("default")))
#endif

#include "common.h"
#include "lauxlib.h"
#include "lua.h"

/*-------------------------------------------------------------------------*\
* Initializes the library.
\*-------------------------------------------------------------------------*/
LUASOCKET_API int luaopen_socket_core(lua_State *L);