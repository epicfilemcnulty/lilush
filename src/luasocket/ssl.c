/*--------------------------------------------------------------------------
 * LuaSec 1.2.0
 *
 * Copyright (C) 2014-2022 Kim Alvefur, Paul Aurich, Tobias Markmann,
 *                         Matthew Wild.
 * Copyright (C) 2006-2022 Bruno Silvestre.
 *
 *--------------------------------------------------------------------------*/

#include <errno.h>
#include <string.h>

#include <lauxlib.h>
#include <lua.h>

#include "buffer.h"
#include "io.h"
#include "socket.h"
#include "timeout.h"
#include "usocket.h"

#include "context.h"
#include "ssl.h"

/**
 * Underline socket error.
 */
static int lsec_socket_error() {
    return errno;
}

/**
 * Map error code into string.
 */
static const char *ssl_ioerror(void *ctx, int err) {
    if (err == LSEC_IO_SSL) {
        p_ssl ssl = (p_ssl)ctx;
        switch (ssl->error) {
        case SSL_ERROR_NONE:
            return "No error";
        case SSL_ERROR_ZERO_RETURN:
            return "closed";
        case SSL_ERROR_WANT_READ:
            return "wantread";
        case SSL_ERROR_WANT_WRITE:
            return "wantwrite";
        case SSL_ERROR_WANT_CONNECT:
            return "'connect' not completed";
        case SSL_ERROR_WANT_ACCEPT:
            return "'accept' not completed";
        case SSL_ERROR_SYSCALL:
            return "System error";
        case SSL_ERROR_SSL:
            return "Uknown SSL error 2";
        default:
            return "Unknown SSL error";
        }
    }
    return socket_strerror(err);
}

static WOLFSSL_CTX *find_sni_context(sni_list *list, const char *name) {
    for (size_t i = 0; i < list->count; i++) {
        if (strcmp(list->entries[i].servername, name) == 0) {
            return list->entries[i].ctx;
        }
    }
    return NULL;
}

static WOLFSSL_CTX *check_client_sni(p_ssl ssl, const unsigned char *buffer, size_t len) {
    // If there are no additional SNI contexts, return NULL to use default context
    if (!ssl->sni_contexts || ssl->sni_contexts->count == 0) {
        return NULL;
    }
    if (len < 5) {
        return NULL; // Need at least TLS record header
    }
    // Check if it's a handshake message (type 22)
    if (buffer[0] != 0x16) {
        return NULL;
    }
    // Get ClientHello message length
    size_t msg_len = (buffer[3] << 8) | buffer[4];
    if (len < msg_len + 5) {
        return NULL;
    }
    // Check if it's indeed a ClientHello message (type 1)
    if (buffer[5] != 0x01) {
        return NULL;
    }
    char sni_name[256];
    unsigned int sni_size = sizeof(sni_name);

    int ret = wolfSSL_SNI_GetFromBuffer(buffer,
                                        msg_len + 5, // TLS Header length + ClientHello length
                                        WOLFSSL_SNI_HOST_NAME, (unsigned char *)sni_name, &sni_size);

    if (ret == WOLFSSL_SUCCESS && sni_size > 0) {
        sni_name[sni_size] = '\0';
        return find_sni_context(ssl->sni_contexts, sni_name);
    }

    return NULL;
}

/**
 * Close the connection before the GC collect the object.
 */
static int meth_destroy(lua_State *L) {
    p_ssl ssl = (p_ssl)luaL_checkudata(L, 1, "SSL:Connection");
    /* Fast teardown: avoid blocking shutdown on peers that disconnect abruptly. */
    if (ssl->sock != SOCKET_INVALID) {
        socket_destroy(&ssl->sock);
    }
    ssl->state = LSEC_STATE_CLOSED;
    if (ssl->ssl) {
        /* Destroy the object */
        wolfSSL_free(ssl->ssl);
        ssl->ssl = NULL;
    }
    // Free SNI contexts
    if (ssl->sni_contexts) {
        if (ssl->sni_contexts->entries) {
            for (size_t i = 0; i < ssl->sni_contexts->count; i++) {
                free((void *)ssl->sni_contexts->entries[i].servername);
            }
            free(ssl->sni_contexts->entries);
        }
        free(ssl->sni_contexts);
        ssl->sni_contexts = NULL;
    }
    return 0;
}

