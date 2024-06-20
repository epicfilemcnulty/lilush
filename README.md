# *Lilush* – *Li*nux *Lu*a *Sh*ell

## Description

*Lilush* is a couple of things. First of all, *lilush* is a statically
compiled LuaJIT interpreter that comes bundled with a curated collection
of custom modules and libraries for

* file system operations
* terminal I/O with UTF-8 support & terminal widgets
* process manipulation
* JSON, markdown and [djot](https://djot.net/) processing/rendering
* TCP/UDP networking with SSL support; HTTP(S) client, HTTP(S)/1.1 server
* Redis protocol support
* Embedded [WireGuard](https://www.wireguard.com/embedding/) support
* other useful stuff too =)

For networking, *lilush* includes
[Luasocket](https://github.com/lunarmodules/luasocket) library,
customized to work seamlessly with [WolfSSL](https://www.wolfssl.com/),
which is also statically compiled and incorporated into the binary.

Grab the binary (less than **2MB**) and put it on any **x86_64 Linux**
system, or add it to a `FROM scratch` container, and your Lua scripts
and apps can use all the builtin modules, without worrying about
installing anything extra. Lilush can compile your Lua code into a
static binary too.[^1]

---

Secondly, *lilush* is a powerful and versatile Linux shell, that
provides a sleek interface with a bunch of handy prompts, smart history search,
completions & predictions, and a variety of built-in modes that allow
users to switch between shell, Lua CLI interpreter, LLM CLI interface,
and more.

## Status

Currently it’s in beta state, so beware and use at your own risk.

[^1]: Well, not yet. And it really depends. But still.
