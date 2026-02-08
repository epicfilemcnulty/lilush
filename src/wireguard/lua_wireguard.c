// SPDX-FileCopyrightText: © 2022—2026 Vladimir Zorin <vladimir@deviant.guru>
// SPDX-License-Identifier: LicenseRef-OWL-1.0-or-later OR GPL-3.0-or-later
// Dual-licensed under OWL v1.0+ and GPLv3+. See LICENSE and LICENSE-GPL3.

#include "wireguard.h"
#include <arpa/inet.h>
#include <lauxlib.h>
#include <linux/if.h>
#include <linux/netlink.h>
#include <linux/route.h>
#include <linux/rtnetlink.h>
#include <lua.h>
#include <net/if.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <unistd.h>

#define RETURN_CUSTOM_ERR(L, msg) \
    do {                          \
        lua_pushnil(L);           \
        lua_pushstring(L, msg);   \
        return 2;                 \
    } while (0)

int lua_set_interface_up(lua_State *L) {
    const char *ifname = luaL_checkstring(L, 1);

    int sockfd = socket(AF_INET, SOCK_DGRAM, 0);
    if (sockfd < 0) {
        RETURN_CUSTOM_ERR(L, "Failed to create socket");
    }

    struct ifreq ifr;
    strncpy(ifr.ifr_name, ifname, IFNAMSIZ - 1);
    ifr.ifr_name[IFNAMSIZ - 1] = '\0';

    if (ioctl(sockfd, SIOCGIFFLAGS, &ifr) < 0) {
        close(sockfd);
        RETURN_CUSTOM_ERR(L, "Failed to get interface flags");
    }

    ifr.ifr_flags |= IFF_UP;

    if (ioctl(sockfd, SIOCSIFFLAGS, &ifr) < 0) {
        close(sockfd);
        RETURN_CUSTOM_ERR(L, "Failed to set interface flags");
    }

    close(sockfd);
    lua_pushboolean(L, 1);
    return 1;
}

int lua_add_ipv4_address(lua_State *L) {
    const char *ifname = luaL_checkstring(L, 1);
    const char *ipaddr = luaL_checkstring(L, 2);
    int prefix_len     = luaL_checkinteger(L, 3);

    struct ifreq ifr;
    struct sockaddr_in *addr = (struct sockaddr_in *)&ifr.ifr_addr;

    int sockfd = socket(AF_INET, SOCK_DGRAM, 0);
    if (sockfd < 0) {
        RETURN_CUSTOM_ERR(L, "Failed to create socket");
    }

    memset(&ifr, 0, sizeof(ifr));
    strncpy(ifr.ifr_name, ifname, IFNAMSIZ - 1);

    addr->sin_family      = AF_INET;
    addr->sin_addr.s_addr = inet_addr(ipaddr);

    if (ioctl(sockfd, SIOCSIFADDR, &ifr) < 0) {
        close(sockfd);
        RETURN_CUSTOM_ERR(L, "Failed to set the address");
    }

    ((struct sockaddr_in *)&ifr.ifr_netmask)->sin_addr.s_addr = htonl(~((1 << (32 - prefix_len)) - 1));

    if (ioctl(sockfd, SIOCSIFNETMASK, &ifr) < 0) {
        close(sockfd);
        RETURN_CUSTOM_ERR(L, "Failed to set the address");
    }
    close(sockfd);
    lua_pushboolean(L, 1);
    return 1;
}

#define NLMSG_TAIL(nmsg) ((struct rtattr *)(((void *)(nmsg)) + NLMSG_ALIGN((nmsg)->nlmsg_len)))

