#pragma once
/*=========================================================================*\
* UNIX STREAM object
* LuaSocket toolkit
*
* The unixstream.h module is basicly a glue that puts together modules buffer.h,
* timeout.h socket.h and inet.h to provide the LuaSocket UNIX STREAM (AF_UNIX,
* SOCK_STREAM) support.
*
* Three classes are defined: master, client and server. The master class is
* a newly created unixstream object, that has not been bound or connected. Server
* objects are unixstream objects bound to some local address. Client objects are
* unixstream objects either connected to some address or returned by the accept
* method of a server object.
\*=========================================================================*/
#include "unix.h"

#pragma GCC visibility push(hidden)

int unixstream_open(lua_State *L);

#pragma GCC visibility pop
