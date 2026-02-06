#pragma once
/*=========================================================================*\
* Timeout management functions
* LuaSocket toolkit
\*=========================================================================*/
#include "luasocket.h"

/* timeout control structure */
typedef struct t_timeout_ {
    double block; /* maximum time for blocking calls */
    double total; /* total number of miliseconds for operation */
    double start; /* time of start of operation */
} t_timeout;
typedef t_timeout *p_timeout;

#pragma GCC visibility push(hidden)

void timeout_init(p_timeout tm, double block, double total);
double timeout_get(p_timeout tm);
double timeout_getstart(p_timeout tm);
double timeout_getretry(p_timeout tm);
p_timeout timeout_markstart(p_timeout tm);

double timeout_gettime(void);

int timeout_open(lua_State *L);

int timeout_meth_settimeout(lua_State *L, p_timeout tm);
int timeout_meth_gettimeout(lua_State *L, p_timeout tm);

#pragma GCC visibility pop

static inline int timeout_iszero(p_timeout tm) {
    if (tm->block == 0.0)
        return 1; /* fast path: explicitly non-blocking */
    if (tm->block < 0.0 && tm->total < 0.0)
        return 0; /* no timeout set */
    return timeout_getretry(tm) <= 0.0;
}
