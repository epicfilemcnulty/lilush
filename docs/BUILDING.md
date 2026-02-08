# Build System

Lilush uses a custom build generator (`buildgen/generate.lua`) that compiles
Lua modules into LuaJIT bytecode, links them with C libraries, and produces
a single static binary. The generator itself runs on plain LuaJIT with no
external Lua dependencies.

Docker is used purely as a build medium — it provides the Alpine toolchain,
WolfSSL, and LuaJIT, then runs the generator. No runtime images are produced.

## Building

```
./build.bash [app]
```

`app` defaults to `lilush`. Available apps: `lilush`, `reliw`, `botls`, `zxkitty`.
The built binary is placed in the repo root.

## File layout

```
Dockerfile                          Docker build template (takes APP build arg)
build.bash                          Build entry point
buildgen/
  generate.lua                      Build orchestrator (runs under luajit)
  c_tmpl                            C source template with preload infrastructure
  modinfo.lua                       Module registry (Lua module names -> C identifiers)
  default_main.c                    Default main() for apps without a custom one
  apps/
    version                         Version string
    lilush.lua                      App config for lilush
    reliw.lua                       App config for reliw
    botls.lua                       App config for botls
    zxkitty.lua                     App config for zxkitty
  entrypoints/
    <app>/
      *.lua                         Lua entrypoint code (embedded as C string constants)
      main.c                        Custom main() (optional, per-app)
```

## App configs

Each app config (`buildgen/apps/<app>.lua`) returns a table:

- `binary` — output binary name
- `luamods` — list of Lua module groups to include (keys into `modinfo.lua`)
- `c_libs` — list of C library groups to include (keys into `modinfo.lua`)
- `start_code` — table mapping C constant names to `.lua` file paths under
  `buildgen/entrypoints/`. Each file is read, escaped, and emitted as a
  `static const char NAME[] = "...";` declaration.
- `custom_main` (optional) — path to a `.c` file under `buildgen/entrypoints/`
  containing the app's `main()`. If absent, `buildgen/default_main.c` is used.

## Build pipeline

What `generate.lua` does, in order:

1. **Load config** — reads the app config and `modinfo.lua`
2. **Compile C modules** — runs `make -C src/<lib>` for each C library,
   strips debug symbols from the resulting `.o` files
3. **Compile Lua modules** — for each Lua module group, finds all `.lua`
   files under `src/<mod>/`, compiles each to a bytecode header with
   `luajit -b`, and patches the header to use the project's naming scheme
4. **Generate entrypoint constants** — reads each `.lua` file referenced in
   `start_code`, escapes it for C, and emits `static const char` declarations
5. **Assemble C source** — fills the `c_tmpl` template with:
   - `{{START_CODE}}` — the entrypoint constant declarations
   - `{{LUAMODS}}` — bytecode `#include`s and the `lua_preload[]` table
   - `{{CLIBS}}` — `extern` declarations and the `c_preload[]` table
   - Appends the app's `main()` (custom or default)
   - Substitutes `{{VERSION}}` and `{{APP_NAME}}`
6. **Build static library** — `ar rcs` all `.o` files into `liblilush.a`
7. **Link binary** — `clang` with static linking against LuaJIT, WolfSSL,
   and `liblilush.a`

The output is written to `/build/<binary>` inside the Docker container.

## Docker

`Dockerfile` accepts a single build arg `APP` (the app name).
It installs the Alpine build toolchain, compiles WolfSSL and LuaJIT from
source, copies `src/` and `buildgen/` into the container, and runs
`generate.lua apps/${APP}.lua`.

`build.bash` builds the Docker image, copies the binary out, and cleans up
the container.

## Build dependencies

Provided by the Docker image (Alpine):

- `clang` (compiler/linker)
- `alpine-sdk` (make, ar, strip, etc.)
- `git` (to clone WolfSSL and LuaJIT)
- `autoconf`, `automake`, `libtool` (WolfSSL build)
- `linux-headers` (kernel headers for C modules)

Built from source inside Docker:

- **WolfSSL** (`v5.8.0-stable`) — TLS and crypto, statically linked
- **LuaJIT** (`v2.1`) — built with `-DLUAJIT_DISABLE_FFI -DLUAJIT_ENABLE_LUA52COMPAT`
