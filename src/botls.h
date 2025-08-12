// SPDX-FileCopyrightText: © 2024 Vladimir Zorin <vladimir@deviant.guru>
// SPDX-License-Identifier: GPL-3.0-or-later

#define BOTLS_VERSION "0.5.8-8-g2acaeb8"

static const char START_BOTLS[] = "local botls = require('botls')\n"
                                  "local bot, err = botls.new()\n"
                                  "if not bot then print('failed to init "
                                  "BOTLS: ' .. tostring(err)) os.exit(-1) end\n"
                                  "bot:manage()\n";

typedef struct mod_lua {
    const char *const name;
    const char *const code;
    const size_t *const size;
} mod_lua__t;

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
#include "../build/luasocket/mod_lua_web_server.h"
// Std
#include "../build/std/mod_lua_std.conv.h"
#include "../build/std/mod_lua_std.fs.h"
#include "../build/std/mod_lua_std.h"
#include "../build/std/mod_lua_std.logger.h"
#include "../build/std/mod_lua_std.mime.h"
#include "../build/std/mod_lua_std.ps.h"
#include "../build/std/mod_lua_std.tbl.h"
#include "../build/std/mod_lua_std.txt.h"
#include "../build/std/mod_lua_std.utf.h"
// ACME
#include "../build/acme/mod_lua_acme.dns.vultr.h"
#include "../build/acme/mod_lua_acme.h"
#include "../build/acme/mod_lua_acme.http.reliw.h"
#include "../build/acme/mod_lua_acme.store.file.h"
// Crypto primitives from WolfSSL
#include "../build/crypto/mod_lua_crypto.h"
// BoTLS
#include "../build/botls/mod_lua_botls.h"

const mod_lua__t lua_preload[] = {
    {"socket",          mod_lua_socket,          &mod_lua_socket_SIZE         },
    {"socket.headers",  mod_lua_headers,         &mod_lua_headers_SIZE        },
    {"socket.http",     mod_lua_http,            &mod_lua_http_SIZE           },
    {"socket.url",      mod_lua_url,             &mod_lua_url_SIZE            },
    {"ssl",             mod_lua_ssl,             &mod_lua_ssl_SIZE            },
    {"ssl.https",       mod_lua_https,           &mod_lua_https_SIZE          },
    {"web",             mod_lua_web,             &mod_lua_web_SIZE            },
    {"web_server",      mod_lua_web_server,      &mod_lua_web_server_SIZE     },
    {"ltn12",           mod_lua_ltn12,           &mod_lua_ltn12_SIZE          },
    {"mime",            mod_lua_mime,            &mod_lua_mime_SIZE           },
    {"std",             mod_lua_std,             &mod_lua_std_SIZE            },
    {"std.fs",          mod_lua_std_fs,          &mod_lua_std_fs_SIZE         },
    {"std.ps",          mod_lua_std_ps,          &mod_lua_std_ps_SIZE         },
    {"std.txt",         mod_lua_std_txt,         &mod_lua_std_txt_SIZE        },
    {"std.tbl",         mod_lua_std_tbl,         &mod_lua_std_tbl_SIZE        },
    {"std.conv",        mod_lua_std_conv,        &mod_lua_std_conv_SIZE       },
    {"std.mime",        mod_lua_std_mime,        &mod_lua_std_mime_SIZE       },
    {"std.logger",      mod_lua_std_logger,      &mod_lua_std_logger_SIZE     },
    {"std.utf",         mod_lua_std_utf,         &mod_lua_std_utf_SIZE        },
    {"acme",            mod_lua_acme,            &mod_lua_acme_SIZE           },
    {"acme.dns.vultr",  mod_lua_acme_dns_vultr,  &mod_lua_acme_dns_vultr_SIZE },
    {"acme.http.reliw", mod_lua_acme_http_reliw, &mod_lua_acme_http_reliw_SIZE},
    {"acme.store.file", mod_lua_acme_store_file, &mod_lua_acme_store_file_SIZE},
    {"crypto",          mod_lua_crypto,          &mod_lua_crypto_SIZE         },
    {"botls",           mod_lua_botls,           &mod_lua_botls_SIZE          },
    {NULL,              NULL,                    NULL                         }
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
    {NULL,            NULL                 }
};
