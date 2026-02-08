# Argparser

This document specifies the `argparser` API and CLI grammar.

## Overview

`argparser` is a declarative command builder with:

- GNU-style options (`--opt v`, `--opt=v`, `-o v`, `-o=v`, `-ov`)
- bool negation aliases (`--no-<flag>`)
- typed validation (`string`, `number`, `boolean`, `file`, `dir`)
- subcommands
- structured help and parse errors

## API

```lua
local argparser = require("argparser")

local parser = argparser.command("tool")
  :summary("One-line summary")
  :description("Longer description")
  :option("verbose", { short = "v", type = "boolean" })
  :argument("path", { type = "string", nargs = "?" })
  :build()

local parsed, err = parser:parse(argv)
```

### Builder methods

- `command(name, opts?)`
- `:summary(text)`
- `:description(text)`
- `:option(name, spec)`
- `:argument(name, spec)`
- `:command(name, spec_fn_or_table)` (subcommand)
- `:action(fn)` (reserved hook)
- `:build()`

### Option spec

- `short`: one-char short alias (`-v`)
- `long`: explicit long name (default: `name` with `_` -> `-`)
- `type|kind`: `boolean|string|number|file|dir` (aliases: `bool|str|num`)
- `default`: default value
- `required`: require option presence
- `repeatable`: collect repeated values into array
- `negatable`: allow/disallow auto `--no-<long>` for bools (default: true)
- `choices`: allowed values list
- `metavar`: help placeholder for value
- `note|help`: help text

### Argument spec

- `type|kind`: same type system as options
- `nargs`: one of `1`, `?`, `*`, `+`
- `default`: default when omitted
- `required`: explicit requirement (typically inferred by `nargs`)
- `note|help`: help text

## Parse Contract

```lua
local parsed, err = parser:parse(argv)
```

- Success: `parsed` table, `err == nil`
- Failure/help: `parsed == nil`, `err` table:
  - `kind`: `help` or `parse_error`
  - `code`: stable error code
  - `message`: human-readable message
  - `usage`: generated usage string
  - `suggestions`: optional list of alternatives

Helpers:

- `argparser.format_help(parser)` -> help text
- `argparser.format_error(err)` -> formatted error/help output
  - for `err.kind == "help"`, returns markdown help directly

## CLI Grammar

### Options

- Long options:
  - `--name value`
  - `--name=value`
- Short options:
  - `-n value`
  - `-n=value`
  - `-nVALUE`
- Short boolean bundles:
  - `-rfv`
  - if one short option needs a value, it must be the final option in the bundle

### Bool negation

- Every bool option is negatable by default:
  - `--cache`
  - `--no-cache`

### End of options

- `--` stops option parsing; remaining tokens are positional.

### Subcommands

- Root command may define subcommands.
- Parser returns:
  - `parsed.__sub`
  - `parsed.__args`

## Help Rendering Contract

Help output is markdown-first and organized as:

1. `# <command>`
2. Summary/description
3. `## Usage`
4. `## Options` (pipe table)
5. `## Arguments` (pipe table)
6. `## Subcommands` (pipe table, when present)

Semantic classes are attached to inline code spans to support themed rendering:

- type classes: `.bool`, `.num`, `.str`, `.file`, `.dir`
- role classes: `.opt`, `.arg`, `.flag`, `.meta`
- state classes: `.req`, `.def`, `.multi`, `.neg`

Example snippets:

- option form: `` `--cache`{.opt .flag .bool} ``
- negation form: `` `--no-cache`{.opt .flag .neg .bool} ``
- default value: `` `false`{.def .bool} ``

## Error Model

Examples of `code` values:

- `unknown_option`
- `missing_value`
- `invalid_value`
- `missing_argument`
- `unknown_subcommand`
- `missing_subcommand`

Unknown options/subcommands include suggestions when available.
