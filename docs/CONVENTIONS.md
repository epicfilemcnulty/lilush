# Coding & Naming conventions

The conventions below are not enforced for the `src/luasocket` module,
as it's a third-party module that was integrated into the project.

## Naming conventions

- **ALL_CAPS** are used for constants.
- **lowercase snake_case** used for everything else: classes, methods, variables, functions.

### Class and OOP Conventions

**IMPORTANT**: Lilush follows a specific pattern for defining classes and object-oriented code. 
This convention must be used consistently throughout the codebase.

- Configuration of a class always lives in `self.cfg` table
- Everything related to state tracking lives in `self.__state` table
- Private/internal fields are prefixed with double underscore: `self.__private_field`

**Method Definition:**
Always use explicit function assignment, never the colon syntax for definitions:

```lua
local get_name = function(self)
    return self.__name
end

local set_name = function(self, name)
    self.__name = name
end
```

**Method calls:**
Method calls use the regular Lua syntactic sugar: `my_obj:set_name("Jimmy")`

**Constructor Pattern:**
Use a simple `new` function that returns a table with methods assigned directly (no metatables by default):

```lua
local new = function(config, opts)

    local instance = {
        cfg = config,
        -- private fields
        __window = {
            size = opts.window_size,
        },    
        __value = opts.value,
        __cache = {},

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

**Key Points:**

1. No `ClassName = {}` with `__index` metatables
2. No `function ClassName:method()` syntax for definitions
3. Methods are defined as local functions, then assigned in the constructor
4. Helper functions that don't need `self` remain standalone local functions
5. Module exports only what's needed (typically just `new`)

**Metatables Policy:**

- Metatables are allowed when they provide clear value and keep code simpler (for example resource lifecycle hooks like `__gc`, or default lookup behavior).
- For constructor-style OOP modules, avoid metatables by default; prefer explicit methods and plain tables unless a metatable is clearly justified.
- When a metatable is used in project code, keep the usage minimal and intentional.


## Module namespacing

C modules use `std.core`, `term.core`, `crypto.core` naming to separate from Lua APIs.
