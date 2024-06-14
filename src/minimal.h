// SPDX-FileCopyrightText: © 2024 Vladimir Zorin <vladimir@deviant.guru>
// SPDX-License-Identifier: GPL-3.0-or-later

typedef struct mod_lua {
    const char *const name;
    const char *const code;
    const size_t *const size;
} mod_lua__t;

// Standard Library Extenstion
#include "../build/std/mod_lua_std.h"
// LuaSocket modules
#include "../build/luasocket/mod_lua_headers.h"
#include "../build/luasocket/mod_lua_http.h"
#include "../build/luasocket/mod_lua_https.h"
#include "../build/luasocket/mod_lua_ltn12.h"
#include "../build/luasocket/mod_lua_mime.h"
#include "../build/luasocket/mod_lua_socket.h"
#include "../build/luasocket/mod_lua_ssl.h"
#include "../build/luasocket/mod_lua_url.h"
#include "../build/luasocket/mod_lua_web.h"
// Text
#include "../build/text/mod_lua_text.h"
// Argparser
#include "../build/argparser/mod_lua_argparser.h"
// DNS (LuaResolver for now)
#include "../build/dns/mod_lua_dns.dig.h"
#include "../build/dns/mod_lua_dns.parser.h"
#include "../build/dns/mod_lua_dns.resolver.h"
// HMAC-SHA256
#include "../build/crypto/mod_lua_crypto.h"
// term
#include "../build/term/mod_lua_term.h"
#include "../build/term/mod_lua_term.input.completion.h"
#include "../build/term/mod_lua_term.input.h"
#include "../build/term/mod_lua_term.input.history.h"
#include "../build/term/mod_lua_term.tss.h"
#include "../build/term/mod_lua_term.widgets.h"
// djot
#include "../build/djot/mod_lua_djot.ast.h"
#include "../build/djot/mod_lua_djot.attributes.h"
#include "../build/djot/mod_lua_djot.block.h"
#include "../build/djot/mod_lua_djot.filter.h"
#include "../build/djot/mod_lua_djot.h"
#include "../build/djot/mod_lua_djot.html.h"
#include "../build/djot/mod_lua_djot.inline.h"
// redis
#include "../build/redis/mod_lua_redis.h"

const mod_lua__t lua_preload[] = {
    {"socket",                mod_lua_socket,                &mod_lua_socket_SIZE               },
    {"socket.headers",        mod_lua_headers,               &mod_lua_headers_SIZE              },
    {"socket.http",           mod_lua_http,                  &mod_lua_http_SIZE                 },
    {"socket.url",            mod_lua_url,                   &mod_lua_url_SIZE                  },
    {"ssl",                   mod_lua_ssl,                   &mod_lua_ssl_SIZE                  },
    {"ssl.https",             mod_lua_https,                 &mod_lua_https_SIZE                },
    {"web",                   mod_lua_web,                   &mod_lua_web_SIZE                  },
    {"ltn12",                 mod_lua_ltn12,                 &mod_lua_ltn12_SIZE                },
    {"mime",                  mod_lua_mime,                  &mod_lua_mime_SIZE                 },
    {"std",                   mod_lua_std,                   &mod_lua_std_SIZE                  },
    {"argparser",             mod_lua_argparser,             &mod_lua_argparser_SIZE            },
    {"crypto",                mod_lua_crypto,                &mod_lua_crypto_SIZE               },
    {"term",                  mod_lua_term,                  &mod_lua_term_SIZE                 },
    {"text",                  mod_lua_text,                  &mod_lua_text_SIZE                 },
    {"term.widgets",          mod_lua_term_widgets,          &mod_lua_term_widgets_SIZE         },
    {"term.tss",              mod_lua_term_tss,              &mod_lua_term_tss_SIZE             },
    {"term.input",            mod_lua_term_input,            &mod_lua_term_input_SIZE           },
    {"term.input.history",    mod_lua_term_input_history,    &mod_lua_term_input_history_SIZE   },
    {"term.input.completion", mod_lua_term_input_completion, &mod_lua_term_input_completion_SIZE},
    {"dns.resolver",          mod_lua_dns_resolver,          &mod_lua_dns_resolver_SIZE         },
    {"dns.parser",            mod_lua_dns_parser,            &mod_lua_dns_parser_SIZE           },
    {"dns.dig",               mod_lua_dns_dig,               &mod_lua_dns_dig_SIZE              },
    {"djot",                  mod_lua_djot,                  &mod_lua_djot_SIZE                 },
    {"djot.ast",              mod_lua_djot_ast,              &mod_lua_djot_ast_SIZE             },
    {"djot.attributes",       mod_lua_djot_attributes,       &mod_lua_djot_attributes_SIZE      },
    {"djot.block",            mod_lua_djot_block,            &mod_lua_djot_block_SIZE           },
    {"djot.filter",           mod_lua_djot_filter,           &mod_lua_djot_filter_SIZE          },
    {"djot.html",             mod_lua_djot_html,             &mod_lua_djot_html_SIZE            },
    {"djot.inline",           mod_lua_djot_inline,           &mod_lua_djot_inline_SIZE          },
    {"redis",                 mod_lua_redis,                 &mod_lua_redis_SIZE                },
    {NULL,                    NULL,                          NULL                               }
};

/*----------------------------------------------------------------
; Modules written in C.  We can use luaL_register() to load these
; into package.preloaded[]
;----------------------------------------------------------------*/

extern int luaopen_socket_core(lua_State *L);
extern int luaopen_socket_unix(lua_State *L);
extern int luaopen_mime_core(lua_State *L);
extern int luaopen_socket_serial(lua_State *L);
extern int luaopen_cjson(lua_State *L);
extern int luaopen_cjson_safe(lua_State *L);
extern int luaopen_ssl_context(lua_State *L);
extern int luaopen_ssl_core(lua_State *L);
extern int luaopen_deviant_core(lua_State *L);
extern int luaopen_crypto_core(lua_State *L);
extern int luaopen_term_core(lua_State *L);
extern int luaopen_wireguard(lua_State *L);

const luaL_Reg c_preload[] = {
    {"socket.core",   luaopen_socket_core  },
    {"socket.unix",   luaopen_socket_unix  },
    {"socket.serial", luaopen_socket_serial},
    {"mime.core",     luaopen_mime_core    },
    {"cjson",         luaopen_cjson        },
    {"cjson.safe",    luaopen_cjson_safe   },
    {"ssl.context",   luaopen_ssl_context  },
    {"ssl.core",      luaopen_ssl_core     },
    {"std.core",      luaopen_deviant_core },
    {"crypto.core",   luaopen_crypto_core  },
    {"term.core",     luaopen_term_core    },
    {"wireguard",     luaopen_wireguard    },
    {NULL,            NULL                 }
};