static int handshake(p_ssl ssl) {
    int err;
    p_timeout tm = timeout_markstart(&ssl->tm);
    if (ssl->state == LSEC_STATE_CLOSED)
        return IO_CLOSED;

    // For server mode with SNI contexts, wait for complete ClientHello FIRST
    if (ssl->mode == LSEC_MODE_SERVER && ssl->sni_contexts && ssl->sni_contexts->count > 0) {
        int prev_peek_len = 0;
        for (;;) {
            char peek_buf[16384];
            int peek_len = recv(ssl->sock, peek_buf, sizeof(peek_buf), MSG_PEEK);

            if (peek_len > 0) {
                // Not a TLS handshake record — skip SNI, let wolfSSL handle it
                if ((unsigned char)peek_buf[0] != 0x16) {
                    break;
                }
                if (peek_len >= 5) {
                    size_t msg_len = ((unsigned char)peek_buf[3] << 8) | (unsigned char)peek_buf[4];
                    if (peek_len >= (int)(msg_len + 5)) {
                        // Complete ClientHello available, check SNI and swap context
                        WOLFSSL_CTX *new_ctx = check_client_sni(ssl, (unsigned char *)peek_buf, peek_len);
                        if (new_ctx) {
                            WOLFSSL *new_ssl = wolfSSL_new(new_ctx);
                            if (new_ssl) {
                                wolfSSL_free(ssl->ssl);
                                ssl->ssl = new_ssl;
                                wolfSSL_set_fd(ssl->ssl, ssl->sock);
                            }
                        }
                        break; // Proceed to handshake
                    }
                }
                // No new data since last peek — peer likely closed
                if (peek_len == prev_peek_len) {
                    break;
                }
                prev_peek_len = peek_len;
            } else if (peek_len == 0) {
                return IO_CLOSED;
            } else if (errno != EAGAIN && errno != EWOULDBLOCK) {
                return IO_CLOSED;
            }

            // Wait for more data
            err = socket_waitfd(&ssl->sock, WAITFD_R, tm);
            if (err == IO_TIMEOUT)
                return LSEC_IO_SSL;
            if (err != IO_DONE)
                return err;
        }
    }

    // Main handshake loop
    for (;;) {
        if (ssl->mode == LSEC_MODE_SERVER) {
            err = wolfSSL_accept(ssl->ssl);
        } else {
            // we could do some checks here, e.g.:
            //
            // char* domain = (char*) “www.domain.com”;
            // ret = wolfSSL_check_domain_name(ssl, domain);
            // if (ret != SSL_SUCCESS) {
            //      failed to enable domain name check
            // }
            //
            // but this requires passing the domain name to the
            // handshake function somehow...
            err = wolfSSL_connect(ssl->ssl);
        }
        ssl->error = wolfSSL_get_error(ssl->ssl, err);
        switch (ssl->error) {
        case SSL_ERROR_NONE:
            ssl->state = LSEC_STATE_CONNECTED;
            return IO_DONE;
        case SSL_ERROR_WANT_READ:
            err = socket_waitfd(&ssl->sock, WAITFD_R, tm);
            if (err == IO_TIMEOUT)
                return LSEC_IO_SSL;
            if (err != IO_DONE)
                return err;
            break;
        case SSL_ERROR_WANT_WRITE:
            err = socket_waitfd(&ssl->sock, WAITFD_W, tm);
            if (err == IO_TIMEOUT)
                return LSEC_IO_SSL;
            if (err != IO_DONE)
                return err;
            break;
        case SSL_ERROR_SYSCALL: {
            if (err == 0)
                return IO_CLOSED;
            int sock_err = lsec_socket_error();
            if (sock_err == 0)
                return IO_CLOSED;
            return sock_err;
        }
        default:
            return LSEC_IO_SSL;
        }
    }
    return IO_UNKNOWN;
}

/**
 * Send data
 */
