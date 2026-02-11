# Credits & Acknowledgements

Lilush is standing on the shoulders of giants,
so let's name and thank them here explicitly.

## Third-Party Libraries

| Library | License | Copyright |
|---|---|---|
| [LuaJIT](https://luajit.org/) | MIT | © 2005—2026 Mike Pall |
| [LuaSocket](https://github.com/lunarmodules/luasocket) | MIT | © 1999—2013 Diego Nehab |
| [LuaSec](https://github.com/lunarmodules/luasec) | MIT | © 2006—2023 Bruno Silvestre, UFG |
| [lua-cjson](https://github.com/mpx/lua-cjson) | MIT | © Mark Pulford |
| [WolfSSL](https://www.wolfssl.com/) | GPLv3+ (or commercial) | © wolfSSL Inc. |
| [WireGuard](https://www.wireguard.com/) | LGPL-2.1+ | © 2008—2012 Pablo Neira Ayuso, © 2015—2020 Jason A. Donenfeld |
### Licensing Notes

Lilush is dual-licensed under **OWL v1.0+** and **GPLv3+**.
See the `LICENSE`, `LICENSE-GPL3`, and `LICENSING` files in
the repository root for full details.

**LuaJIT** is MIT-licensed. Its copyright notice and license text are
preserved in its source directory.

**LuaSocket** and **LuaSec** are both MIT-licensed. Lilush includes a
heavily modified version of LuaSocket that merges in LuaSec and adapts
the TLS layer to work with WolfSSL instead of OpenSSL. Both original
copyright notices are preserved.

**WolfSSL** is statically linked into the Lilush binary and is used
under the GPLv3+ open-source license (WolfSSL changed from GPLv2
to GPLv3 as of version 5.8.2). Because of this, the compiled binary
as distributed is subject to the terms of the GPLv3+. The complete
corresponding source code for WolfSSL (as used in this build) is
available from the project repository.

**WireGuard** — Lilush includes a couple of files (C file and the headers) from the
[wireguard-tools](https://github.com/WireGuard/wireguard-tools) project, licensed 
under LGPL-2.1+. LGPL-2.1+ is compatible with GPLv3+ and permits static linking 
provided the complete corresponding source is available (which it is, as part of this
repository). The original copyright notices and SPDX identifier are
preserved in the file.

If you have questions about licensing, contact: vladimir@deviant.guru

## Runtime Dependencies

Lilush connects to [Redis](https://redis.io/) over a network socket at
runtime. Redis is not bundled or linked into the Lilush binary, so its
license does not affect Lilush's licensing terms.

## Inspirations

The build system was inspired by [The Boston Diaries](https://boston.conman.org/)
blog post.

The TSS system was obviously inspired by CSS, but adapted
to the harsh realms of terminal.

## AI contributions

Core parts of the project were designed and implemented first
by me (a human), and then refactored/extended with the help of LLMs.

Some parts were implemented by LLMs first, and then cleaned
up/extended or refactored by me.

Some were designed by me and an LLM together.

The point is — LLMs did contribute to this project,
and I'm very grateful for this, and would like to thank:

* GPT-5.2 and GPT-5.3
* Qwen3-Coder-Next
* Claude Opus and Claude Sonnet
