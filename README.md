# _Lilush_ – *Li*nux *Lu*a *Sh*ell

## Description

_Lilush_ is a couple of things. First of all, _lilush_ is a statically
compiled for Linux [LuaJIT](https://luajit.org/) interpreter that comes bundled with a 
curated collection of Lua modules and C libraries for

* File system operations
* Terminal I/O with UTF-8 support, styling with *TSS* (Terminal Style Sheets)
* A set of terminal widgets for use in CLI apps
* Process manipulation
* JSON, markdown and [djot](https://djot.net/) processing/rendering
* TCP/UDP networking with SSL support; HTTP(S) client, HTTP(S)/1.1 server
* Redis protocol support
* Embedded [WireGuard](https://www.wireguard.com/embedding/) client
* And much more =)

For networking, _lilush_ includes [Luasocket](https://github.com/lunarmodules/luasocket) library,
which has been merged with [LuaSec](https://github.com/lunarmodules/luasec) and customized 
to work seamlessly with [WolfSSL](https://www.wolfssl.com/).
WolfSSL is also statically compiled and incorporated into the *lilush* binary.

The binary is fewer than *2MB*, and should work fine on any *x86_64 Linux*
system. It's also a nice addition to a `FROM scratch` docker container, as
_lilush_ can be used as a busybox replacement.

And to top it off, _lilush_ can compile your Lua code into a static binary too![^1]

---

Secondly, to showcase most features of its bundled modules, 
_lilush_ includes a modular Linux Shell (as in Bash, Csh or Fish), 
suprisingly called _Lilush Shell_, which

* provides a sleek CLI interface straight out of the box:

    * Pre-configured prompts: host, user, dir, git, aws, k8s, python venv
    * Command completions, completions scrolling
    * Smart directory navigation and history search, similar to [McFly](https://github.com/cantino/mcfly) and [zoxide](https://github.com/ajeetdsouza/zoxide)
    * [Terminal graphics](https://sw.kovidgoyal.net/kitty/graphics-protocol/) support

* has some handy shell builtins like `kat` (file viewer + pager), `netstat`, `dig`, `wgcli`, etc.
* supports styling with the help of TSS
* is easily extendable with plugins
* can do fortune telling and probably one day will save the humanity =)

::: NotaBene  

  _Lilush Shell_ relies on [Kitty's keyboard protocol](https://sw.kovidgoyal.net/kitty/keyboard-protocol),
  thus will only work in terminal emulators that support this protocol, e.g. `kitty`, `foot`, `alacritty`, `konsole`...  

:::  

Oh, and there is also [RELIW](RELIW_README.md), a web server/framework built on top of _Lilush_ core modules.

## Building from source

The easiest way is just to build with docker and then copy
the binary from the container:

```
git clone https://github.com/epicfilemcnulty/lilush
cd lilush
ln -s dockerfiles/lilush Dockerfile
docker build -t lilush .
docker cp $(docker create --name lilush lilush):/usr/bin/lilush .
docker rm lilush
```
If you want to build on a host system, see the [Dockerfile](dockerfiles/lilush) 
as a reference for building details.

## Status

Right now the project is certainly in beta. 

* Not all planned features have been implemented
* Documentation is lagging behind
* No proper testing has been done
* There are known bugs
* There are most certainly yet undiscovered bugs, because no proper testing has been done.

When most of the above issues are resolved, the `1.0.0` version will be released.
But quite a lot of things might be heavily refactored or removed along the way to the `1.0.0` version,
so beware and use at your own risk.

After `1.0.0` version release the project will abide by the semantic versioning promises,
but until then all bets are off. Meaning that there might be breaking changes of the core 
lilush modules' API even between, say, `0.5.x` and `0.6.x`. Or worse.
But let's hope it won't come to that.



[^1]: Well, not yet automatically. And it really depends. But still.