static int ssl_send(void *ctx, const char *data, size_t count, size_t *sent, p_timeout tm) {
    int err;
    p_ssl ssl = (p_ssl)ctx;
    if (ssl->state != LSEC_STATE_CONNECTED)
        return IO_CLOSED;
    *sent = 0;
    for (;;) {
        err        = wolfSSL_write(ssl->ssl, data, (int)count);
        ssl->error = wolfSSL_get_error(ssl->ssl, err);
        switch (ssl->error) {
        case SSL_ERROR_NONE:
            *sent = err;
            return IO_DONE;
        case SSL_ERROR_WANT_READ:
            err = socket_waitfd(&ssl->sock, WAITFD_R, tm);
            if (err == IO_TIMEOUT)
                return LSEC_IO_SSL;
            if (err != IO_DONE)
                return err;
            break;
        case SSL_ERROR_WANT_WRITE:
            err = socket_waitfd(&ssl->sock, WAITFD_W, tm);
            if (err == IO_TIMEOUT)
                return LSEC_IO_SSL;
            if (err != IO_DONE)
                return err;
            break;
        case SSL_ERROR_SYSCALL: {
            if (err == 0)
                return IO_CLOSED;
            int sock_err = lsec_socket_error();
            if (sock_err == 0)
                return IO_CLOSED;
            return sock_err;
        }
        default:
            return LSEC_IO_SSL;
        }
    }
    return IO_UNKNOWN;
}

/**
 * Receive data
 */
static int ssl_recv(void *ctx, char *data, size_t count, size_t *got, p_timeout tm) {
    int err;
    p_ssl ssl = (p_ssl)ctx;
    *got      = 0;
    if (ssl->state != LSEC_STATE_CONNECTED)
        return IO_CLOSED;
    for (;;) {
        err        = wolfSSL_read(ssl->ssl, data, (int)count);
        ssl->error = wolfSSL_get_error(ssl->ssl, err);
        switch (ssl->error) {
        case SSL_ERROR_NONE:
            *got = err;
            return IO_DONE;
        case SSL_ERROR_ZERO_RETURN:
            return IO_CLOSED;
        case SSL_ERROR_WANT_READ:
            err = socket_waitfd(&ssl->sock, WAITFD_R, tm);
            if (err == IO_TIMEOUT)
                return LSEC_IO_SSL;
            if (err != IO_DONE)
                return err;
            break;
        case SSL_ERROR_WANT_WRITE:
            err = socket_waitfd(&ssl->sock, WAITFD_W, tm);
            if (err == IO_TIMEOUT)
                return LSEC_IO_SSL;
            if (err != IO_DONE)
                return err;
            break;
        case SSL_ERROR_SYSCALL: {
            if (err == 0)
                return IO_CLOSED;
            int sock_err = lsec_socket_error();
            if (sock_err == 0)
                return IO_CLOSED;
            return sock_err;
        }
        default:
            return LSEC_IO_SSL;
        }
    }
    return IO_UNKNOWN;
}

static int debug_mode(lua_State *L) {

    int enable = lua_toboolean(L, 1);
    if (enable) {
        wolfSSL_Debugging_ON();
    } else {
        wolfSSL_Debugging_OFF();
    }
    lua_pushboolean(L, 1);
    return 1;
}

/**
 * Create a new TLS/SSL object and mark it as new.
 */
static int meth_create(lua_State *L) {
    p_ssl ssl;
    int mode;
    WOLFSSL_CTX *ctx;

    lua_settop(L, 1);

    ssl = (p_ssl)lua_newuserdata(L, sizeof(t_ssl));
    if (!ssl) {
        lua_pushnil(L);
        lua_pushstring(L, "error creating SSL object");
        return 2;
    }

    if ((ctx = lsec_testcontext(L, 1))) {
        mode = lsec_getmode(L, 1);
        if (mode == LSEC_MODE_INVALID) {
            lua_pushnil(L);
            lua_pushstring(L, "invalid mode");
            return 2;
        }
        ssl->ssl = wolfSSL_new(ctx);
        if (!ssl->ssl) {
            lua_pushnil(L);
            lua_pushfstring(L, "error creating SSL object (%s)", "uknown");
            return 2;
        }
        ssl->mode = mode;
    } else {
        return luaL_argerror(L, 1, "invalid context");
    }
    ssl->state = LSEC_STATE_NEW;
    wolfSSL_set_fd(ssl->ssl, (int)SOCKET_INVALID);

    // Initialize sni_contexts
    ssl->sni_contexts = malloc(sizeof(sni_list));
    if (!ssl->sni_contexts) {
        wolfSSL_free(ssl->ssl);
        lua_pushnil(L);
        lua_pushstring(L, "out of memory");
        return 2;
    }
    ssl->sni_contexts->entries = NULL;
    ssl->sni_contexts->count   = 0;

    io_init(&ssl->io, (p_send)ssl_send, (p_recv)ssl_recv, (p_error)ssl_ioerror, ssl);
    timeout_init(&ssl->tm, -1, -1);
    buffer_init(&ssl->buf, &ssl->io, &ssl->tm);

    luaL_getmetatable(L, "SSL:Connection");
    lua_setmetatable(L, -2);
    return 1;
}