int addattr_l(struct nlmsghdr *n, int maxlen, int type, const void *data, int alen) {
    int len = RTA_LENGTH(alen);
    struct rtattr *rta;

    if (NLMSG_ALIGN(n->nlmsg_len) + RTA_ALIGN(len) > maxlen) {
        fprintf(stderr, "addattr_l ERROR: message exceeded bound of %d\n", maxlen);
        return -1;
    }

    rta           = NLMSG_TAIL(n);
    rta->rta_type = type;
    rta->rta_len  = len;
    memcpy(RTA_DATA(rta), data, alen);
    n->nlmsg_len = NLMSG_ALIGN(n->nlmsg_len) + RTA_ALIGN(len);
    return 0;
}

int addattr32(struct nlmsghdr *n, int maxlen, int type, int data) {
    int len = RTA_LENGTH(4);
    struct rtattr *rta;

    if (NLMSG_ALIGN(n->nlmsg_len) + len > maxlen) {
        fprintf(stderr, "addattr32: Error! max allowed bound %d exceeded\n", maxlen);
        return -1;
    }

    rta           = NLMSG_TAIL(n);
    rta->rta_type = type;
    rta->rta_len  = len;
    memcpy(RTA_DATA(rta), &data, 4);
    n->nlmsg_len = NLMSG_ALIGN(n->nlmsg_len) + len;
    return 0;
}

