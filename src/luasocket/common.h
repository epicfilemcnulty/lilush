#pragma once

#define LSEC_API         extern
#define lua_rawlen(L, i) lua_objlen(L, i)

#define SSL_NOTHING 1
#define SSL_WRITING 2
#define SSL_READING 3