static int meth_add_sni_context(lua_State *L) {
    p_ssl ssl              = (p_ssl)luaL_checkudata(L, 1, "SSL:Connection");
    const char *servername = luaL_checkstring(L, 2);
    WOLFSSL_CTX *ctx       = lsec_checkcontext(L, 3);

    if (!ssl->sni_contexts) {
        ssl->sni_contexts = malloc(sizeof(sni_list));
        if (!ssl->sni_contexts) {
            return luaL_error(L, "out of memory");
        }
        ssl->sni_contexts->entries = NULL;
        ssl->sni_contexts->count   = 0;
    }

    sni_list_entry *new_entries =
        realloc(ssl->sni_contexts->entries, (ssl->sni_contexts->count + 1) * sizeof(sni_list_entry));

    if (!new_entries) {
        return luaL_error(L, "out of memory");
    }

    ssl->sni_contexts->entries                                      = new_entries;
    ssl->sni_contexts->entries[ssl->sni_contexts->count].servername = strdup(servername);
    ssl->sni_contexts->entries[ssl->sni_contexts->count].ctx        = ctx;
    ssl->sni_contexts->count++;

    lua_pushboolean(L, 1);
    return 1;
}

/**
 * Lua handshake function.
 */
static int meth_handshake(lua_State *L) {
    int err;
    p_ssl ssl = (p_ssl)luaL_checkudata(L, 1, "SSL:Connection");
    err       = handshake(ssl);
    if (err == IO_DONE) {
        lua_pushboolean(L, 1);
        return 1;
    }
    lua_pushboolean(L, 0);
    lua_pushstring(L, ssl_ioerror((void *)ssl, err));
    return 2;
}

/**
 * Buffer send function
 */
static int meth_send(lua_State *L) {
    p_ssl ssl = (p_ssl)luaL_checkudata(L, 1, "SSL:Connection");
    return buffer_meth_send(L, &ssl->buf);
}

/**
 * Buffer receive function
 */
static int meth_receive(lua_State *L) {
    p_ssl ssl = (p_ssl)luaL_checkudata(L, 1, "SSL:Connection");
    return buffer_meth_receive(L, &ssl->buf);
}

/**
 * Get the buffer's statistics.
 */
static int meth_getstats(lua_State *L) {
    p_ssl ssl = (p_ssl)luaL_checkudata(L, 1, "SSL:Connection");
    return buffer_meth_getstats(L, &ssl->buf);
}

/**
 * Set the buffer's statistics.
 */
static int meth_setstats(lua_State *L) {
    p_ssl ssl = (p_ssl)luaL_checkudata(L, 1, "SSL:Connection");
    return buffer_meth_setstats(L, &ssl->buf);
}

/**
 * Select support methods
 */
static int meth_getfd(lua_State *L) {
    p_ssl ssl = (p_ssl)luaL_checkudata(L, 1, "SSL:Connection");
    lua_pushnumber(L, ssl->sock);
    return 1;
}

/**
 * Set the TLS/SSL file descriptor.
 * Call it *before* the handshake.
 */