int lua_add_network_route(lua_State *L) {
    const char *dest   = luaL_checkstring(L, 1);
    int prefix_len     = luaL_checkinteger(L, 2);
    const char *ifname = luaL_checkstring(L, 3);
    int scope          = luaL_optinteger(L, 4, 0);
    const char *gw     = luaL_optstring(L, 5, NULL);

    struct {
        struct nlmsghdr nl;
        struct rtmsg rt;
        char buf[1024];
    } req;

    memset(&req, 0, sizeof(req));

    req.nl.nlmsg_len   = NLMSG_LENGTH(sizeof(struct rtmsg));
    req.nl.nlmsg_flags = NLM_F_REQUEST | NLM_F_CREATE | NLM_F_EXCL;
    req.nl.nlmsg_type  = RTM_NEWROUTE;

    req.rt.rtm_family   = AF_INET;
    req.rt.rtm_table    = RT_TABLE_MAIN;
    req.rt.rtm_protocol = RTPROT_BOOT;
    req.rt.rtm_scope    = scope;
    req.rt.rtm_type     = RTN_UNICAST;
    req.rt.rtm_dst_len  = prefix_len;

    struct sockaddr_in sin;
    sin.sin_family = AF_INET;
    inet_pton(AF_INET, dest, &sin.sin_addr);
    addattr_l(&req.nl, sizeof(req), RTA_DST, &sin.sin_addr, 4);

    int ifindex = if_nametoindex(ifname);
    if (ifindex == 0) {
        RETURN_CUSTOM_ERR(L, "Invalid interface name");
    }
    addattr32(&req.nl, sizeof(req), RTA_OIF, ifindex);

    if (gw) {
        inet_pton(AF_INET, gw, &sin.sin_addr);
        addattr_l(&req.nl, sizeof(req), RTA_GATEWAY, &sin.sin_addr, 4);
    }

    int sockfd = socket(AF_NETLINK, SOCK_RAW, NETLINK_ROUTE);
    if (sockfd < 0) {
        RETURN_CUSTOM_ERR(L, "Failed to create socket");
    }

    struct sockaddr_nl addr;
    memset(&addr, 0, sizeof(addr));
    addr.nl_family = AF_NETLINK;

    if (sendto(sockfd, &req, req.nl.nlmsg_len, 0, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        close(sockfd);
        RETURN_CUSTOM_ERR(L, "Failed to send netlink message");
    }

    close(sockfd);
    lua_pushboolean(L, 1);
    return 1;
}

int lua_wg_list_devices(lua_State *L) {
    char *device_names, *device_name;
    size_t len;

    device_names = wg_list_device_names();
    if (!device_names) {
        RETURN_CUSTOM_ERR(L, "Failed to get device names");
    }
    lua_newtable(L);
    int i = 1;
    wg_for_each_device_name(device_names, device_name, len) {
        lua_pushinteger(L, i);
        lua_pushstring(L, device_name);
        lua_settable(L, -3);
        i++;
    }
    free(device_names);
    return 1;
}

int lua_wg_add_device(lua_State *L) {
    const char *device_name = luaL_checkstring(L, 1);
    int result              = wg_add_device(device_name);
    if (result < 0) {
        RETURN_CUSTOM_ERR(L, "Failed to add device");
    }
    lua_pushboolean(L, 1);
    return 1;
}

int lua_wg_del_device(lua_State *L) {
    const char *device_name = luaL_checkstring(L, 1);
    int result              = wg_del_device(device_name);
    if (result < 0) {
        RETURN_CUSTOM_ERR(L, "Failed to delete device");
    }
    lua_pushboolean(L, 1);
    return 1;
}

// Helper function to convert a wg_allowedip struct to a Lua table
static int push_allowedip(lua_State *L, const wg_allowedip *allowedip) {
    lua_newtable(L);
    lua_pushinteger(L, allowedip->family);
    lua_setfield(L, -2, "family");

    if (allowedip->family == AF_INET) {
        char ip4_str[INET_ADDRSTRLEN];
        inet_ntop(AF_INET, &allowedip->ip4, ip4_str, sizeof(ip4_str));
        lua_pushstring(L, ip4_str);
        lua_setfield(L, -2, "ip");
    } else if (allowedip->family == AF_INET6) {
        char ip6_str[INET6_ADDRSTRLEN];
        inet_ntop(AF_INET6, &allowedip->ip6, ip6_str, sizeof(ip6_str));
        lua_pushstring(L, ip6_str);
        lua_setfield(L, -2, "ip");
    }

    lua_pushinteger(L, allowedip->cidr);
    lua_setfield(L, -2, "cidr");
    return 1;
}

// Helper function to convert a wg_peer struct to a Lua table
static int push_peer(lua_State *L, const wg_peer *peer) {
    lua_newtable(L);

    lua_pushboolean(L, peer->flags & WGPEER_REMOVE_ME);
    lua_setfield(L, -2, "remove_me");

    lua_pushboolean(L, peer->flags & WGPEER_REPLACE_ALLOWEDIPS);
    lua_setfield(L, -2, "replace_allowedips");

    if (peer->flags & WGPEER_HAS_PUBLIC_KEY) {
        wg_key_b64_string key_str;
        wg_key_to_base64(key_str, peer->public_key);
        lua_pushstring(L, key_str);
        lua_setfield(L, -2, "public_key");
    }
    if (peer->flags & WGPEER_HAS_PRESHARED_KEY) {
        wg_key_b64_string key_str;
        wg_key_to_base64(key_str, peer->preshared_key);
        lua_pushstring(L, key_str);
        lua_setfield(L, -2, "preshared_key");
    }

    // Push endpoint
    lua_newtable(L);
    if (peer->endpoint.addr.sa_family == AF_INET) {
        char ip4_str[INET_ADDRSTRLEN];
        inet_ntop(AF_INET, &peer->endpoint.addr4.sin_addr, ip4_str, sizeof(ip4_str));
        lua_pushstring(L, ip4_str);
        lua_setfield(L, -2, "ip");
        lua_pushinteger(L, ntohs(peer->endpoint.addr4.sin_port));
        lua_setfield(L, -2, "port");
    } else if (peer->endpoint.addr.sa_family == AF_INET6) {
        char ip6_str[INET6_ADDRSTRLEN];
        inet_ntop(AF_INET6, &peer->endpoint.addr6.sin6_addr, ip6_str, sizeof(ip6_str));
        lua_pushstring(L, ip6_str);
        lua_setfield(L, -2, "ip");
        lua_pushinteger(L, ntohs(peer->endpoint.addr6.sin6_port));
        lua_setfield(L, -2, "port");
    }
    lua_setfield(L, -2, "endpoint");

    lua_pushinteger(L, peer->last_handshake_time.tv_sec);
    lua_setfield(L, -2, "last_handshake_time_sec");
    lua_pushinteger(L, peer->last_handshake_time.tv_nsec);
    lua_setfield(L, -2, "last_handshake_time_nsec");

    lua_pushinteger(L, peer->rx_bytes);
    lua_setfield(L, -2, "rx_bytes");
    lua_pushinteger(L, peer->tx_bytes);
    lua_setfield(L, -2, "tx_bytes");

    lua_pushinteger(L, peer->persistent_keepalive_interval);
    lua_setfield(L, -2, "persistent_keepalive_interval");

    // Push allowed IPs
    lua_newtable(L);
    int allowedip_index     = 1;
    wg_allowedip *allowedip = peer->first_allowedip;
    while (allowedip) {
        lua_pushinteger(L, allowedip_index);
        push_allowedip(L, allowedip);
        lua_settable(L, -3);
        allowedip_index++;
        allowedip = allowedip->next_allowedip;
    }
    lua_setfield(L, -2, "allowed_ips");

    return 1;
}

int lua_wg_set_device(lua_State *L) {
    if (!lua_istable(L, 1)) {
        RETURN_CUSTOM_ERR(L, "Expected a table as the first argument");
    }

    // Allocate a wg_device struct
    wg_device *dev = (wg_device *)malloc(sizeof(wg_device));
    if (!dev) {
        RETURN_CUSTOM_ERR(L, "Failed to allocate memory for wg_device");
    }
    // Initialize the wg_device struct with default values
    memset(dev, 0, sizeof(wg_device));

    // Get the device name from the Lua table
    lua_getfield(L, 1, "name");
    const char *name = lua_tostring(L, -1);
    if (!name) {
        RETURN_CUSTOM_ERR(L, "Device name is missing or invalid");
    }
    strncpy(dev->name, name, IFNAMSIZ - 1);
    dev->name[IFNAMSIZ - 1] = '\0';
    lua_pop(L, 1);

    // Get the flags from the Lua table
    lua_getfield(L, 1, "flags");
    if (lua_isnil(L, -1)) {
        // No flags specified, use default
        dev->flags = 0;
    } else {
        dev->flags = lua_tointeger(L, -1);
    }
    lua_pop(L, 1);

    lua_getfield(L, 1, "public_key");
    if (!lua_isnil(L, -1)) {
        const char *public_key_str = lua_tostring(L, -1);
        if (wg_key_from_base64(dev->public_key, public_key_str) < 0) {
            RETURN_CUSTOM_ERR(L, "Invalid public key1");
        }
        dev->flags |= WGDEVICE_HAS_PUBLIC_KEY;
    }
    lua_pop(L, 1);

    lua_getfield(L, 1, "private_key");
    if (!lua_isnil(L, -1)) {
        const char *private_key_str = lua_tostring(L, -1);
        if (wg_key_from_base64(dev->private_key, private_key_str) < 0) {
            RETURN_CUSTOM_ERR(L, "Invalid private key");
        }
        dev->flags |= WGDEVICE_HAS_PRIVATE_KEY;
    }
    lua_pop(L, 1);

    lua_getfield(L, 1, "listen_port");
    if (!lua_isnil(L, -1)) {
        dev->listen_port = lua_tointeger(L, -1);
        dev->flags |= WGDEVICE_HAS_LISTEN_PORT;
    }
    lua_pop(L, 1);

    lua_getfield(L, 1, "fwmark");
    if (!lua_isnil(L, -1)) {
        dev->fwmark = lua_tointeger(L, -1);
        dev->flags |= WGDEVICE_HAS_FWMARK;
    }
    lua_pop(L, 1);

    lua_getfield(L, 1, "peers");
    if (!lua_isnil(L, -1)) {
        if (!lua_istable(L, -1)) {
            RETURN_CUSTOM_ERR(L, "Peers must be a table");
        }
        // Iterate over the peers table
        lua_pushnil(L);
        while (lua_next(L, -2) != 0) {
            // Check if the value is a table
            if (!lua_istable(L, -1)) {
                RETURN_CUSTOM_ERR(L, "Each peer must be a table");
            }
            // Allocate a new wg_peer struct
            wg_peer *peer = (wg_peer *)malloc(sizeof(wg_peer));
            if (!peer) {
                RETURN_CUSTOM_ERR(L, "Failed to allocate memory for wg_peer");
            }
            memset(peer, 0, sizeof(wg_peer));
            // Parse the peer table and populate the wg_peer struct
            lua_getfield(L, -1, "remove_me");
            if (!lua_isnil(L, -1)) {
                peer->flags |= WGPEER_REMOVE_ME * lua_toboolean(L, -1);
            }
            lua_pop(L, 1);

            lua_getfield(L, -1, "replace_allowedips");
            if (!lua_isnil(L, -1)) {
                peer->flags |= WGPEER_REPLACE_ALLOWEDIPS * lua_toboolean(L, -1);
            }
            lua_pop(L, 1);

            lua_getfield(L, -1, "public_key");
            if (!lua_isnil(L, -1)) {
                const char *public_key_str = lua_tostring(L, -1);
                if (wg_key_from_base64(peer->public_key, public_key_str) < 0) {
                    RETURN_CUSTOM_ERR(L, "Invalid public key");
                }
                peer->flags |= WGPEER_HAS_PUBLIC_KEY;
            }
            lua_pop(L, 1);

            lua_getfield(L, -1, "preshared_key");
            if (!lua_isnil(L, -1)) {
                const char *preshared_key_str = lua_tostring(L, -1);
                if (wg_key_from_base64(peer->preshared_key, preshared_key_str) < 0) {
                    RETURN_CUSTOM_ERR(L, "Invalid preshared key");
                }
                peer->flags |= WGPEER_HAS_PRESHARED_KEY;
            }
            lua_pop(L, 1);

            lua_getfield(L, -1, "endpoint");
            if (!lua_isnil(L, -1)) {
                if (!lua_istable(L, -1)) {
                    RETURN_CUSTOM_ERR(L, "Endpoint must be a table");
                }

                lua_getfield(L, -1, "ip");
                const char *ip_str = lua_tostring(L, -1);
                if (!ip_str) {
                    RETURN_CUSTOM_ERR(L, "Endpoint IP is missing or invalid");
                }
                if (inet_pton(AF_INET, ip_str, &peer->endpoint.addr4.sin_addr) == 1) {
                    peer->endpoint.addr.sa_family = AF_INET;
                } else if (inet_pton(AF_INET6, ip_str, &peer->endpoint.addr6.sin6_addr) == 1) {
                    peer->endpoint.addr.sa_family = AF_INET6;
                } else {
                    RETURN_CUSTOM_ERR(L, "Invalid endpoint IP address");
                }
                lua_pop(L, 1);

                lua_getfield(L, -1, "port");
                if (!lua_isnil(L, -1)) {
                    uint16_t port = lua_tointeger(L, -1);
                    if (peer->endpoint.addr.sa_family == AF_INET) {
                        peer->endpoint.addr4.sin_port = htons(port);
                    } else if (peer->endpoint.addr.sa_family == AF_INET6) {
                        peer->endpoint.addr6.sin6_port = htons(port);
                    }
                }
                lua_pop(L, 1);
            }
            lua_pop(L, 1);

            lua_getfield(L, -1, "last_handshake_time_sec");
            if (!lua_isnil(L, -1)) {
                peer->last_handshake_time.tv_sec = lua_tointeger(L, -1);
            }
            lua_pop(L, 1);

            lua_getfield(L, -1, "last_handshake_time_nsec");
            if (!lua_isnil(L, -1)) {
                peer->last_handshake_time.tv_nsec = lua_tointeger(L, -1);
            }
            lua_pop(L, 1);

            lua_getfield(L, -1, "rx_bytes");
            if (!lua_isnil(L, -1)) {
                peer->rx_bytes = lua_tointeger(L, -1);
            }
            lua_pop(L, 1);

            lua_getfield(L, -1, "tx_bytes");
            if (!lua_isnil(L, -1)) {
                peer->tx_bytes = lua_tointeger(L, -1);
            }
            lua_pop(L, 1);

            lua_getfield(L, -1, "persistent_keepalive_interval");
            if (!lua_isnil(L, -1)) {
                peer->persistent_keepalive_interval = lua_tointeger(L, -1);
                peer->flags |= WGPEER_HAS_PERSISTENT_KEEPALIVE_INTERVAL;
            }
            lua_pop(L, 1);

            lua_getfield(L, -1, "allowed_ips");
            if (!lua_isnil(L, -1)) {
                if (!lua_istable(L, -1)) {
                    RETURN_CUSTOM_ERR(L, "Allowed IPs must be a table");
                }

                lua_pushnil(L);
                while (lua_next(L, -2) != 0) {
                    if (!lua_istable(L, -1)) {
                        RETURN_CUSTOM_ERR(L, "Each allowed IP must be a table");
                    }

                    wg_allowedip *allowedip = (wg_allowedip *)malloc(sizeof(wg_allowedip));
                    if (!allowedip) {
                        RETURN_CUSTOM_ERR(L, "Failed to allocate memory for wg_allowedip");
                    }
                    memset(allowedip, 0, sizeof(wg_allowedip));

                    lua_getfield(L, -1, "family");
                    if (!lua_isnil(L, -1)) {
                        allowedip->family = lua_tointeger(L, -1);
                    }
                    lua_pop(L, 1);

                    lua_getfield(L, -1, "ip");
                    const char *ip_str = lua_tostring(L, -1);
                    if (ip_str) {
                        if (allowedip->family == AF_INET) {
                            if (inet_pton(AF_INET, ip_str, &allowedip->ip4) != 1) {
                                RETURN_CUSTOM_ERR(L, "Invalid IPv4 address");
                            }
                        } else if (allowedip->family == AF_INET6) {
                            if (inet_pton(AF_INET6, ip_str, &allowedip->ip6) != 1) {
                                RETURN_CUSTOM_ERR(L, "Invalid IPv6 address");
                            }
                        }
                    }
                    lua_pop(L, 1);

                    lua_getfield(L, -1, "cidr");
                    if (!lua_isnil(L, -1)) {
                        allowedip->cidr = lua_tointeger(L, -1);
                    }
                    lua_pop(L, 1);

                    if (!peer->first_allowedip) {
                        peer->first_allowedip = allowedip;
                    } else {
                        peer->last_allowedip->next_allowedip = allowedip;
                    }
                    peer->last_allowedip = allowedip;

                    lua_pop(L, 1);
                }
            }
            lua_pop(L, 1);

            // Add the peer to the linked list
            if (!dev->first_peer) {
                dev->first_peer = peer;
            } else {
                dev->last_peer->next_peer = peer;
            }
            dev->last_peer = peer;

            lua_pop(L, 1);
        }

        dev->flags |= WGDEVICE_REPLACE_PEERS;
    }
    lua_pop(L, 1);

    // Call wg_set_device
    int result = wg_set_device(dev);
    // Free the wg_device struct and its peers
    wg_free_device(dev);

    if (result < 0) {
        RETURN_CUSTOM_ERR(L, "Failed to set device");
    }
    lua_pushboolean(L, 1);
    return 1;
}

int lua_wg_generate_public_key(lua_State *L) {
    size_t private_key_len;
    const char *private_key_str = luaL_checklstring(L, 1, &private_key_len);
    if (private_key_len != sizeof(wg_key)) {
        RETURN_CUSTOM_ERR(L, "Invalid private key length");
    }

    wg_key private_key, public_key;
    memcpy(private_key, private_key_str, sizeof(wg_key));
    wg_generate_public_key(public_key, private_key);

    lua_pushlstring(L, (const char *)public_key, sizeof(wg_key));
    return 1;
}

int lua_wg_generate_private_key(lua_State *L) {
    wg_key private_key;
    wg_generate_private_key(private_key);

    lua_pushlstring(L, (const char *)private_key, sizeof(wg_key));
    return 1;
}

int lua_wg_key_from_base64(lua_State *L) {
    const char *base64_key = luaL_checkstring(L, 1);
    wg_key key;
    int result = wg_key_from_base64(key, base64_key);
    if (result != 0) {
        RETURN_CUSTOM_ERR(L, "Failed to decode base64 key");
    }

    lua_pushlstring(L, (const char *)key, sizeof(wg_key));
    return 1;
}

int lua_wg_key_to_base64(lua_State *L) {
    size_t key_len;
    const char *key_str = luaL_checklstring(L, 1, &key_len);
    if (key_len != sizeof(wg_key)) {
        RETURN_CUSTOM_ERR(L, "Invalid key length");
    }

    wg_key key;
    memcpy(key, key_str, sizeof(wg_key));
    wg_key_b64_string base64_key;
    wg_key_to_base64(base64_key, key);

    lua_pushstring(L, base64_key);
    return 1;
}

int lua_wg_get_device(lua_State *L) {
    const char *device_name = luaL_checkstring(L, 1);

    wg_device *dev = NULL;
    int result     = wg_get_device(&dev, device_name);
    if (result < 0) {
        RETURN_CUSTOM_ERR(L, "Failed to get device");
    }

    lua_newtable(L);

    lua_pushstring(L, dev->name);
    lua_setfield(L, -2, "name");

    lua_pushinteger(L, dev->flags);
    lua_setfield(L, -2, "flags");

    if (dev->flags & WGDEVICE_HAS_PUBLIC_KEY) {
        wg_key_b64_string key_str;
        wg_key_to_base64(key_str, dev->public_key);
        lua_pushstring(L, key_str);
        lua_setfield(L, -2, "public_key");
    }

    if (dev->flags & WGDEVICE_HAS_PRIVATE_KEY) {
        wg_key_b64_string key_str;
        wg_key_to_base64(key_str, dev->private_key);
        lua_pushstring(L, key_str);
        lua_setfield(L, -2, "private_key");
    }

    if (dev->flags & WGDEVICE_HAS_LISTEN_PORT) {
        lua_pushinteger(L, dev->listen_port);
        lua_setfield(L, -2, "listen_port");
    }

    if (dev->flags & WGDEVICE_HAS_FWMARK) {
        lua_pushinteger(L, dev->fwmark);
        lua_setfield(L, -2, "fwmark");
    }

    lua_newtable(L);
    int peer_index = 1;
    wg_peer *peer  = dev->first_peer;
    while (peer) {
        lua_pushinteger(L, peer_index);
        push_peer(L, peer);
        lua_settable(L, -3);
        peer_index++;
        peer = peer->next_peer;
    }
    lua_setfield(L, -2, "peers");

    wg_free_device(dev);
    return 1;
}

static luaL_Reg funcs[] = {
    {"list_devices",         lua_wg_list_devices        },
    {"add_device",           lua_wg_add_device          },
    {"del_device",           lua_wg_del_device          },
    {"set_device",           lua_wg_set_device          },
    {"get_device",           lua_wg_get_device          },
    {"generate_private_key", lua_wg_generate_private_key},
    {"generate_public_key",  lua_wg_generate_public_key },
    {"key_from_b64",         lua_wg_key_from_base64     },
    {"key_to_b64",           lua_wg_key_to_base64       },
    {"add_ipv4_addr",        lua_add_ipv4_address       },
    {"add_route",            lua_add_network_route      },
    {"iface_up",             lua_set_interface_up       },
    {NULL,                   NULL                       }
};

int luaopen_wireguard(lua_State *L) {
    luaL_newlib(L, funcs);
    return 1;
}
