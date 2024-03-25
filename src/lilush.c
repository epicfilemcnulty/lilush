// SPDX-FileCopyrightText: © 2024 Vladimir Zorin <vladimir@deviant.guru>
// SPDX-License-Identifier: GPL-3.0-or-later
#include <assert.h>
#include <libgen.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "lilush.h"
#include <lauxlib.h>
#include <lua.h>
#include <lualib.h>

/*---------------------------------------------------------------
; Modules written in Lua.
; Generate them from Lua code with `luajit -b source.lua output.h`
; and include generated headers here
;---------------------------------------------------------------*/

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
// Deviant
#include "../build/std/mod_lua_std.h"
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
#include "../build/term/mod_lua_term.input.h"
#include "../build/term/mod_lua_term.legacy_input.h"
#include "../build/term/mod_lua_term.tss.h"
#include "../build/term/mod_lua_term.widgets.h"
// markdown
#include "../build/markdown/mod_lua_markdown.h"
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
// llm
#include "../build/llm/mod_lua_llm.anthropic.h"
#include "../build/llm/mod_lua_llm.general.h"
#include "../build/llm/mod_lua_llm.ggml.h"
#include "../build/llm/mod_lua_llm.h"
#include "../build/llm/mod_lua_llm.openai.h"
// shell
#include "../build/shell/mod_lua_shell.builtins.h"
#include "../build/shell/mod_lua_shell.completions.h"
#include "../build/shell/mod_lua_shell.completions.shell.h"
#include "../build/shell/mod_lua_shell.completions.sources.bin.h"
#include "../build/shell/mod_lua_shell.completions.sources.builtins.h"
#include "../build/shell/mod_lua_shell.completions.sources.cmds.h"
#include "../build/shell/mod_lua_shell.completions.sources.env.h"
#include "../build/shell/mod_lua_shell.completions.sources.fs.h"
#include "../build/shell/mod_lua_shell.h"
#include "../build/shell/mod_lua_shell.history.h"
#include "../build/shell/mod_lua_shell.input.h"
#include "../build/shell/mod_lua_shell.modes.llm.h"
#include "../build/shell/mod_lua_shell.modes.lua.h"
#include "../build/shell/mod_lua_shell.modes.shell.h"
#include "../build/shell/mod_lua_shell.prompts.llm.h"
#include "../build/shell/mod_lua_shell.prompts.lua.h"
#include "../build/shell/mod_lua_shell.prompts.shell.h"
#include "../build/shell/mod_lua_shell.storage.h"
#include "../build/shell/mod_lua_shell.theme.h"
#include "../build/shell/mod_lua_shell.utils.h"