static int meth_setfd(lua_State *L) {
    p_ssl ssl = (p_ssl)luaL_checkudata(L, 1, "SSL:Connection");
    if (ssl->state != LSEC_STATE_NEW)
        luaL_argerror(L, 1, "invalid SSL object state");
    ssl->sock = (t_socket)luaL_checkinteger(L, 2);
    socket_setnonblocking(&ssl->sock);
    int ret;
    ret = wolfSSL_set_fd(ssl->ssl, (int)ssl->sock);
    if (ret != SSL_SUCCESS) {
        luaL_argerror(L, 1, "Failed to WRAP");
    }
    ssl->state = LSEC_STATE_CONNECTED;
    return 0;
}

/**
 * Close the connection.
 */
static int meth_close(lua_State *L) {
    meth_destroy(L);
    return 0;
}

/**
 * Set timeout.
 */
static int meth_settimeout(lua_State *L) {
    p_ssl ssl = (p_ssl)luaL_checkudata(L, 1, "SSL:Connection");
    return timeout_meth_settimeout(L, &ssl->tm);
}

/**
 * Check if there is data in the buffer.
 */
static int meth_dirty(lua_State *L) {
    int res   = 0;
    p_ssl ssl = (p_ssl)luaL_checkudata(L, 1, "SSL:Connection");
    if (ssl->state != LSEC_STATE_CLOSED)
        res = !buffer_isempty(&ssl->buf) || wolfSSL_pending(ssl->ssl);
    lua_pushboolean(L, res);
    return 1;
}

/**
 * Return the state information about the SSL object.
 */
static int meth_want(lua_State *L) {
    p_ssl ssl = (p_ssl)luaL_checkudata(L, 1, "SSL:Connection");
    int code  = (ssl->state == LSEC_STATE_CLOSED) ? SSL_NOTHING : 2;
    if (wolfSSL_want_read(ssl->ssl))
        code = 3;
    switch (code) {
    case SSL_NOTHING:
        lua_pushstring(L, "nothing");
        break;
    case SSL_READING:
        lua_pushstring(L, "read");
        break;
    case SSL_WRITING:
        lua_pushstring(L, "write");
        break;
    }
    return 1;
}

/**
 * Object information -- tostring metamethod
 */
static int meth_tostring(lua_State *L) {
    p_ssl ssl = (p_ssl)luaL_checkudata(L, 1, "SSL:Connection");
    lua_pushfstring(L, "SSL connection: %p%s", ssl, ssl->state == LSEC_STATE_CLOSED ? " (closed)" : "");
    return 1;
}

/*---------------------------------------------------------------------------*/

/**
 * SSL methods
 */
static luaL_Reg methods[] = {
    {"close",           meth_close          },
    {"getfd",           meth_getfd          },
    {"getstats",        meth_getstats       },
    {"dohandshake",     meth_handshake      },
    {"setstats",        meth_setstats       },
    {"dirty",           meth_dirty          },
    {"receive",         meth_receive        },
    {"send",            meth_send           },
    {"add_sni_context", meth_add_sni_context},
    {"settimeout",      meth_settimeout     },
    {"want",            meth_want           },
    {NULL,              NULL                }
};

/**
 * SSL metamethods.
 */
static luaL_Reg meta[] = {
    {"__close",    meth_destroy },
    {"__gc",       meth_destroy },
    {"__tostring", meth_tostring},
    {NULL,         NULL         }
};

/**
 * SSL functions.
 */
static luaL_Reg funcs[] = {
    {"create",     meth_create},
    {"setfd",      meth_setfd },
    {"debug_mode", debug_mode },
    {NULL,         NULL       }
};

/**
 * Initialize modules.
 */
LSEC_API int luaopen_ssl_core(lua_State *L) {
    /* Initialize SSL */
    int ret;
    if ((ret = wolfSSL_Init()) != WOLFSSL_SUCCESS) {
        lua_pushstring(L, "unable to initialize SSL library");
        lua_error(L);
    }
    socket_open();
    /* Register the functions and tables */
    luaL_newmetatable(L, "SSL:Connection");
    luaL_setfuncs(L, meta, 0);

    luaL_newlib(L, methods);
    lua_setfield(L, -2, "__index");

    luaL_newlib(L, funcs);

    lua_pushstring(L, "SOCKET_INVALID");
    lua_pushinteger(L, SOCKET_INVALID);
    lua_rawset(L, -3);

    return 1;
}

//------------------------------------------------------------------------------
