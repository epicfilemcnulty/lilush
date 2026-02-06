# Project Overview

Lilush is a statically compiled LuaJIT interpreter for Linux that 
bundles a curated collection of Lua modules and C libraries. It serves dual purposes:

1. A batteries-included LuaJIT runtime with networking, crypto, terminal I/O, and system utilities
2. A feature-rich Linux shell (Lilush Shell) that showcases these capabilities

Lilush is by design Linux only and not portable.

### Terminal Requirements                                                                                                                                  
1. **CRITICAL**: Lilush Shell requires terminals 
   supporting [Kitty keyboard protocol](https://sw.kovidgoyal.net/kitty/keyboard-protocol/): kitty, foot, alacritty, konsole...
   Check with `term.has_kkbp()` before enabling

2. Shell enables both KKBP and bracketed paste mode  

Primary target is kitty, since it has other QoL enhancements, like
graphics, text-sizing, etc.
 
## Key Dependencies

- **LuaJIT 2.1** - Lua runtime (with Lua 5.2 compat enabled)
- **WolfSSL** - SSL/TLS and crypto (statically linked)

## Common Gotchas

1. **LuaJIT is not Lua 5.3+** - Uses Lua 5.1 + some 5.2 compat.
2. **Static linking** - All dependencies must be statically linkable. 
   Dynamic loading (`require` with .so) won't work in final binary.
3. **FFI disabled** - LuaJIT FFI is disabled (`-DLUAJIT_DISABLE_FFI`) for size/security. Use C modules instead.

# Documentation index

All file names in the documentation are relative to the root of the repo.

* `docs/CONVENTIONS.md`: Coding and naming conventions used in the project
* `docs/BUILDING.md`: Building instructions and building system architecture
* `docs/TESTING.md`: Testing system, running tests
* `docs/TSS.md`: TSS (Terminal Style Sheets) semantics, properties, cascading, and API contract
