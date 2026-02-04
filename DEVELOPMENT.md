# Project Overview

Lilush is a statically compiled LuaJIT interpreter for Linux that 
bundles a curated collection of Lua modules and C libraries. It serves dual purposes:

1. A batteries-included LuaJIT runtime with networking, crypto, terminal I/O, and system utilities
2. A feature-rich Linux shell (Lilush Shell) that showcases these capabilities

## Build System

Lilush uses a custom build generator written in Lua (`buildgen/generate.lua`) that compiles everything into a static binary.

### Building

**Use Docker builds:**

```bash
ln -s dockerfiles/lilush Dockerfile
docker build -t lilush .
docker cp $(docker create --name lilush lilush):/usr/bin/lilush .
docker rm lilush
```

**Understanding the build process:**

1. `buildgen/generate.lua` is the main build orchestrator
2. App configurations in `buildgen/apps/*.lua` define which modules to include
3. Lua modules are compiled to bytecode headers using `luajit -b`
4. C modules are compiled with their respective Makefiles in `src/*/Makefile`
5. Everything is statically linked with LuaJIT and WolfSSL into a single binary

**Key build files:**

- `buildgen/apps/lilush.lua` - Main application configuration
- `buildgen/modinfo.lua` - Module registry mapping Lua/C modules
- `buildgen/c_tmpl` - C code template with preload infrastructure
- `dockerfiles/lilush` - Dockerfile showing full build dependencies

## Architecture

### Module Organization

The codebase is organized into self-contained modules in `src/`:

**Core Libraries (Lua + C):**

- `std/` - Standard library: filesystem (`std.fs`), process (`std.ps`), UTF-8 (`std.utf`), text (`std.txt`), tables (`std.tbl`), conversions, utilities
- `term/` - Terminal I/O with Kitty keyboard & graphic protocols support, widgets, TSS (Terminal Style Sheets)
- `crypto/` - Cryptography via WolfSSL
- `luasocket/` - Networking (TCP/UDP/Unix sockets) with SSL via WolfSSL (fork of LuaSocket + LuaSec)

**Pure Lua Libraries:**

- `shell/` - The Lilush Shell implementation (see Shell Architecture below)
- `reliw/` - HTTP server/framework (Redis-centric)
- `acme/` - ACMEv2 client for Let's Encrypt
- `dns/` - DNS resolver and dig utility
- `redis/` - Redis protocol client
- `vault/` - Secrets management
- `markdown/` - Markdown parser and renderer
- `argparser/` - Argument parsing
- `llm/` - Clients for working with OpenAI and llamacpp server APIs
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

See `buildgen/apps/lilush.lua` custom_main for implementation.

## Development Patterns

### Class and OOP Conventions

**IMPORTANT**: Lilush follows a specific pattern for defining classes and object-oriented code. 
This convention must be used consistently throughout the codebase.

**Naming:**
- Use **lowercase snake_case** for everything: classes, methods, variables, functions
- Use **ALL_CAPS** for constants only
- Prefix private/internal fields with underscore: `_private_field`

**Method Definition:**
Always use explicit function assignment, never the colon syntax for definitions:

```lua
-- CORRECT: Explicit function assignment
local get_name = function(self)
    return self._name
end

local set_name = function(self, name)
    self._name = name
end

-- WRONG: Do NOT use this style
function MyClass:getName()  -- PascalCase and colon syntax
    return self._name
end
```

**Constructor Pattern:**
Use a simple `new` function that returns a table with methods assigned directly (no metatables):

```lua
local new = function(initial_value)
    local instance = {
        -- Private state (prefixed with _)
        _value = initial_value,
        _cache = {},

        -- Methods assigned directly
        get_value = get_value,
        set_value = set_value,
        process = process,
    }

    return instance
end

-- Module export
return {
    new = new,
}
```

**Complete Example:**

```lua
-- my_class.lua

local std = require("std")

-- Constants (ALL_CAPS)
local DEFAULT_TIMEOUT = 5000

-- Private helper (doesn't need self, standalone function)
local validate_input = function(value)
    return value ~= nil and value ~= ""
end

-- Methods (explicit assignment, takes self)
local get_name = function(self)
    return self._name
end

local set_name = function(self, name)
    if not validate_input(name) then
        return nil, "invalid name"
    end
    self._name = name
    return true
end

local process = function(self, data)
    -- Implementation using self._name, self._timeout, etc.
end

-- Constructor
local new = function(name, options)
    options = options or {}

    local instance = {
        _name = name,
        _timeout = options.timeout or DEFAULT_TIMEOUT,

        get_name = get_name,
        set_name = set_name,
        process = process,
    }

    return instance
end

return {
    new = new,
}
```

**Key Points:**
- No `ClassName = {}` with `__index` metatables
- No `function ClassName:method()` syntax
- Methods are defined as local functions, then assigned in the constructor
- Helper functions that don't need `self` remain standalone local functions
- Module exports only what's needed (typically just `new`)

### Module Registration

When adding a new Lua module:

1. Create files in `src/yourmodule/*.lua`
2. Add module to `buildgen/modinfo.lua` luamods section
3. Add to app config in `buildgen/apps/lilush.lua` luamods array

When adding a new C module:

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

### Terminal Requirements

**CRITICAL**: Lilush Shell requires terminals supporting Kitty keyboard protocol:

- kitty, foot, alacritty, konsole, etc.
- Check with `term.has_kkbp()` before enabling
- Shell enables both KKBP and bracketed paste mode

### Error Handling

Use consistent error handling pattern:

```lua
local result, err = some_function()
if not result then
    return nil, err
end
```

Display errors to users via:

- `errmsg()` in builtins (renders with theme)
- `show_error_msg(status, err)` in shell core

## Testing

Lilush uses a minimal custom test framework called `testimony` for regression prevention and refactoring safety. 
Tests focus on core utilities (`std.*` modules) and critical logic in `term` module.

### Running Tests

**Run individual test file:**

```bash
lilush tests/std/test_tbl.lua
```

## Common Gotchas

1. **LuaJIT is not Lua 5.3+** - Uses Lua 5.1 + some 5.2 compat.
2. **Static linking** - All dependencies must be statically linkable. Dynamic loading (`require` with .so) won't work in final binary.
3. **FFI disabled** - LuaJIT FFI is disabled (`-DLUAJIT_DISABLE_FFI`) for size/security. Use C modules instead.
4. **Terminal state management** - Always restore sane mode after raw mode errors:

   ```lua
   term.set_raw_mode()
   -- ... work ...
   term.set_sane_mode()  -- Always restore!
   ```

5. **Module namespacing** - C modules use `std.core`, `term.core`, `crypto.core` naming to separate from Lua APIs.

6. **`-c` vs `-e` flags** - Lilush serves as both a shell and Lua interpreter:
   - Use `-c` for **shell commands**: `lilush -c "echo hello && ls"`
   - Use `-e` for **Lua code**: `lilush -e "print('hello')"`
   - The `-c` flag mimics bash behavior (shell command execution), not Python/Ruby style code execution

## Key Dependencies

- **LuaJIT 2.1** - Lua runtime (with Lua 5.2 compat enabled)
- **WolfSSL** - SSL/TLS and crypto (statically linked)
- **Linux-specific** - Uses Linux syscalls, terminal features, not portable
