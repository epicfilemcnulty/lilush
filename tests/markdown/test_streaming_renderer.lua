-- SPDX-FileCopyrightText: © 2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: GPL-3.0-or-later

local testimony = require("testimony")
local markdown = require("markdown")
local renderer_registry = require("markdown.renderer")
local streaming = require("markdown.renderer.streaming")
local buffer = require("string.buffer")
local tss = require("term.tss")
local theme = require("markdown.renderer.theme")
local default_tss = tss.new(theme.DEFAULT_RSS)

local testify = testimony.new("== markdown.renderer.streaming ==")

-- Helper to create a renderer that captures output
local function create_capturing_renderer(options)
	options = options or {}
	local output_buf = buffer.new()
	local capture_fn = function(s)
		output_buf:put(s)
	end
	options.output_fn = capture_fn
	local renderer = streaming.new(options)
	return renderer, function()
		return output_buf:get()
	end
end

-- Helper to feed events from markdown.parse to renderer
local function render_with_streaming(input, options)
	options = options or {}
	local renderer, get_output = create_capturing_renderer(options)
	local events = markdown.parse(input, { inline = true, streaming_inline = false })
	for _, event in ipairs(events) do
		renderer:render_event(event)
	end
	renderer:finish()
	return get_output()
end

-- Helper to strip ANSI escape codes and OSC sequences for content testing
local function strip_ansi(str)
	-- Strip SGR sequences: ESC [ ... m
	str = str:gsub("\027%[[^m]*m", "")
	-- Strip OSC 66 text sizing sequences: ESC ] 66 ; params ; text ESC \
	str = str:gsub("\027%]66;[^;]*;([^\027]*)\027\\", "%1")
	-- Strip cursor movement sequences: ESC [ n A/B/C/D/E/F/G/H
	str = str:gsub("\027%[%d*[ABCDEFGH]", "")
	-- Strip synchronized output sequences
	str = str:gsub("\027%[%?2026[hl]", "")
	-- Strip clear line sequences: ESC [ n K
	str = str:gsub("\027%[%d*K", "")
	return str
end

-- Helper to check if string contains substring
local function contains(str, substr)
	return str:find(substr, 1, true) ~= nil
end

-- ============================================
-- Renderer Registry Tests
-- ============================================

testify:that("renderer registry returns streaming renderer", function()
	local mod, err = renderer_registry.get("streaming")
	testimony.assert_not_nil(mod)
	testimony.assert_nil(err)
	testimony.assert_not_nil(mod.new)
end)

testify:that("renderer registry create returns streaming instance", function()
	local buf = buffer.new()
	local r, err = renderer_registry.create("streaming", {
		width = 80,
		output_fn = function(s)
			buf:put(s)
		end,
	})
	testimony.assert_not_nil(r)
	testimony.assert_nil(err)
	testimony.assert_not_nil(r.render_event)
	testimony.assert_not_nil(r.finish)
end)

testify:that("renderer registry list includes streaming", function()
	local names = renderer_registry.list()
	local found_streaming = false
	for _, name in ipairs(names) do
		if name == "streaming" then
			found_streaming = true
			break
		end
	end
	testimony.assert_true(found_streaming)
end)

-- ============================================
-- Basic Streaming Output Tests
-- ============================================

testify:that("streaming renderer outputs text", function()
	local result = render_with_streaming("Hello world")
	local plain = strip_ansi(result)
	testimony.assert_true(contains(plain, "Hello world"))
end)

testify:that("streaming renderer handles empty input", function()
	local result = render_with_streaming("")
	testimony.assert_equal("string", type(result))
end)

-- ============================================
-- Paragraph Rendering Tests
-- ============================================

testify:that("renders simple paragraph immediately", function()
	local result = render_with_streaming("Hello world")
	local plain = strip_ansi(result)
	testimony.assert_true(contains(plain, "Hello world"))
end)

testify:that("renders multiple paragraphs", function()
	local result = render_with_streaming("First paragraph.\n\nSecond paragraph.")
	local plain = strip_ansi(result)
	testimony.assert_true(contains(plain, "First paragraph"))
	testimony.assert_true(contains(plain, "Second paragraph"))
end)

testify:that("handles softbreak as space", function()
	local renderer, get_output = create_capturing_renderer({ width = 80 })
	renderer:render_event({ type = "block_start", tag = "para" })
	renderer:render_event({ type = "text", text = "Line one" })
	renderer:render_event({ type = "softbreak" })
	renderer:render_event({ type = "text", text = "line two" })
	renderer:render_event({ type = "block_end", tag = "para" })
	renderer:finish()
	local result = get_output()
	local plain = strip_ansi(result)
	testimony.assert_true(contains(plain, "Line one") and contains(plain, "line two"))
end)

-- ============================================
-- Heading Rendering Tests
-- ============================================

testify:that("renders h1 heading", function()
	local result = render_with_streaming("# Heading One")
	local plain = strip_ansi(result)
	testimony.assert_true(contains(plain, "Heading One"))
end)

testify:that("renders h2 heading", function()
	local result = render_with_streaming("## Heading Two")
	local plain = strip_ansi(result)
	testimony.assert_true(contains(plain, "Heading Two"))
end)

testify:that("renders all heading levels 1-6", function()
	for level = 1, 6 do
		local input = string.rep("#", level) .. " Level " .. level
		local result = render_with_streaming(input)
		local plain = strip_ansi(result)
		testimony.assert_true(contains(plain, "Level " .. level))
	end
end)

testify:that("heading followed by paragraph", function()
	local result = render_with_streaming("# Title\n\nSome content.")
	local plain = strip_ansi(result)
	testimony.assert_true(contains(plain, "Title"))
	testimony.assert_true(contains(plain, "Some content"))
end)

-- ============================================
-- Inline Emphasis Tests
-- ============================================

testify:that("renders bold text", function()
	local result = render_with_streaming("This is **bold** text.")
	local plain = strip_ansi(result)
	testimony.assert_true(contains(plain, "bold"))
	testimony.assert_true(contains(plain, "This is"))
	testimony.assert_true(contains(plain, "text"))
end)

testify:that("renders italic text", function()
	local result = render_with_streaming("This is *italic* text.")
	local plain = strip_ansi(result)
	testimony.assert_true(contains(plain, "italic"))
end)

testify:that("renders inline code", function()
	local result = render_with_streaming("Use the `print` function.")
	local plain = strip_ansi(result)
	testimony.assert_true(contains(plain, "print"))
end)

testify:that("renders nested emphasis", function()
	local result = render_with_streaming("This is ***bold and italic*** text.")
	local plain = strip_ansi(result)
	testimony.assert_true(contains(plain, "bold and italic"))
end)

-- ============================================
-- Link Rendering Tests
-- ============================================

testify:that("renders link with text and URL", function()
	local result = render_with_streaming("Visit [Example](https://example.com) site.")
	local plain = strip_ansi(result)
	testimony.assert_true(contains(plain, "Example"))
	-- URL may be clipped by TSS w=0.2 setting, so check for partial URL
	testimony.assert_true(contains(plain, "example"))
end)

testify:that("renders multiple links in paragraph", function()
	local result = render_with_streaming("See [one](http://one.com) and [two](http://two.com).")
	local plain = strip_ansi(result)
	testimony.assert_true(contains(plain, "one"))
	testimony.assert_true(contains(plain, "two"))
	testimony.assert_true(contains(plain, "one.com"))
	testimony.assert_true(contains(plain, "two.com"))
end)

-- ============================================
-- Image Rendering Tests
-- ============================================

testify:that("renders image with alt text and URL", function()
	local result = render_with_streaming("![Alt text](https://example.com/image.png)")
	local plain = strip_ansi(result)
	testimony.assert_true(contains(plain, "Alt text"))
	testimony.assert_true(contains(plain, "example.com"))
end)

-- ============================================
-- Thematic Break Tests
-- ============================================

testify:that("renders thematic break with dashes", function()
	local result = render_with_streaming("Before\n\n---\n\nAfter")
	local plain = strip_ansi(result)
	testimony.assert_true(contains(plain, "Before"))
	testimony.assert_true(contains(plain, "After"))
	testimony.assert_true(contains(plain, default_tss:get_property("thematic_break", "fill_char")))
end)

testify:that("renders thematic break with asterisks", function()
	local result = render_with_streaming("Before\n\n***\n\nAfter")
	local plain = strip_ansi(result)
	testimony.assert_true(contains(plain, default_tss:get_property("thematic_break", "fill_char")))
end)

testify:that("renders thematic break with underscores", function()
	local result = render_with_streaming("Before\n\n___\n\nAfter")
	local plain = strip_ansi(result)
	testimony.assert_true(contains(plain, default_tss:get_property("thematic_break", "fill_char")))
end)

-- ============================================
-- Code Block Rendering Tests
-- ============================================

testify:that("renders code block", function()
	local result = render_with_streaming("```\ncode here\n```")
	local plain = strip_ansi(result)
	testimony.assert_true(contains(plain, "code here"))
end)

testify:that("renders code block with language label", function()
	local result = render_with_streaming("```lua\nprint('hello')\n```")
	local plain = strip_ansi(result)
	testimony.assert_true(contains(plain, "lua"))
	testimony.assert_true(contains(plain, "print"))
end)

testify:that("code block has borders", function()
	local result = render_with_streaming("```\ncode\n```")
	local plain = strip_ansi(result)
	local border = theme.DEFAULT_BORDERS
	testimony.assert_true(contains(plain, border.top_line.before) or contains(plain, border.top_line.content) or contains(plain, border.v.content))
end)

testify:that("code block preserves content", function()
	local result = render_with_streaming("```\n  indented\n    more indented\n```")
	local plain = strip_ansi(result)
	testimony.assert_true(contains(plain, "indented"))
	testimony.assert_true(contains(plain, "more indented"))
end)

testify:that("empty code block renders", function()
	local result = render_with_streaming("```\n```")
	testimony.assert_equal("string", type(result))
end)

testify:that("code block with multiple lines", function()
	local result = render_with_streaming("```\nline1\nline2\nline3\n```")
	local plain = strip_ansi(result)
	testimony.assert_true(contains(plain, "line1"))
	testimony.assert_true(contains(plain, "line2"))
	testimony.assert_true(contains(plain, "line3"))
end)

-- ============================================
-- List Rendering Tests
-- ============================================

testify:that("renders simple unordered list", function()
	local result = render_with_streaming("- Item one\n- Item two\n- Item three")
	local plain = strip_ansi(result)
	testimony.assert_true(contains(plain, "Item one"))
	testimony.assert_true(contains(plain, "Item two"))
	testimony.assert_true(contains(plain, "Item three"))
end)

testify:that("renders simple ordered list", function()
	local result = render_with_streaming("1. First\n2. Second\n3. Third")
	local plain = strip_ansi(result)
	testimony.assert_true(contains(plain, "First"))
	testimony.assert_true(contains(plain, "Second"))
	testimony.assert_true(contains(plain, "Third"))
	testimony.assert_true(contains(plain, "1."))
	testimony.assert_true(contains(plain, "2."))
	testimony.assert_true(contains(plain, "3."))
end)

testify:that("renders ordered list with non-1 start", function()
	local result = render_with_streaming("5. Fifth\n6. Sixth")
	local plain = strip_ansi(result)
	testimony.assert_true(contains(plain, "5."))
	testimony.assert_true(contains(plain, "6."))
end)

testify:that("renders nested list", function()
	local result = render_with_streaming("- Outer\n  - Inner")
	local plain = strip_ansi(result)
	testimony.assert_true(contains(plain, "Outer"))
	testimony.assert_true(contains(plain, "Inner"))
end)

testify:that("renders list after paragraph", function()
	local result = render_with_streaming("Some paragraph.\n\n- List item")
	local plain = strip_ansi(result)
	testimony.assert_true(contains(plain, "Some paragraph"))
	testimony.assert_true(contains(plain, "List item"))
end)

testify:that("renders paragraph after list", function()
	local result = render_with_streaming("- List item\n\nParagraph after.")
	local plain = strip_ansi(result)
	testimony.assert_true(contains(plain, "List item"))
	testimony.assert_true(contains(plain, "Paragraph after"))
end)

testify:that("renders list item with inline formatting", function()
	local result = render_with_streaming("- Item with **bold** and *italic*")
	local plain = strip_ansi(result)
	testimony.assert_true(contains(plain, "Item with"))
	testimony.assert_true(contains(plain, "bold"))
	testimony.assert_true(contains(plain, "italic"))
end)

-- ============================================
-- Streaming Renderer Instance Tests
-- ============================================

testify:that("renderer can be reset and reused", function()
	local renderer, get_output = create_capturing_renderer({ width = 80 })

	-- First render
	renderer:render_event({ type = "block_start", tag = "para" })
	renderer:render_event({ type = "text", text = "First" })
	renderer:render_event({ type = "block_end", tag = "para" })
	local result1 = get_output()

	-- Reset and render again
	renderer:reset()
	renderer:render_event({ type = "block_start", tag = "para" })
	renderer:render_event({ type = "text", text = "Second" })
	renderer:render_event({ type = "block_end", tag = "para" })
	local result2 = get_output()

	local plain1 = strip_ansi(result1)
	local plain2 = strip_ansi(result2)

	testimony.assert_true(contains(plain1, "First"))
	testimony.assert_true(contains(plain2, "Second"))
end)

testify:that("renderer handles events directly", function()
	local renderer, get_output = create_capturing_renderer({ width = 80 })

	renderer:render_event({ type = "block_start", tag = "heading", attrs = { level = 1 } })
	renderer:render_event({ type = "text", text = "Direct Test" })
	renderer:render_event({ type = "block_end", tag = "heading" })
	renderer:finish()

	local result = get_output()
	local plain = strip_ansi(result)

	testimony.assert_true(contains(plain, "Direct Test"))
end)

-- ============================================
-- Combined Element Tests
-- ============================================

testify:that("renders document with multiple element types", function()
	local input = [[# Main Title

This is a paragraph with **bold** and *italic* text.

## Section One

Some code:

```lua
print("hello")
```

---

## Section Two

Visit [our site](https://example.com) for more.
]]
	local result = render_with_streaming(input)
	local plain = strip_ansi(result)

	testimony.assert_true(contains(plain, "Main Title"))
	testimony.assert_true(contains(plain, "bold"))
	testimony.assert_true(contains(plain, "italic"))
	testimony.assert_true(contains(plain, "Section One"))
	testimony.assert_true(contains(plain, "print"))
	testimony.assert_true(contains(plain, default_tss:get_property("thematic_break", "fill_char")))
	testimony.assert_true(contains(plain, "Section Two"))
	testimony.assert_true(contains(plain, "our site"))
end)

testify:that("heading with inline emphasis", function()
	local result = render_with_streaming("# Title with **bold** word")
	local plain = strip_ansi(result)
	testimony.assert_true(contains(plain, "Title with"))
	testimony.assert_true(contains(plain, "bold"))
	testimony.assert_true(contains(plain, "word"))
end)

testify:that("paragraph between code blocks", function()
	local result = render_with_streaming("```\ncode1\n```\n\nMiddle paragraph.\n\n```\ncode2\n```")
	local plain = strip_ansi(result)
	testimony.assert_true(contains(plain, "code1"))
	testimony.assert_true(contains(plain, "Middle paragraph"))
	testimony.assert_true(contains(plain, "code2"))
end)

-- ============================================
-- Edge Cases
-- ============================================

testify:that("handles empty paragraph gracefully", function()
	local renderer, get_output = create_capturing_renderer({ width = 80 })
	renderer:render_event({ type = "block_start", tag = "para" })
	renderer:render_event({ type = "block_end", tag = "para" })
	renderer:finish()
	local result = get_output()
	testimony.assert_equal("string", type(result))
end)

testify:that("handles consecutive headings", function()
	local result = render_with_streaming("# First\n\n## Second\n\n### Third")
	local plain = strip_ansi(result)
	testimony.assert_true(contains(plain, "First"))
	testimony.assert_true(contains(plain, "Second"))
	testimony.assert_true(contains(plain, "Third"))
end)

testify:that("handles link in heading", function()
	local result = render_with_streaming("# Check [this](http://example.com)")
	local plain = strip_ansi(result)
	testimony.assert_true(contains(plain, "Check"))
	testimony.assert_true(contains(plain, "this"))
	testimony.assert_true(contains(plain, "example.com"))
end)

-- ============================================
-- Inline Code Class Styling Tests
-- ============================================

-- These tests verify that class attributes on inline code
-- are used for TSS styling (e.g., `value`{.num} renders with code.num style)

-- Create a test RSS (raw style sheet) with distinctive markers for classes
local function create_test_rss()
	return {
		code = {
			fg = 249,
			before = "[C:",
			after = ":C]",
			num = { before = "[NUM:", after = ":NUM]" },
			str = { before = "[STR:", after = ":STR]" },
			req = { s = "bold", before = "[REQ:", after = ":REQ]" },
			highlight = { before = "[HL:", after = ":HL]" },
		},
	}
end

testify:that("inline code with single class applies class style", function()
	local test_rss = create_test_rss()
	local result = render_with_streaming("`123`{.num}", { tss = test_rss })
	-- Should have class-specific markers
	testimony.assert_true(contains(result, "[NUM:"))
	testimony.assert_true(contains(result, ":NUM]"))
	-- Should NOT have base code markers (class style overrides)
	testimony.assert_nil(result:find("[C:", 1, true))
end)

testify:that("inline code with multiple classes applies all class styles", function()
	local test_rss = create_test_rss()
	local result = render_with_streaming("`value`{.num .req}", { tss = test_rss })
	-- TSS cascading: later class (.req) overrides earlier (.num) for before/after
	-- So we get [REQ:...:REQ], not a mix of both markers
	testimony.assert_true(contains(result, "[REQ:"))
	testimony.assert_true(contains(result, ":REQ]"))
	-- Content should still be present
	testimony.assert_true(contains(result, "value"))
end)

testify:that("inline code without class uses base code style", function()
	local test_rss = create_test_rss()
	local result = render_with_streaming("`plain`", { tss = test_rss })
	-- Should have base code markers
	testimony.assert_true(contains(result, "[C:"))
	testimony.assert_true(contains(result, ":C]"))
	-- Should NOT have class-specific markers
	testimony.assert_nil(result:find("[NUM:", 1, true))
	testimony.assert_nil(result:find("[STR:", 1, true))
end)

testify:that("inline code class works in paragraph context", function()
	local test_rss = create_test_rss()
	local result = render_with_streaming("The value is `42`{.num} which is a number.", { tss = test_rss })
	-- Should have class markers
	testimony.assert_true(contains(result, "[NUM:"))
	testimony.assert_true(contains(result, ":NUM]"))
	-- Should contain the actual number
	testimony.assert_true(contains(result, "42"))
end)

testify:that("inline code with class in heading", function()
	-- Note: In headings with text-sizing, before/after decorators are NOT applied
	-- because apply_sized uses OSC66 sequences. Only color/style attributes work.
	-- This test verifies the content is rendered correctly with class styling recorded.
	local test_rss = {
		heading = { h1 = { size = 2 } },
		code = {
			fg = 123, -- Distinctive color
			highlight = { fg = 201 }, -- Different color for highlight class
		},
	}
	local result = render_with_streaming("# Heading with `code`{.highlight}", { tss = test_rss })
	local plain = strip_ansi(result)
	-- Should contain the heading text
	testimony.assert_true(contains(plain, "Heading with"))
	testimony.assert_true(contains(plain, "code"))
	-- Should have SGR sequences with the highlight color (201 -> 38;5;201)
	testimony.assert_true(contains(result, "38;5;201"))
end)

testify:that("multiple inline codes with different classes", function()
	local test_rss = create_test_rss()
	local result = render_with_streaming("Number: `123`{.num}, String: `hello`{.str}", { tss = test_rss })
	-- Should have both class markers
	testimony.assert_true(contains(result, "[NUM:"))
	testimony.assert_true(contains(result, ":NUM]"))
	testimony.assert_true(contains(result, "[STR:"))
	testimony.assert_true(contains(result, ":STR]"))
end)

testify:conclude()
