-- SPDX-FileCopyrightText: © 2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: OWL-1.0 or later
-- Licensed under the Open Weights License v1.0. See LICENSE for details.

local testimony = require("testimony")
local markdown = require("markdown")
local renderer_registry = require("markdown.renderer")
local static = require("markdown.renderer.static")
local tss = require("term.tss")
local theme = require("markdown.renderer.theme")
local default_tss = tss.new(theme.DEFAULT_RSS)

local testify = testimony.new("== markdown.renderer.static ==")

-- Helper to strip ANSI escape codes and OSC sequences for content testing
local function strip_ansi(str)
	-- Strip SGR sequences: ESC [ ... m
	str = str:gsub("\027%[[^m]*m", "")
	-- Strip OSC 66 text sizing sequences: ESC ] 66 ; params ; text ESC \
	-- We extract and keep the text content from inside the sequence
	str = str:gsub("\027%]66;[^;]*;([^\027]*)\027\\", "%1")
	return str
end

-- Helper to check if string contains substring
local function contains(str, substr)
	return str:find(substr, 1, true) ~= nil
end

-- ============================================
-- Renderer Registry Tests
-- ============================================

testify:that("renderer registry returns static renderer", function()
	local mod, err = renderer_registry.get("static")
	testimony.assert_not_nil(mod)
	testimony.assert_nil(err)
	testimony.assert_not_nil(mod.new)
end)

testify:that("renderer registry returns error for unknown renderer", function()
	local mod, err = renderer_registry.get("nonexistent")
	testimony.assert_nil(mod)
	testimony.assert_not_nil(err)
	testimony.assert_true(contains(err, "unknown renderer"))
end)

testify:that("renderer registry create returns instance", function()
	local r, err = renderer_registry.create("static", { width = 80 })
	testimony.assert_not_nil(r)
	testimony.assert_nil(err)
	testimony.assert_not_nil(r.render_event)
	testimony.assert_not_nil(r.finish)
end)

