# _Lilush_ – *Li*nux *Lu*a *Sh*ell

## Description

_Lilush_ is a couple of things. First of all, _lilush_ is a statically
compiled LuaJIT interpreter that comes bundled with a curated collection
of custom modules and libraries for

* File system operations
* Terminal I/O with UTF-8 support, styling with TSS (terminal style sheets)
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
WolfSSL is also statically compiled and incorporated into the *Lilush* binary.

Grab the binary (less than *2MB*) and put it on any *x86_64 Linux*
system, or add it to a `FROM scratch` container, and your Lua scripts
and apps can use all the builtin modules, without worrying about
installing anything extra. _Lilush_ can compile your Lua code into a
static binary too.[^1]

---

Secondly, to illustrate what can be built with the bundled modules, 
_Lilush_ includes a modular Linux shell (as in Bash, Csh or Fish), which

* provides a sleek CLI interface straight out of the box:

    * Pre-configured prompts: host, user, dir, git, aws, k8s, python venv
    * Command completions, completions scrolling
    * Smart directory navigation and history search, similar to [McFly](https://github.com/cantino/mcfly) and [zoxide](https://github.com/ajeetdsouza/zoxide)

* supports styling with the help of TSS
* easily extendable with plugins
* can do fortune telling and probably one day will save the humanity =)

Oh, and there is also [RELIW](RELIW_README.md), a web server/framework built on top of _lilush_ core modules.

## Building from source

Building is done with docker:

```
git clone https://github.com/epicfilemcnulty/lilush
cd lilush
ln -s dockerfiles/lilush Dockerfile
docker build -t lilush .
docker cp $(docker create --name lilush lilush):/usr/bin/lilush .
docker rm lilush
```
See the [Dockerfile](dockerfiles/lilush) for building details.

## Status

Right now the project is certainly in beta.
The first version I consider "stable" will be tagged as `1.0.0` and from there on
the project will abide by the semantic versioning promises. 

Until then all bets are off, meaning that there might be breaking
changes of the core lilush modules' API even between, say, `0.5.x` and `0.6.x`. Or worse.
But let's hope it won't come to that.

[^1]: Well, not yet automatically. And it really depends. But still.
