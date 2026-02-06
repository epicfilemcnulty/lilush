# Build System

Lilush uses a custom build generator written in Lua (`buildgen/generate.lua`) that compiles everything into a static binary.

## Syntax checks & formatting

We use `stylua` for syntax checks and code formatting.
Just run it against changed Lua files.

## Building

Run `./build.bash` in the repo root.
The built `lilush` binary will be put in the repo root.

### Understanding the build process

1. `buildgen/generate.lua` is the main build orchestrator
2. `buildgen/modinfo.lua` is a module registry, mapping Lua/C modules.
3. `buildgen/c_tmpl` - C code template with preload infrastructure
4. App configurations in `buildgen/apps/*.lua` define which modules to include
5. Lua modules are compiled to bytecode headers using `luajit -b`
6. C modules are compiled with their respective Makefiles in `src/*/Makefile`
7. Everything is statically linked with LuaJIT and WolfSSL into a single binary
8. Dockerfiles in `dockerfiles/` show full build dependencies for applications

## Architecture

### Module Organization

The codebase is organized into self-contained modules in `src/`:

**Core Libraries (Lua + C):**

- `std/` - Standard library
   * filesystem (`std.fs`)
   * process (`std.ps`)
   * UTF-8 (`std.utf`)
   * text (`std.txt`)
   * tables (`std.tbl`)
   * conversions, utilities
- `term/` - Terminal I/O with Kitty keyboard & graphic protocols support, widgets, TSS (Terminal Style Sheets)
- `crypto/` - Cryptography via WolfSSL
- `luasocket/` - Networking (TCP/UDP/Unix sockets) with SSL via WolfSSL (fork of LuaSocket + LuaSec)

**Pure Lua Libraries:**

- `shell/` - The Lilush Shell implementation (see Shell Architecture below)
- `argparser/` - Argument parsing
- `markdown/` - Markdown parser and renderer
- `redis/` - Redis protocol client
- `dns/` - DNS resolver and dig utility
- `vault/` - Secrets management
- `llm/` - Clients for working with OpenAI and llamacpp server APIs
- `acme/` - ACMEv2 client for Let's Encrypt
- `reliw/` - HTTP server/framework (Redis-centric)
- `testimony/` - Miminal testing framework for Lilush

**C-only Libraries:**

- `cjson/` - Fast JSON encoding/decoding
- `wireguard/` - WireGuard client bindings
- `inotify/` - File system event monitoring

### Shell Architecture

The shell (`src/shell/shell.lua`) is a **mode-based** system:

1. **Input Layer** (`term.input`) - Handles keyboard events via Kitty keyboard protocol
2. **Mode System** - Extensible modes with their own prompts/completions/behaviors

   - Default mode: `shell.mode.shell` (standard shell)
   - Modes configured in `~/.config/lilush/modes/*.json`
   - Each mode has: prompt, completion system, history, key combos

3. **Built-ins** (`shell.builtins.lua`) - Shell commands implemented in Lua
4. **Completion** (`shell.completion.shell`) - Multi-source completion engine

   - Sources: binaries, builtins, commands, environment vars, filesystem

5. **Theme** (`shell.theme.lua`) - TSS-based styling

**Shell execution flow:**

- User input → Mode handler → Built-in or external command
- Built-ins run in-process (Lua functions)
- External commands use `std.ps.exec*` functions
- Terminal state managed: raw mode during input, sane mode during execution

### Binary Preloading System

Lilush embeds all modules in the binary:

1. **Lua modules** - Compiled to bytecode, embedded as C char arrays
2. **C modules** - Statically linked, registered via `luaL_Reg`
3. **Preloading** - Both registered in `package.preload` before Lua execution

The `c_tmpl` template generates:

- `mod_lua__t lua_preload[]` - Array of Lua bytecode modules
- `luaL_Reg c_preload[]` - Array of C module loaders
- `preload_modules(L)` - Populates `package.preload`

### Entry Points

The main binary (`lilush`) has multiple entry modes:

1. **Interactive shell**: `lilush` (no args)
2. **Script execution**: `lilush /path/to/script.lua [args]`
   - Example: `lilush myscript.lua arg1 arg2`
3. **Lua code execution**: `lilush -e '<lua-code>'`
   - Executes Lua code directly (like `python -e` or `ruby -e`)
   - Example: `lilush -e "print('Hello from Lua')"`
   - Example: `lilush -e "local std = require('std'); print(std.fs.cwd())"`
4. **Shell command mode**: `lilush -c <shell-commands>`
   - Executes lilush shell commands (mimics bash `-c` behavior)
   - Example: `lilush -c "echo hello"`
   - **Note**: This runs shell commands, NOT Lua code. Use `-e` for Lua code.
5. **Built-in mode**: Symlinked as builtin name executes that builtin
6. **Version**: `lilush -v`

See `custom_main` in `buildgen/apps/lilush.lua` for implementation.

### Module Registration

#### Adding a new Lua module:

1. Create files in `src/yourmodule/*.lua`
2. Add module to `buildgen/modinfo.lua` luamods section
3. Add to app config in `buildgen/apps/lilush.lua` luamods array

#### Adding a new C module:

1. Create source in `src/yourmodule/*.c` with `luaopen_*` function
2. Create `src/yourmodule/Makefile`
3. Add to `buildgen/modinfo.lua` c_libs section
4. Add to app config in `buildgen/apps/lilush.lua` c_libs array

### File Paths and Package Loading

Lilush sets up custom Lua package paths:

```
./?.lua
~/.local/share/lilush/packages/?.lua
~/.local/share/lilush/packages/?/init.lua
/usr/local/share/lilush/?.lua
/usr/local/share/lilush/?/init.lua
```

This allows user-installed extensions in `~/.local/share/lilush/packages/`.
