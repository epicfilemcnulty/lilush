# TSS (Terminal Style Sheets)

This document defines the behavior of `term.tss` (`src/term/term/tss.lua`):

- supported properties
- cascading/override rules
- width semantics (`w`)
- public API contract

## Overview

TSS is a style system for terminal output. A style sheet (`rss`) is a Lua table.
Styles are resolved by dot-path (for example: `table.border.top_line`), then applied
through `tss:apply()` or `tss:apply_sized()`.

TSS is used directly by terminal widgets and by markdown renderers.

## Supported Core Properties

These properties are understood by `term.tss` itself:

| Property | Type | Behavior |
|----------|------|----------|
| `fg` | `string` / `number` / `{r,g,b}` | Foreground color |
| `bg` | `string` / `number` / `{r,g,b}` | Background color |
| `s` | `string` | Comma-separated style list (`bold,italic,...`) |
| `align` | `string` | `left`, `right`, `center`, `none` |
| `clip` | `number` | `0` auto-clip to configured width, `>0` explicit clip position, `<0` disable clipping |
| `text_indent` | `number` | Text-level indentation added by `tss:apply()` |
| `block_indent` | `number` | Block-level indentation hint for renderers (not applied by `tss:apply()`) |
| `w` | `number` | Element width (fractional or absolute; see width semantics below) |
| `ts` | `string` / `table` | Kitty text sizing configuration (non-cascading) |

## Leaf-Object Properties

The following are read from the final resolved style object (leaf), not from cascaded props:

| Property | Type | Behavior |
|----------|------|----------|
| `content` | `string` | Overrides input content |
| `before` | `string` | Prefix decorator added before content |
| `after` | `string` | Suffix decorator added after content |
| `fill` | `boolean` | Repeats content to configured width |

Because these are leaf-object properties, define them at the style you apply directly.

## Cascading Rules

### Property cascade

- `fg`, `bg`, `align`, `clip`, `text_indent`, `block_indent`: overwrite
- `s`: accumulates; `reset` clears previously accumulated styles
- `w`: recalculated at each level using the previous computed width as max
- `ts`: does not cascade; each level either sets it or clears it

### Multiple elements in one apply call

`tss:apply(elements, content)` accepts one element or an array of elements.
When multiple elements are passed, TSS resolves them in order and merges style state
left-to-right.

## Width (`w`) Semantics

`w` rules are strict:

- `w <= 0`: auto (no explicit width)
- `0 < w < 1`: fractional width of current max width, with `floor`
- `w >= 1`: absolute terminal cell width, clamped to current max width

Important consequence:

- `w = 1` means exactly one cell (not `100%`)
- `w = 0.99` becomes `floor(max * 0.99)`, so it is not guaranteed full width

For full-width behavior, use an absolute width that will clamp to max
(for example, a very large value).

## Text Sizing (`ts`) Semantics

`ts` supports:

- preset strings: `double`, `triple`, `superscript`, `subscript`, `half`, `compact`
- table form: `{ s, w, n, d, v, h }`

Validation:

- `s`: `1..7`
- `w`: `0..7`
- `n`, `d`: `0..15` and `d > n`
- `v`: `0..2` or `top|bottom|center`
- `h`: `0..2` or `left|right|center`

Runtime gate:

- if TSS instance is created with `supports_ts = false`, `ts` is ignored by
  `apply()` and `apply_sized()`

## Public API

`term.tss` exports:

- `new(rss, opts?)`
- `merge(rss_1, rss_2, opts?)`

TSS object methods:

- `get(path, base_props?)`
- `apply(elements, content, position?)`
- `apply_sized(base_elements, content_buf, position?)`
- `scope(overrides?)`
- `set_property(path, property, value)`
- `get_property(path, property)`
- `calc_el_width(w, max?, scale?)`

### `apply()` return value

`apply()` and `apply_sized()` return a table:

- `text`: styled output string
- `width`: terminal cell width of rendered output
- `height`: terminal cell height of rendered output

Use `.text`, `.width`, and `.height` explicitly.

## Renderer-Specific Style Fields

Some style fields used in markdown renderers are not interpreted by `term.tss` directly
(for example `list.indent_per_level`).
They are consumed by renderer code and may coexist with core TSS properties.

Thematic break glyph customization uses core TSS fields:
- `thematic_break.content` for the repeated pattern
- `thematic_break.fill = true` to expand pattern to element width
