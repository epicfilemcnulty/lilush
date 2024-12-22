// SPDX-FileCopyrightText: © 2024 Vladimir Zorin <vladimir@deviant.guru>
// SPDX-License-Identifier: GPL-3.0-or-later

#define RELIW_VERSION "0.5.6-27-gf01061b"

static const char START_RELIW[] = "local reliw = require('reliw')\n"
                                  "local reliw_srv, err = reliw.new()\n"
                                  "if not reliw_srv then print('failed to init "
                                  "RELIW: ' .. tostring(err)) os.exit(-1) end\n"
                                  "reliw_srv:run()\n";

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
// Djot
#include "../build/djot/mod_lua_djot.ast.h"
#include "../build/djot/mod_lua_djot.attributes.h"
#include "../build/djot/mod_lua_djot.block.h"
#include "../build/djot/mod_lua_djot.filter.h"
#include "../build/djot/mod_lua_djot.h"
#include "../build/djot/mod_lua_djot.html.h"
#include "../build/djot/mod_lua_djot.inline.h"
// Redis
#include "../build/redis/mod_lua_redis.h"
// Reliw
#include "../build/reliw/mod_lua_reliw.acme.h"
#include "../build/reliw/mod_lua_reliw.api.h"
#include "../build/reliw/mod_lua_reliw.auth.h"
#include "../build/reliw/mod_lua_reliw.h"
#include "../build/reliw/mod_lua_reliw.handle.h"
#include "../build/reliw/mod_lua_reliw.metrics.h"
#include "../build/reliw/mod_lua_reliw.proxy.h"
#include "../build/reliw/mod_lua_reliw.store.h"
#include "../build/reliw/mod_lua_reliw.templates.h"

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
    {"djot",            mod_lua_djot,            &mod_lua_djot_SIZE           },
    {"djot.ast",        mod_lua_djot_ast,        &mod_lua_djot_ast_SIZE       },
    {"djot.attributes", mod_lua_djot_attributes, &mod_lua_djot_attributes_SIZE},
    {"djot.block",      mod_lua_djot_block,      &mod_lua_djot_block_SIZE     },
    {"djot.filter",     mod_lua_djot_filter,     &mod_lua_djot_filter_SIZE    },
    {"djot.html",       mod_lua_djot_html,       &mod_lua_djot_html_SIZE      },
    {"djot.inline",     mod_lua_djot_inline,     &mod_lua_djot_inline_SIZE    },
    {"redis",           mod_lua_redis,           &mod_lua_redis_SIZE          },
    {"reliw",           mod_lua_reliw,           &mod_lua_reliw_SIZE          },
    {"reliw.api",       mod_lua_reliw_api,       &mod_lua_reliw_api_SIZE      },
    {"reliw.auth",      mod_lua_reliw_auth,      &mod_lua_reliw_auth_SIZE     },
    {"reliw.acme",      mod_lua_reliw_acme,      &mod_lua_reliw_acme_SIZE     },
    {"reliw.handle",    mod_lua_reliw_handle,    &mod_lua_reliw_handle_SIZE   },
    {"reliw.metrics",   mod_lua_reliw_metrics,   &mod_lua_reliw_metrics_SIZE  },
    {"reliw.store",     mod_lua_reliw_store,     &mod_lua_reliw_store_SIZE    },
    {"reliw.proxy",     mod_lua_reliw_proxy,     &mod_lua_reliw_proxy_SIZE    },
    {"reliw.templates", mod_lua_reliw_templates, &mod_lua_reliw_templates_SIZE},
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