const mod_lua__t lua_preload[] = {
    {"socket",                             mod_lua_socket,                             &mod_lua_socket_SIZE                      },
    {"socket.headers",                     mod_lua_headers,                            &mod_lua_headers_SIZE                     },
    {"socket.http",                        mod_lua_http,                               &mod_lua_http_SIZE                        },
    {"socket.url",                         mod_lua_url,                                &mod_lua_url_SIZE                         },
    {"ssl",                                mod_lua_ssl,                                &mod_lua_ssl_SIZE                         },
    {"ssl.https",                          mod_lua_https,                              &mod_lua_https_SIZE                       },
    {"web",                                mod_lua_web,                                &mod_lua_web_SIZE                         },
    {"ltn12",                              mod_lua_ltn12,                              &mod_lua_ltn12_SIZE                       },
    {"mime",                               mod_lua_mime,                               &mod_lua_mime_SIZE                        },
    {"std",                                mod_lua_std,                                &mod_lua_std_SIZE                         },
    {"argparser",                          mod_lua_argparser,                          &mod_lua_argparser_SIZE                   },
    {"crypto",                             mod_lua_crypto,                             &mod_lua_crypto_SIZE                      },
    {"term",                               mod_lua_term,                               &mod_lua_term_SIZE                        },
    {"text",                               mod_lua_text,                               &mod_lua_text_SIZE                        },
    {"term.widgets",                       mod_lua_term_widgets,                       &mod_lua_term_widgets_SIZE                },
    {"term.tss",                           mod_lua_term_tss,                           &mod_lua_term_tss_SIZE                    },
    {"term.input",                         mod_lua_term_input,                         &mod_lua_term_input_SIZE                  },
    {"term.legacy_input",                  mod_lua_term_legacy_input,                  &mod_lua_term_legacy_input_SIZE           },
    {"dns.resolver",                       mod_lua_dns_resolver,                       &mod_lua_dns_resolver_SIZE                },
    {"dns.parser",                         mod_lua_dns_parser,                         &mod_lua_dns_parser_SIZE                  },
    {"dns.dig",                            mod_lua_dns_dig,                            &mod_lua_dns_dig_SIZE                     },
    {"djot",                               mod_lua_djot,                               &mod_lua_djot_SIZE                        },
    {"djot.ast",                           mod_lua_djot_ast,                           &mod_lua_djot_ast_SIZE                    },
    {"djot.attributes",                    mod_lua_djot_attributes,                    &mod_lua_djot_attributes_SIZE             },
    {"djot.block",                         mod_lua_djot_block,                         &mod_lua_djot_block_SIZE                  },
    {"djot.filter",                        mod_lua_djot_filter,                        &mod_lua_djot_filter_SIZE                 },
    {"djot.html",                          mod_lua_djot_html,                          &mod_lua_djot_html_SIZE                   },
    {"djot.inline",                        mod_lua_djot_inline,                        &mod_lua_djot_inline_SIZE                 },
    {"redis",                              mod_lua_redis,                              &mod_lua_redis_SIZE                       },
    {"llm",                                mod_lua_llm,                                &mod_lua_llm_SIZE                         },
    {"llm.openai",                         mod_lua_llm_openai,                         &mod_lua_llm_openai_SIZE                  },
    {"llm.anthropic",                      mod_lua_llm_anthropic,                      &mod_lua_llm_anthropic_SIZE               },
    {"llm.ggml",                           mod_lua_llm_ggml,                           &mod_lua_llm_ggml_SIZE                    },
    {"llm.general",                        mod_lua_llm_general,                        &mod_lua_llm_general_SIZE                 },
    {"markdown",                           mod_lua_markdown,                           &mod_lua_markdown_SIZE                    },
    {"shell",                              mod_lua_shell,                              &mod_lua_shell_SIZE                       },
    {"shell.input",                        mod_lua_shell_input,                        &mod_lua_shell_input_SIZE                 },
    {"shell.theme",                        mod_lua_shell_theme,                        &mod_lua_shell_theme_SIZE                 },
    {"shell.builtins",                     mod_lua_shell_builtins,                     &mod_lua_shell_builtins_SIZE              },
    {"shell.utils",                        mod_lua_shell_utils,                        &mod_lua_shell_utils_SIZE                 },
    {"shell.storage",                      mod_lua_shell_storage,                      &mod_lua_shell_storage_SIZE               },
    {"shell.history",                      mod_lua_shell_history,                      &mod_lua_shell_history_SIZE               },
    {"shell.completions",                  mod_lua_shell_completions,                  &mod_lua_shell_completions_SIZE           },
    {"shell.completions.shell",            mod_lua_shell_completions_shell,            &mod_lua_shell_completions_shell_SIZE     },
    {"shell.completions.sources.fs",       mod_lua_shell_completions_sources_fs,       &mod_lua_shell_completions_sources_fs_SIZE},
    {"shell.completions.sources.bin",      mod_lua_shell_completions_sources_bin,
     &mod_lua_shell_completions_sources_bin_SIZE                                                                                 },
    {"shell.completions.sources.builtins", mod_lua_shell_completions_sources_builtins,
     &mod_lua_shell_completions_sources_builtins_SIZE                                                                            },
    {"shell.completions.sources.env",      mod_lua_shell_completions_sources_env,
     &mod_lua_shell_completions_sources_env_SIZE                                                                                 },
    {"shell.completions.sources.cmds",     mod_lua_shell_completions_sources_cmds,
     &mod_lua_shell_completions_sources_cmds_SIZE                                                                                },
    {"shell.modes.shell",                  mod_lua_shell_modes_shell,                  &mod_lua_shell_modes_shell_SIZE           },
    {"shell.modes.lua",                    mod_lua_shell_modes_lua,                    &mod_lua_shell_modes_lua_SIZE             },
    {"shell.modes.llm",                    mod_lua_shell_modes_llm,                    &mod_lua_shell_modes_llm_SIZE             },
    {"shell.prompts.shell",                mod_lua_shell_prompts_shell,                &mod_lua_shell_prompts_shell_SIZE         },
    {"shell.prompts.lua",                  mod_lua_shell_prompts_lua,                  &mod_lua_shell_prompts_lua_SIZE           },
    {"shell.prompts.llm",                  mod_lua_shell_prompts_llm,                  &mod_lua_shell_prompts_llm_SIZE           },
    {NULL,                                 NULL,                                       NULL                                      }
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

void preload_modules(lua_State *const L) {
    assert(L != NULL);

    lua_gc(L, LUA_GCSTOP, 0);
    luaL_openlibs(L);
    lua_gc(L, LUA_GCRESTART, 0);

    lua_getglobal(L, "package");
    lua_getfield(L, -1, "preload");

    luaL_register(L, NULL, c_preload);

    for (size_t i = 0; lua_preload[i].name != NULL; i++) {
        int rc = luaL_loadbuffer(L, lua_preload[i].code, *lua_preload[i].size, lua_preload[i].name);
        if (rc != 0) {
            const char *err;

            switch (rc) {
            case LUA_ERRRUN:
                err = "runtime error";
                break;
            case LUA_ERRSYNTAX:
                err = "syntax error";
                break;
            case LUA_ERRMEM:
                err = "memory error";
                break;
            case LUA_ERRERR:
                err = "generic error";
                break;
            case LUA_ERRFILE:
                err = "file error";
                break;
            default:
                err = "unknown error";
                break;
            }

            fprintf(stderr, "%s: %s\n", lua_preload[i].name, err);
            exit(EXIT_FAILURE);
        }
        lua_setfield(L, -2, lua_preload[i].name);
    }
}

int main(int argc, char **argv) {
    int error;
    lua_State *L = luaL_newstate();
    preload_modules(L);

    char *cmd = basename(argv[0]);
    if (strcmp(cmd, "lilush") != 0 && strcmp(cmd, "-lilush") != 0) {
        lua_pushstring(L, cmd);
        lua_setglobal(L, "cmd");
        int args = argc - 1;
        lua_createtable(L, args, args);
        int i;
        for (i = 1; i < argc; i++) {
            lua_pushstring(L, argv[i]);
            lua_rawseti(L, -2, i);
        }
        lua_setglobal(L, "arg");
        error = luaL_dostring(L, EXEC_BUILTIN);
        if (error) {
            fprintf(stderr, "Error: %s\n", lua_tostring(L, -1));
            return 1;
        }
        return 0;
    }
    if (argc < 2) {
        error = luaL_dostring(L, START_SHELL);
        if (error) {
            fprintf(stderr, "Error: %s\n", lua_tostring(L, -1));
            return 1;
        }
        return 0;
    }

    if (strcmp(argv[1], "-c") == 0) {
        int args = argc - 2;
        lua_createtable(L, args, args);
        int i;
        for (i = 2; i < argc; i++) {
            lua_pushstring(L, argv[i]);
            lua_rawseti(L, -2, i - 1);
        }
        lua_setglobal(L, "arg");
        error = luaL_dostring(L, START_MINI_SHELL);
        if (error) {
            fprintf(stderr, "Error: %s\n", lua_tostring(L, -1));
            return 1;
        }
        return 0;
    }
    if (strcmp(argv[1], "-v") == 0) {
        fprintf(stdout, "version %s\n", LILUSH_VERSION);
        return 0;
    }

    if (!(access(argv[1], F_OK) == 0)) {
        fprintf(stderr, "File %s does not exist!\n", argv[1]);
        fprintf(stderr, "Usage: %s /path/to/a/script.lua\n", argv[0]);
        return 1;
    }

    // Let's load it by default and make it global
    error = luaL_dostring(L, PRELOAD_INIT);
    if (error) {
        fprintf(stderr, "Error: %s\n", lua_tostring(L, -1));
        return 1;
    }

    int args = argc - 2;
    lua_createtable(L, args, args);
    int i;
    for (i = 2; i < argc; i++) {
        lua_pushstring(L, argv[i]);
        lua_rawseti(L, -2, i - 1);
    }
    lua_setglobal(L, "arg");

    error = luaL_dofile(L, argv[1]);
    if (error) {
        fprintf(stderr, "Error: %s\n", lua_tostring(L, -1));
        return 1;
    }
    return 0;
}