testify:that("renderer registry list returns available renderers", function()
	local names = renderer_registry.list()
	testimony.assert_true(#names >= 1)
	local found_static = false
	for _, name in ipairs(names) do
		if name == "static" then
			found_static = true
			break
		end
	end
	testimony.assert_true(found_static)
end)

-- ============================================
-- Basic Render Function Tests
-- ============================================

testify:that("markdown.render returns string", function()
	local result = markdown.render("Hello world")
	testimony.assert_equal("string", type(result))
end)

testify:that("markdown.render handles empty input", function()
	local result = markdown.render("")
	testimony.assert_equal("string", type(result))
end)

testify:that("markdown.render handles nil input", function()
	local result = markdown.render(nil)
	testimony.assert_equal("string", type(result))
end)

testify:that("markdown.render returns error for unknown renderer", function()
	local result, err = markdown.render("test", { renderer = "nonexistent" })
	testimony.assert_nil(result)
	testimony.assert_not_nil(err)
end)

-- ============================================
-- Paragraph Rendering Tests
-- ============================================

testify:that("renders simple paragraph", function()
	local result = markdown.render("Hello world")
	local plain = strip_ansi(result)
	testimony.assert_true(contains(plain, "Hello world"))
end)

testify:that("renders multiple paragraphs with blank line separation", function()
	local result = markdown.render("First paragraph.\n\nSecond paragraph.")
	local plain = strip_ansi(result)
	testimony.assert_true(contains(plain, "First paragraph"))
	testimony.assert_true(contains(plain, "Second paragraph"))
end)

testify:that("wraps long paragraphs at specified width", function()
	local long_text = string.rep("word ", 30) -- ~150 chars
	local result = markdown.render(long_text, { width = 40 })
	local plain = strip_ansi(result)
	-- Should have multiple lines due to wrapping
	local lines = {}
	for line in plain:gmatch("[^\n]+") do
		lines[#lines + 1] = line
	end
	testimony.assert_true(#lines > 1)
end)

-- ============================================
-- Heading Rendering Tests
-- ============================================

testify:that("renders h1 heading", function()
	local result = markdown.render("# Heading One")
	local plain = strip_ansi(result)
	testimony.assert_true(contains(plain, "Heading One"))
end)

testify:that("renders h2 heading", function()
	local result = markdown.render("## Heading Two")
	local plain = strip_ansi(result)
	testimony.assert_true(contains(plain, "Heading Two"))
end)

testify:that("renders h3 heading", function()
	local result = markdown.render("### Heading Three")
	local plain = strip_ansi(result)
	testimony.assert_true(contains(plain, "Heading Three"))
end)

testify:that("renders all heading levels 1-6", function()
	for level = 1, 6 do
		local input = string.rep("#", level) .. " Level " .. level
		local result = markdown.render(input)
		local plain = strip_ansi(result)
		testimony.assert_true(contains(plain, "Level " .. level))
	end
end)

testify:that("heading followed by paragraph", function()
	local result = markdown.render("# Title\n\nSome content.")
	local plain = strip_ansi(result)
	testimony.assert_true(contains(plain, "Title"))
	testimony.assert_true(contains(plain, "Some content"))
end)

-- ============================================
-- Code Block Rendering Tests
-- ============================================

testify:that("renders fenced code block", function()
	local input = "```\ncode here\n```"
	local result = markdown.render(input)
	local plain = strip_ansi(result)
	testimony.assert_true(contains(plain, "code here"))
end)

testify:that("renders code block with language label", function()
	local input = "```lua\nprint('hello')\n```"
	local result = markdown.render(input)
	local plain = strip_ansi(result)
	testimony.assert_true(contains(plain, "lua"))
	testimony.assert_true(contains(plain, "print"))
end)

testify:that("code block has borders", function()
	local input = "```\ncode\n```"
	local result = markdown.render(input)
	local plain = strip_ansi(result)
	-- Should have border characters (from default TSS)
	local border = theme.DEFAULT_BORDERS
	testimony.assert_true(contains(plain, border.top_line.before) or contains(plain, border.top_line.content) or contains(plain, border.v.content))
end)

testify:that("code block preserves indentation", function()
	local input = "```\n  indented\n    more indented\n```"
	local result = markdown.render(input)
	local plain = strip_ansi(result)
	testimony.assert_true(contains(plain, "  indented"))
	testimony.assert_true(contains(plain, "    more indented"))
end)

testify:that("empty code block renders", function()
	local input = "```\n```"
	local result = markdown.render(input)
	testimony.assert_equal("string", type(result))
end)

testify:that("code block with multiple lines", function()
	local input = "```\nline1\nline2\nline3\n```"
	local result = markdown.render(input)
	local plain = strip_ansi(result)
	testimony.assert_true(contains(plain, "line1"))
	testimony.assert_true(contains(plain, "line2"))
	testimony.assert_true(contains(plain, "line3"))
end)

-- ============================================
-- Thematic Break Tests
-- ============================================

-- TODO: we need to test thematic breaks,
-- but without relying on specific symbols,
-- as they can be styled differently depending
-- on TSS in use.

-- ============================================
-- Inline Emphasis Tests
-- ============================================

testify:that("renders bold text", function()
	local result = markdown.render("This is **bold** text.")
	local plain = strip_ansi(result)
	testimony.assert_true(contains(plain, "bold"))
	-- Bold styling is applied via ANSI, so original text should be present
	testimony.assert_true(contains(plain, "This is"))
	testimony.assert_true(contains(plain, "text"))
end)

testify:that("renders italic text", function()
	local result = markdown.render("This is *italic* text.")
	local plain = strip_ansi(result)
	testimony.assert_true(contains(plain, "italic"))
end)

testify:that("renders inline code", function()
	local result = markdown.render("Use the `print` function.")
	local plain = strip_ansi(result)
	testimony.assert_true(contains(plain, "print"))
end)

testify:that("renders nested emphasis", function()
	local result = markdown.render("This is ***bold and italic*** text.")
	local plain = strip_ansi(result)
	testimony.assert_true(contains(plain, "bold and italic"))
end)

-- ============================================
-- Link Rendering Tests
-- ============================================

testify:that("renders link with text and URL", function()
	local result = markdown.render("Visit [Example](https://example.com) site.")
	local plain = strip_ansi(result)
	testimony.assert_true(contains(plain, "Example"))
	-- URL may be clipped by TSS w=0.2 setting, so check for partial URL
	testimony.assert_true(contains(plain, "example"))
end)

testify:that("renders link with title", function()
	local result = markdown.render('[Link](https://example.com "Title")')
	local plain = strip_ansi(result)
	testimony.assert_true(contains(plain, "Link"))
	-- URL may be clipped by TSS w=0.2 setting, so check for partial URL
	testimony.assert_true(contains(plain, "example"))
end)

testify:that("renders multiple links in paragraph", function()
	local result = markdown.render("See [one](http://one.com) and [two](http://two.com).")
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
	local result = markdown.render("![Alt text](https://example.com/image.png)")
	local plain = strip_ansi(result)
	testimony.assert_true(contains(plain, "Alt text"))
	testimony.assert_true(contains(plain, "example.com"))
end)

-- ============================================
-- Width Configuration Tests
-- ============================================

testify:that("respects custom width setting", function()
	local long_text = string.rep("x", 100)
	local result_narrow = markdown.render(long_text, { width = 30 })
	local result_wide = markdown.render(long_text, { width = 120 })
	-- Narrow should have more newlines due to wrapping
	local narrow_newlines = select(2, result_narrow:gsub("\n", "\n"))
	local wide_newlines = select(2, result_wide:gsub("\n", "\n"))
	testimony.assert_true(narrow_newlines >= wide_newlines)
end)

testify:that("default width is 80", function()
	-- 100+ char line with spaces should wrap at default 80
	-- lines_of only wraps at spaces/hyphens when force_split=false
	local text = string.rep("word ", 20) -- "word word word..." ~100 chars
	local result = markdown.render(text)
	local plain = strip_ansi(result)
	local lines = {}
	for line in plain:gmatch("[^\n]+") do
		lines[#lines + 1] = line
	end
	testimony.assert_true(#lines > 1)
end)

-- ============================================
-- Global Indent Tests
-- ============================================

testify:that("applies global indent", function()
	local result = markdown.render("Hello", { indent = 4 })
	-- Should start with 4 spaces (after stripping ANSI codes that std.txt.indent adds)
	local plain = strip_ansi(result)
	testimony.assert_true(plain:match("^    "))
end)

testify:that("indent zero has no leading spaces", function()
	local result = markdown.render("Hello", { indent = 0 })
	local plain = strip_ansi(result)
	-- First non-whitespace should be 'H'
	local first_char = plain:match("^%S")
	testimony.assert_equal("H", first_char)
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
	local result = markdown.render(input)
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
	local result = markdown.render("# Title with **bold** word")
	local plain = strip_ansi(result)
	testimony.assert_true(contains(plain, "Title with"))
	testimony.assert_true(contains(plain, "bold"))
	testimony.assert_true(contains(plain, "word"))
end)

testify:that("paragraph between code blocks", function()
	local input = "```\ncode1\n```\n\nMiddle paragraph.\n\n```\ncode2\n```"
	local result = markdown.render(input)
	local plain = strip_ansi(result)
	testimony.assert_true(contains(plain, "code1"))
	testimony.assert_true(contains(plain, "Middle paragraph"))
	testimony.assert_true(contains(plain, "code2"))
end)

-- ============================================
-- Static Renderer Instance Tests
-- ============================================

testify:that("renderer can be reset and reused", function()
	local r = static.new({ width = 80 })

	-- First render
	r:render_event({ type = "block_start", tag = "para" })
	r:render_event({ type = "text", text = "First" })
	r:render_event({ type = "block_end", tag = "para" })
	local result1 = r:finish()

	-- Reset and render again
	r:reset()
	r:render_event({ type = "block_start", tag = "para" })
	r:render_event({ type = "text", text = "Second" })
	r:render_event({ type = "block_end", tag = "para" })
	local result2 = r:finish()

	local plain1 = strip_ansi(result1.rendered)
	local plain2 = strip_ansi(result2.rendered)

	testimony.assert_true(contains(plain1, "First"))
	testimony.assert_false(contains(plain1, "Second"))
	testimony.assert_true(contains(plain2, "Second"))
	testimony.assert_false(contains(plain2, "First"))
end)

testify:that("renderer handles events directly", function()
	local r = static.new({ width = 80 })

	r:render_event({ type = "block_start", tag = "heading", attrs = { level = 1 } })
	r:render_event({ type = "text", text = "Direct Test" })
	r:render_event({ type = "block_end", tag = "heading" })

	local result = r:finish()
	local plain = strip_ansi(result.rendered)

	testimony.assert_true(contains(plain, "Direct Test"))
end)

-- ============================================
-- Edge Cases
-- ============================================

testify:that("handles empty paragraph gracefully", function()
	local r = static.new({ width = 80 })
	r:render_event({ type = "block_start", tag = "para" })
	r:render_event({ type = "block_end", tag = "para" })
	local result = r:finish()
	-- Should not crash, result should be a table with rendered string
	testimony.assert_equal("table", type(result))
	testimony.assert_equal("string", type(result.rendered))
end)

testify:that("handles softbreak as space", function()
	local r = static.new({ width = 80 })
	r:render_event({ type = "block_start", tag = "para" })
	r:render_event({ type = "text", text = "Line one" })
	r:render_event({ type = "softbreak" })
	r:render_event({ type = "text", text = "line two" })
	r:render_event({ type = "block_end", tag = "para" })
	local result = r:finish()
	local plain = strip_ansi(result.rendered)
	testimony.assert_true(contains(plain, "Line one line two") or contains(plain, "Line one\nline two"))
end)

testify:that("handles consecutive headings", function()
	local input = "# First\n\n## Second\n\n### Third"
	local result = markdown.render(input)
	local plain = strip_ansi(result)
	testimony.assert_true(contains(plain, "First"))
	testimony.assert_true(contains(plain, "Second"))
	testimony.assert_true(contains(plain, "Third"))
end)

testify:that("handles link in heading", function()
	local result = markdown.render("# Check [this](http://example.com)")
	local plain = strip_ansi(result)
	testimony.assert_true(contains(plain, "Check"))
	testimony.assert_true(contains(plain, "this"))
	testimony.assert_true(contains(plain, "example.com"))
end)

-- ============================================
-- List Rendering Tests
-- ============================================

testify:that("renders simple unordered list", function()
	local input = "- Item one\n- Item two\n- Item three"
	local result = markdown.render(input)
	local plain = strip_ansi(result)
	testimony.assert_true(contains(plain, "Item one"))
	testimony.assert_true(contains(plain, "Item two"))
	testimony.assert_true(contains(plain, "Item three"))
end)

testify:that("renders simple ordered list", function()
	local input = "1. First\n2. Second\n3. Third"
	local result = markdown.render(input)
	local plain = strip_ansi(result)
	testimony.assert_true(contains(plain, "First"))
	testimony.assert_true(contains(plain, "Second"))
	testimony.assert_true(contains(plain, "Third"))
	-- Should have numbers
	testimony.assert_true(contains(plain, "1."))
	testimony.assert_true(contains(plain, "2."))
	testimony.assert_true(contains(plain, "3."))
end)

testify:that("renders ordered list with non-1 start", function()
	local input = "5. Fifth\n6. Sixth"
	local result = markdown.render(input)
	local plain = strip_ansi(result)
	testimony.assert_true(contains(plain, "5."))
	testimony.assert_true(contains(plain, "6."))
end)

testify:that("renders nested list", function()
	local input = "- Outer\n  - Inner"
	local result = markdown.render(input)
	local plain = strip_ansi(result)
	testimony.assert_true(contains(plain, "Outer"))
	testimony.assert_true(contains(plain, "Inner"))
end)

testify:that("renders list after paragraph", function()
	local input = "Some paragraph.\n\n- List item"
	local result = markdown.render(input)
	local plain = strip_ansi(result)
	testimony.assert_true(contains(plain, "Some paragraph"))
	testimony.assert_true(contains(plain, "List item"))
end)

testify:that("renders paragraph after list", function()
	local input = "- List item\n\nParagraph after."
	local result = markdown.render(input)
	local plain = strip_ansi(result)
	testimony.assert_true(contains(plain, "List item"))
	testimony.assert_true(contains(plain, "Paragraph after"))
end)

testify:that("renders list item with inline formatting", function()
	local input = "- Item with **bold** and *italic*"
	local result = markdown.render(input)
	local plain = strip_ansi(result)
	testimony.assert_true(contains(plain, "Item with"))
	testimony.assert_true(contains(plain, "bold"))
	testimony.assert_true(contains(plain, "italic"))
end)

testify:that("renders empty list item", function()
	local input = "- \n- Item"
	local result = markdown.render(input)
	local plain = strip_ansi(result)
	-- Should not crash, and should contain the non-empty item
	testimony.assert_true(contains(plain, "Item"))
end)

testify:that("renders single item list", function()
	local input = "- Only item"
	local result = markdown.render(input)
	local plain = strip_ansi(result)
	testimony.assert_true(contains(plain, "Only item"))
end)

-- ============================================
-- Blockquote Rendering Tests
-- ============================================

testify:that("renders simple blockquote", function()
	local input = "> This is a quote."
	local result = markdown.render(input)
	local plain = strip_ansi(result)
	testimony.assert_true(contains(plain, "This is a quote"))
	-- Should have the bar character from default theme
	local bar = theme.DEFAULT_RSS.blockquote.bar.content
	testimony.assert_true(contains(result, bar:sub(1, 1))) -- Check for ┃
end)

testify:that("renders multi-line blockquote", function()
	local input = "> Line one.\n> Line two."
	local result = markdown.render(input)
	local plain = strip_ansi(result)
	testimony.assert_true(contains(plain, "Line one"))
	testimony.assert_true(contains(plain, "Line two"))
end)

testify:that("renders blockquote with paragraph", function()
	local input = "Before.\n\n> Quoted text.\n\nAfter."
	local result = markdown.render(input)
	local plain = strip_ansi(result)
	testimony.assert_true(contains(plain, "Before"))
	testimony.assert_true(contains(plain, "Quoted text"))
	testimony.assert_true(contains(plain, "After"))
end)

testify:that("renders blockquote with inline formatting", function()
	local input = "> This has **bold** and *italic* text."
	local result = markdown.render(input)
	local plain = strip_ansi(result)
	testimony.assert_true(contains(plain, "bold"))
	testimony.assert_true(contains(plain, "italic"))
end)

-- ============================================
-- Fenced Div Rendering Tests
-- ============================================

testify:that("renders simple fenced div", function()
	local input = "::: note\nThis is a note.\n:::"
	local result = markdown.render(input)
	local plain = strip_ansi(result)
	testimony.assert_true(contains(plain, "This is a note"))
	-- Should have border characters
	local border = theme.DEFAULT_BORDERS
	testimony.assert_true(contains(plain, border.v.content))
end)

testify:that("renders div with class label", function()
	local input = "::: warning\nBe careful!\n:::"
	local result = markdown.render(input)
	local plain = strip_ansi(result)
	testimony.assert_true(contains(plain, "Be careful"))
	-- Should show class name in header (like code block shows language)
	testimony.assert_true(contains(plain, "warning"))
end)

testify:that("renders div with default class", function()
	local input = ":::\nGeneric div content.\n:::"
	local result = markdown.render(input)
	local plain = strip_ansi(result)
	testimony.assert_true(contains(plain, "Generic div content"))
end)

testify:that("renders div with paragraph and code", function()
	local input = "::: tip\nHere's a tip:\n\n```\nsome code\n```\n:::"
	local result = markdown.render(input)
	local plain = strip_ansi(result)
	testimony.assert_true(contains(plain, "tip"))
	testimony.assert_true(contains(plain, "Here's a tip"))
	testimony.assert_true(contains(plain, "some code"))
end)

testify:conclude()
