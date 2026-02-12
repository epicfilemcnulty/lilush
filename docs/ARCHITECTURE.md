# Architecture

## Module Organization

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
- `markdown/` - Markdown parser and renderers (static, streaming, HTML)
- `redis/` - Redis protocol client
- `dns/` - DNS resolver and dig utility
- `vault/` - Secrets management
- `llm/` - Clients for working with OpenAI and llamacpp server APIs
- `agent/` - Agent mode runtime for shell coding assistant
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
   - Built-in modes are always present: `shell` (`F1`), `Lua REPL` (`F2`), `Agent Smith` (`F3`)
   - Modes configured in `~/.config/lilush/modes/*.json`
   - User modes are additive; reserved built-ins/shortcuts (`F1..F3`) are not overridable
   - Each mode has: prompt, completion system, history, key combos
   - Shell public mode-introspection API: `has_mode`, `get_mode`, `list_modes`, `get_mode_for_shortcut`, `list_shortcuts`, `has_combo_handler`
   - Mode contract used by shell runtime: required `run`, `get_input`, `can_handle_combo`, `handle_combo`; optional `on_shell_exit`
   - Shell validates mode contract at load time and fails fast on invalid custom modes with explicit errors
   - `shell.mode.lua` is a stateful REPL mode with a persistent in-process environment

3. **Built-ins** (`shell.builtins.lua`) - Shell commands implemented in Lua
4. **Completion** (`shell.completion.shell`) - Multi-source completion engine

   - Sources: binaries, builtins, commands, environment vars, filesystem

5. **Theme** (`theme.lua`) - central TSS-based styling for shell, markdown, and agent
   - User overrides are loaded from `~/.config/lilush/theme/`
   - Shell uses `shell.json`; markdown and agent use `markdown.json` / `agent.json`

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
