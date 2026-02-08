# Documentation index

All file names in the documentation are relative to the root of the repo.

* `docs/ARCHITECTURE.md`: Detailed architecture overview
* `docs/CONVENTIONS.md`: Coding and naming conventions used in the project
* `docs/BUILDING.md`: Building instructions and building system architecture
* `docs/TESTING.md`: Testing system, running tests
* `docs/TSS.md`: TSS (Terminal Style Sheets) semantics, properties, cascading, and API contract
* `docs/RELIW.md`: RELIW operator/developer guide (config, Redis schema, WAF, request semantics, operations)
* `docs/REDIS.md`: Redis client API and connection config contract
* `docs/ARGPARSER.md`: Argparser v2 API, grammar, errors, and migration guide
* `docs/CREDITS.md`: Credits, acknowledgements, licensing info

# High level overview

Lilush is a statically compiled LuaJIT interpreter for Linux that 
bundles a curated collection of Lua modules and C libraries. It serves dual purposes:

1. A batteries-included LuaJIT runtime with networking, crypto, terminal I/O, and system utilities
2. A feature-rich Linux shell (Lilush Shell) that showcases these capabilities

Lilush is by design Linux only and not portable.

## Entry Points

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

See `buildgen/entrypoints/lilush/main.c` for implementation.

### Terminal Requirements                                                                                                                                  
1. Lilush Shell requires terminals supporting 
   [Kitty keyboard protocol](https://sw.kovidgoyal.net/kitty/keyboard-protocol/): kitty, ghostty, foot, alacritty, konsole...
   Check with `term.has_kkbp()` before enabling.
2. Shell enables both KKBP and bracketed paste mode  

Primary target is Kitty Terminal, since it has other QoL enhancements, like
graphics support, text-sizing, etc. Ghostty is the next best bet (plus it
also supports kitty's graphics). Foot and Alacritty kinda work, but there are rendering issues.
Konsole should work, but was never really tested.

## Key Dependencies

- **LuaJIT 2.1** - Lua runtime (with Lua 5.2 compat enabled)
- **WolfSSL** - SSL/TLS and crypto (statically linked)

## Common Gotchas

1. **LuaJIT is not Lua 5.3+** - Uses Lua 5.1 + some 5.2 compat.
2. **Static linking** - All dependencies must be statically linkable. 
   Dynamic loading (`require` with .so) won't work in final binary.
3. **FFI disabled** - LuaJIT FFI is disabled (`-DLUAJIT_DISABLE_FFI`) for size/security. Use C modules instead.
