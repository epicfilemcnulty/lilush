#pragma once
/*=========================================================================*\
* Select implementation
* LuaSocket toolkit
*
* Each object that can be passed to the select function has to export
* method getfd() which returns the descriptor to be passed to the
* underlying select function. Another method, dirty(), should return
* true if there is data ready for reading (required for buffered input).
\*=========================================================================*/

#pragma GCC visibility push(hidden)

int select_open(lua_State *L);

#pragma GCC visibility pop
