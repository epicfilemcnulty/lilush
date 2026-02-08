-- SPDX-FileCopyrightText: © 2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: OWL-1.0 or later
-- Licensed under the Open Weights License v1.0. See LICENSE for details.

local testimony = require("testimony")
local markdown = require("markdown")
local events = require("markdown.events")
local state = require("markdown.state")

local testify = testimony.new("== markdown.parser ==")

-- Helper to find event by type and tag
local function find_event(evts, type, tag)
	for _, e in ipairs(evts) do
		if e.type == type and (tag == nil or e.tag == tag) then
			return e
		end
	end
	return nil
end

-- Helper to count events of a type
local function count_events(evts, type, tag)
	local count = 0
	for _, e in ipairs(evts) do
		if e.type == type and (tag == nil or e.tag == tag) then
			count = count + 1
		end
	end
	return count
end

-- ============================================
-- Event Emitter Tests
-- ============================================

testify:that("events emitter invokes callback immediately", function()
	local received = nil
	local emitter = events.new(function(e)
		received = e
	end)
	emitter:emit({ type = "test", tag = "foo" })
	testimony.assert_equal("test", received.type)
	testimony.assert_equal("foo", received.tag)
end)

testify:that("events emitter with no callback is silent", function()
	local emitter = events.new(nil)
	-- Should not error
	emitter:emit({ type = "test" })
	emitter:emit_block_start("para")
	emitter:emit_block_end("para")
	emitter:emit_text("hello")
end)

testify:that("events emitter creates correct block_start events", function()
	local received = nil
	local emitter = events.new(function(e)
		received = e
	end)
	emitter:emit_block_start("heading", { level = 2 })
	testimony.assert_equal("block_start", received.type)
	testimony.assert_equal("heading", received.tag)
	testimony.assert_equal(2, received.attrs.level)
end)

testify:that("events emitter creates correct block_end events", function()
	local received = nil
	local emitter = events.new(function(e)
		received = e
	end)
	emitter:emit_block_end("para")
	testimony.assert_equal("block_end", received.type)
	testimony.assert_equal("para", received.tag)
end)

testify:that("events emitter creates correct text events", function()
	local received = nil
	local emitter = events.new(function(e)
		received = e
	end)
	emitter:emit_text("Hello, world!")
	testimony.assert_equal("text", received.type)
	testimony.assert_equal("Hello, world!", received.text)
end)

testify:that("events emitter skips empty text", function()
	local count = 0
	local emitter = events.new(function(e)
		count = count + 1
	end)
	emitter:emit_text("")
	emitter:emit_text(nil)
	testimony.assert_equal(0, count)
end)

-- ============================================
-- State Detection Tests
-- ============================================

testify:that("state detects blank lines", function()
	testimony.assert_true(state.is_blank_line(""))
	testimony.assert_true(state.is_blank_line("   "))
	testimony.assert_true(state.is_blank_line("\t\t"))
	testimony.assert_true(state.is_blank_line("  \t  "))
	testimony.assert_false(state.is_blank_line("hello"))
	testimony.assert_false(state.is_blank_line("  x"))
end)

testify:that("state detects headings level 1-6", function()
	local level, content = state.detect_heading("# Hello")
	testimony.assert_equal(1, level)
	testimony.assert_equal("Hello", content)

	level, content = state.detect_heading("## World")
	testimony.assert_equal(2, level)
	testimony.assert_equal("World", content)

	level, content = state.detect_heading("###### Deep")
	testimony.assert_equal(6, level)
	testimony.assert_equal("Deep", content)
end)

testify:that("state strips trailing hashes from headings", function()
	local level, content = state.detect_heading("# Hello ###")
	testimony.assert_equal(1, level)
	testimony.assert_equal("Hello", content)

	level, content = state.detect_heading("## World ##")
	testimony.assert_equal(2, level)
	testimony.assert_equal("World", content)
end)

testify:that("state handles empty headings", function()
	local level, content = state.detect_heading("# ")
	testimony.assert_equal(1, level)
	testimony.assert_equal("", content)

	level, content = state.detect_heading("##")
	testimony.assert_equal(2, level)
	testimony.assert_equal("", content)
end)

testify:that("state rejects invalid headings", function()
	-- No space after hashes
	testimony.assert_nil(state.detect_heading("#Hello"))
	-- Too many hashes
	testimony.assert_nil(state.detect_heading("####### Too many"))
	-- Too much leading indent (4+ spaces = code block, not heading)
	testimony.assert_nil(state.detect_heading("    # Heading"))
end)

testify:that("state allows up to 3 leading spaces in headings", function()
	-- 1 space
	local level, content = state.detect_heading(" # One space")
	testimony.assert_equal(1, level)
	testimony.assert_equal("One space", content)

	-- 2 spaces
	level, content = state.detect_heading("  # Two spaces")
	testimony.assert_equal(1, level)
	testimony.assert_equal("Two spaces", content)

	-- 3 spaces
	level, content = state.detect_heading("   # Three spaces")
	testimony.assert_equal(1, level)
	testimony.assert_equal("Three spaces", content)
end)

testify:that("state detects code fence opening", function()
	local char, len, lang, indent = state.detect_code_fence_open("```lua")
	testimony.assert_equal("`", char)
	testimony.assert_equal(3, len)
	testimony.assert_equal("lua", lang)

	char, len, lang, indent = state.detect_code_fence_open("~~~python")
	testimony.assert_equal("~", char)
	testimony.assert_equal(3, len)
	testimony.assert_equal("python", lang)

	char, len, lang, indent = state.detect_code_fence_open("````")
	testimony.assert_equal("`", char)
	testimony.assert_equal(4, len)
	testimony.assert_equal("", lang)
end)

testify:that("state detects code fence closing", function()
	testimony.assert_true(state.is_code_fence_close("```", "`", 3))
	testimony.assert_true(state.is_code_fence_close("````", "`", 3))
	testimony.assert_true(state.is_code_fence_close("~~~", "~", 3))
	testimony.assert_false(state.is_code_fence_close("``", "`", 3))
	testimony.assert_false(state.is_code_fence_close("```", "~", 3))
end)

testify:that("state rejects backtick fence with backticks in info string", function()
	-- CommonMark: backtick code fence info string cannot contain backticks
	testimony.assert_nil(state.detect_code_fence_open("```lua`s"))
	testimony.assert_nil(state.detect_code_fence_open("``` `inline` ```"))

	-- Tilde fences can have backticks in info string
	local char, len, lang = state.detect_code_fence_open("~~~lua`s")
	testimony.assert_equal("~", char)
	testimony.assert_equal("lua`s", lang)
end)

testify:that("state allows up to 3 leading spaces in code fences", function()
	local char, len, lang, indent = state.detect_code_fence_open(" ```lua")
	testimony.assert_equal("`", char)
	testimony.assert_equal(1, indent)

	char, len, lang, indent = state.detect_code_fence_open("  ```lua")
	testimony.assert_equal(2, indent)

	char, len, lang, indent = state.detect_code_fence_open("   ```lua")
	testimony.assert_equal(3, indent)

	-- 4 spaces should fail (would be indented code block)
	testimony.assert_nil(state.detect_code_fence_open("    ```lua"))
end)

testify:that("state code fence closing allows trailing whitespace", function()
	testimony.assert_true(state.is_code_fence_close("```  ", "`", 3))
	testimony.assert_true(state.is_code_fence_close("```\t", "`", 3))
	testimony.assert_true(state.is_code_fence_close("~~~  \t  ", "~", 3))

	-- But not other characters
	testimony.assert_false(state.is_code_fence_close("```x", "`", 3))
	testimony.assert_false(state.is_code_fence_close("```lua", "`", 3))
end)

testify:that("state detects thematic breaks", function()
	testimony.assert_true(state.detect_thematic_break("---"))
	testimony.assert_true(state.detect_thematic_break("***"))
	testimony.assert_true(state.detect_thematic_break("___"))
	testimony.assert_true(state.detect_thematic_break("- - -"))
	testimony.assert_true(state.detect_thematic_break("* * *"))
	testimony.assert_true(state.detect_thematic_break("-----"))
	testimony.assert_true(state.detect_thematic_break("  ---"))
	testimony.assert_false(state.detect_thematic_break("--"))
	testimony.assert_false(state.detect_thematic_break("hello"))
end)

testify:that("state rejects invalid thematic breaks", function()
	-- Only 2 characters (need 3+)
	testimony.assert_false(state.detect_thematic_break("--"))
	testimony.assert_false(state.detect_thematic_break("**"))
	testimony.assert_false(state.detect_thematic_break("__"))

	-- Mixed characters
	testimony.assert_false(state.detect_thematic_break("-*-"))
	testimony.assert_false(state.detect_thematic_break("*-*"))
	testimony.assert_false(state.detect_thematic_break("-_-"))

	-- 4+ leading spaces (would be code block)
	testimony.assert_false(state.detect_thematic_break("    ---"))

	-- Non-thematic break characters
	testimony.assert_false(state.detect_thematic_break("==="))
	testimony.assert_false(state.detect_thematic_break("+++"))
end)

testify:that("state allows up to 3 leading spaces in thematic breaks", function()
	testimony.assert_true(state.detect_thematic_break(" ---"))
	testimony.assert_true(state.detect_thematic_break("  ---"))
	testimony.assert_true(state.detect_thematic_break("   ---"))
end)

-- ============================================
-- Basic Block Tests
-- (Using inline=false to test block structure in isolation)
-- ============================================

testify:that("parses single paragraph", function()
	local evts = markdown.parse("Hello, world!", { inline = false })
	testimony.assert_equal(3, #evts) -- block_start, text, block_end
	testimony.assert_equal("block_start", evts[1].type)
	testimony.assert_equal("para", evts[1].tag)
	testimony.assert_equal("text", evts[2].type)
	testimony.assert_equal("Hello, world!", evts[2].text)
	testimony.assert_equal("block_end", evts[3].type)
	testimony.assert_equal("para", evts[3].tag)
end)

testify:that("parses multi-line paragraph with softbreaks", function()
	local evts = markdown.parse("Line one\nLine two\nLine three", { inline = false })
	-- block_start, text, softbreak, text, softbreak, text, block_end
	testimony.assert_equal(7, #evts)
	testimony.assert_equal("softbreak", evts[3].type)
	testimony.assert_equal("softbreak", evts[5].type)
end)

testify:that("parses paragraph terminated by blank line", function()
	local evts = markdown.parse("Paragraph one\n\nParagraph two", { inline = false })
	-- Two paragraphs
	testimony.assert_equal(2, count_events(evts, "block_start", "para"))
	testimony.assert_equal(2, count_events(evts, "block_end", "para"))
end)

testify:that("parses heading level 1", function()
	local evts = markdown.parse("# Hello", { inline = false })
	testimony.assert_equal(3, #evts)
	testimony.assert_equal("block_start", evts[1].type)
	testimony.assert_equal("heading", evts[1].tag)
	testimony.assert_equal(1, evts[1].attrs.level)
	testimony.assert_equal("Hello", evts[2].text)
end)

testify:that("parses heading levels 1-6", function()
	local input = "# H1\n## H2\n### H3\n#### H4\n##### H5\n###### H6"
	local evts = markdown.parse(input, { inline = false })
	local headings = 0
	for _, e in ipairs(evts) do
		if e.type == "block_start" and e.tag == "heading" then
			headings = headings + 1
		end
	end
	testimony.assert_equal(6, headings)
end)

testify:that("parses fenced code block", function()
	local input = "```lua\nprint('hello')\n```"
	local evts = markdown.parse(input, { inline = false })
	local start_evt = find_event(evts, "block_start", "code_block")
	testimony.assert_equal("lua", start_evt.attrs.lang)
	local text_evt = find_event(evts, "text")
	testimony.assert_equal("print('hello')", text_evt.text)
end)

testify:that("parses code block without language", function()
	local input = "```\nsome code\n```"
	local evts = markdown.parse(input, { inline = false })
	local start_evt = find_event(evts, "block_start", "code_block")
	testimony.assert_nil(start_evt.attrs)
end)

testify:that("parses code block with tilde fence", function()
	local input = "~~~\ncode here\n~~~"
	local evts = markdown.parse(input, { inline = false })
	testimony.assert_equal(1, count_events(evts, "block_start", "code_block"))
end)

testify:that("parses thematic break", function()
	local evts = markdown.parse("---", { inline = false })
	testimony.assert_equal(2, #evts)
	testimony.assert_equal("block_start", evts[1].type)
	testimony.assert_equal("thematic_break", evts[1].tag)
	testimony.assert_equal("block_end", evts[2].type)
end)

testify:that("parses thematic break variants", function()
	for _, br in ipairs({ "---", "***", "___", "- - -", "  ---" }) do
		local evts = markdown.parse(br, { inline = false })
		testimony.assert_equal(1, count_events(evts, "block_start", "thematic_break"))
	end
end)

-- ============================================
-- Block Interaction Tests
-- ============================================

testify:that("heading interrupts paragraph", function()
	local evts = markdown.parse("Start of para\n# Heading", { inline = false })
	-- Should have paragraph then heading
	local found_para = false
	local found_heading = false
	for _, e in ipairs(evts) do
		if e.type == "block_start" and e.tag == "para" then
			found_para = true
		end
		if e.type == "block_start" and e.tag == "heading" then
			found_heading = true
		end
	end
	testimony.assert_true(found_para)
	testimony.assert_true(found_heading)
end)

testify:that("thematic break interrupts paragraph", function()
	local evts = markdown.parse("Para text\n---", { inline = false })
	testimony.assert_equal(1, count_events(evts, "block_start", "para"))
	testimony.assert_equal(1, count_events(evts, "block_start", "thematic_break"))
end)

testify:that("code block content is not parsed as blocks", function()
	local input = "```\n# Not a heading\n---\n```"
	local evts = markdown.parse(input, { inline = false })
	-- Should only have code_block, no heading or thematic_break
	testimony.assert_equal(1, count_events(evts, "block_start", "code_block"))
	testimony.assert_equal(0, count_events(evts, "block_start", "heading"))
	testimony.assert_equal(0, count_events(evts, "block_start", "thematic_break"))
end)

testify:that("multiple blocks in sequence", function()
	local input = "# Title\n\nParagraph.\n\n---\n\n```\ncode\n```"
	local evts = markdown.parse(input, { inline = false })
	testimony.assert_equal(1, count_events(evts, "block_start", "heading"))
	testimony.assert_equal(1, count_events(evts, "block_start", "para"))
	testimony.assert_equal(1, count_events(evts, "block_start", "thematic_break"))
	testimony.assert_equal(1, count_events(evts, "block_start", "code_block"))
end)

-- ============================================
-- Streaming Tests (block-level, inline=false)
-- ============================================

testify:that("handles chunk boundary in middle of line", function()
	local evts = {}
	local parser = markdown.stream({
		on_event = function(e)
			evts[#evts + 1] = e
		end,
		inline = false,
	})
	parser:feed("Hel")
	parser:feed("lo")
	parser:finish()
	local text_evt = find_event(evts, "text")
	testimony.assert_equal("Hello", text_evt.text)
end)

testify:that("handles chunk boundary at newline", function()
	local evts = {}
	local parser = markdown.stream({
		on_event = function(e)
			evts[#evts + 1] = e
		end,
		inline = false,
	})
	parser:feed("Line 1\n")
	parser:feed("Line 2")
	parser:finish()
	testimony.assert_equal(2, count_events(evts, "text"))
end)

testify:that("reset clears parser state", function()
	local evts = {}
	local parser = markdown.stream({
		on_event = function(e)
			evts[#evts + 1] = e
		end,
		inline = false,
	})
	parser:feed("First")
	parser:finish()
	local first_count = #evts

	parser:reset()
	evts = {}
	parser:set_event_callback(function(e)
		evts[#evts + 1] = e
	end)
	parser:feed("Second")
	parser:finish()

	-- Should have fresh events
	local text_evt = find_event(evts, "text")
	testimony.assert_equal("Second", text_evt.text)
end)

testify:that("handles empty input", function()
	local evts = markdown.parse("", { inline = false })
	testimony.assert_equal(0, #evts)
end)

testify:that("handles only blank lines", function()
	local evts = markdown.parse("\n\n\n", { inline = false })
	testimony.assert_equal(0, #evts)
end)

-- ============================================
-- Edge Cases
-- ============================================

testify:that("handles unclosed code block", function()
	local input = "```lua\ncode without closing"
	local evts = markdown.parse(input, { inline = false })
	-- Should still emit code_block events
	testimony.assert_equal(1, count_events(evts, "block_start", "code_block"))
	testimony.assert_equal(1, count_events(evts, "block_end", "code_block"))
end)

testify:that("handles heading without content", function()
	local evts = markdown.parse("# ", { inline = false })
	testimony.assert_equal(1, count_events(evts, "block_start", "heading"))
end)

testify:that("handles CRLF line endings", function()
	local evts = markdown.parse("Line 1\r\nLine 2\r\n", { inline = false })
	testimony.assert_equal(1, count_events(evts, "block_start", "para"))
	testimony.assert_equal(2, count_events(evts, "text"))
end)

testify:that("code block preserves internal blank lines", function()
	local input = "```\nline 1\n\nline 2\n```"
	local evts = markdown.parse(input, { inline = false })
	local text_evt = find_event(evts, "text")
	testimony.assert_match("\n\n", text_evt.text)
end)

-- ============================================
-- List Detection Tests
-- ============================================

testify:that("state detects unordered list marker -", function()
	local block_type, attrs = state.detect_list_item("- Item")
	testimony.assert_equal("list_item", block_type)
	testimony.assert_false(attrs.ordered)
	testimony.assert_equal("-", attrs.marker)
	testimony.assert_equal("Item", attrs.content)
end)

testify:that("state detects unordered list marker *", function()
	local block_type, attrs = state.detect_list_item("* Item")
	testimony.assert_equal("list_item", block_type)
	testimony.assert_false(attrs.ordered)
	testimony.assert_equal("*", attrs.marker)
end)

testify:that("state detects unordered list marker +", function()
	local block_type, attrs = state.detect_list_item("+ Item")
	testimony.assert_equal("list_item", block_type)
	testimony.assert_false(attrs.ordered)
	testimony.assert_equal("+", attrs.marker)
end)

testify:that("state detects ordered list marker with period", function()
	local block_type, attrs = state.detect_list_item("1. First item")
	testimony.assert_equal("list_item", block_type)
	testimony.assert_true(attrs.ordered)
	testimony.assert_equal(1, attrs.start)
	testimony.assert_equal(".", attrs.delimiter)
	testimony.assert_equal("First item", attrs.content)
end)

testify:that("state detects ordered list marker with paren", function()
	local block_type, attrs = state.detect_list_item("1) First item")
	testimony.assert_equal("list_item", block_type)
	testimony.assert_true(attrs.ordered)
	testimony.assert_equal(")", attrs.delimiter)
end)

testify:that("state detects ordered list with high start number", function()
	local block_type, attrs = state.detect_list_item("42. Answer")
	testimony.assert_equal("list_item", block_type)
	testimony.assert_equal(42, attrs.start)
end)

testify:that("state allows up to 3 leading spaces in list items", function()
	-- 1 space
	local _, attrs = state.detect_list_item(" - Item")
	testimony.assert_equal(1, attrs.indent)

	-- 2 spaces
	_, attrs = state.detect_list_item("  - Item")
	testimony.assert_equal(2, attrs.indent)

	-- 3 spaces
	_, attrs = state.detect_list_item("   - Item")
	testimony.assert_equal(3, attrs.indent)

	-- 4 spaces should not be detected (would be code block)
	local block_type = state.detect_list_item("    - Item")
	testimony.assert_nil(block_type)
end)

testify:that("state requires space after list marker", function()
	-- No space after marker - not a list item
	testimony.assert_nil(state.detect_list_item("-Item"))
	testimony.assert_nil(state.detect_list_item("1.Item"))
end)

testify:that("state detects empty list items", function()
	local block_type, attrs = state.detect_list_item("- ")
	testimony.assert_equal("list_item", block_type)
	testimony.assert_equal("", attrs.content)
end)

-- ============================================
-- List Parsing Tests
-- ============================================

testify:that("parses simple unordered list", function()
	local input = "- Item one\n- Item two\n- Item three"
	local evts = markdown.parse(input, { inline = false })

	-- Should have: list_start, list_item(x3 with para inside), list_end
	testimony.assert_equal(1, count_events(evts, "block_start", "list"))
	testimony.assert_equal(1, count_events(evts, "block_end", "list"))
	testimony.assert_equal(3, count_events(evts, "block_start", "list_item"))
	testimony.assert_equal(3, count_events(evts, "block_end", "list_item"))
end)

testify:that("parses simple ordered list", function()
	local input = "1. First\n2. Second\n3. Third"
	local evts = markdown.parse(input, { inline = false })

	testimony.assert_equal(1, count_events(evts, "block_start", "list"))
	local list_start = find_event(evts, "block_start", "list")
	testimony.assert_true(list_start.attrs.ordered)
	testimony.assert_equal(1, list_start.attrs.start)
end)

testify:that("parses ordered list with non-1 start", function()
	local input = "5. Fifth\n6. Sixth"
	local evts = markdown.parse(input, { inline = false })

	local list_start = find_event(evts, "block_start", "list")
	testimony.assert_equal(5, list_start.attrs.start)
end)

testify:that("different markers create separate lists", function()
	local input = "- Dash item\n* Star item"
	local evts = markdown.parse(input, { inline = false })

	-- Different markers = different lists
	testimony.assert_equal(2, count_events(evts, "block_start", "list"))
end)

testify:that("list after paragraph", function()
	local input = "Some paragraph.\n\n- List item"
	local evts = markdown.parse(input, { inline = false })

	-- 1 standalone paragraph + 1 paragraph inside list item = 2 paragraphs
	testimony.assert_equal(2, count_events(evts, "block_start", "para"))
	testimony.assert_equal(1, count_events(evts, "block_start", "list"))
end)

testify:that("list interrupts paragraph", function()
	local input = "Paragraph text\n- List item"
	local evts = markdown.parse(input, { inline = false })

	-- List should interrupt the paragraph
	-- 1 interrupted paragraph + 1 paragraph inside list item = 2 paragraphs
	testimony.assert_equal(2, count_events(evts, "block_start", "para"))
	testimony.assert_equal(1, count_events(evts, "block_start", "list"))
end)

testify:that("paragraph after list", function()
	local input = "- List item\n\nParagraph after."
	local evts = markdown.parse(input, { inline = false })

	testimony.assert_equal(1, count_events(evts, "block_start", "list"))
	-- Paragraph count includes the one in the list item plus the one after
	testimony.assert_true(count_events(evts, "block_start", "para") >= 2)
end)

testify:that("nested list with indentation", function()
	local input = "- Outer\n  - Inner"
	local evts = markdown.parse(input, { inline = false })

	-- Should have two lists (outer and inner)
	testimony.assert_equal(2, count_events(evts, "block_start", "list"))
end)

testify:that("tight nested list with multiple sibling items", function()
	local input = "- Outer\n  - Inner1\n  - Inner2\n  - Inner3"
	local evts = markdown.parse(input, { inline = false })

	-- Should have two lists (outer and nested)
	testimony.assert_equal(2, count_events(evts, "block_start", "list"))
	-- Should have 4 list items total (1 outer + 3 inner)
	testimony.assert_equal(4, count_events(evts, "block_start", "list_item"))
end)

testify:that("loose nested list with sibling items", function()
	local input = "- Outer\n\n  - Inner1\n\n  - Inner2"
	local evts = markdown.parse(input, { inline = false })

	-- Should have two lists (outer and nested)
	testimony.assert_equal(2, count_events(evts, "block_start", "list"))
	-- Should have 3 list items total (1 outer + 2 inner)
	testimony.assert_equal(3, count_events(evts, "block_start", "list_item"))
end)

testify:that("nested list mixing tight and loose items", function()
	local input = "- Outer\n  - Inner1\n  - Inner2\n\n  - Inner3"
	local evts = markdown.parse(input, { inline = false })

	testimony.assert_equal(2, count_events(evts, "block_start", "list"))
	testimony.assert_equal(4, count_events(evts, "block_start", "list_item"))
end)

testify:that("three-level nested list", function()
	local input = "- L1\n  - L2a\n    - L3\n  - L2b"
	local evts = markdown.parse(input, { inline = false })

	-- Should have 3 lists (L1, L2, L3)
	testimony.assert_equal(3, count_events(evts, "block_start", "list"))
	-- Should have 4 items total
	testimony.assert_equal(4, count_events(evts, "block_start", "list_item"))
end)

testify:that("list with empty item", function()
	local input = "- \n- Item"
	local evts = markdown.parse(input, { inline = false })

	testimony.assert_equal(1, count_events(evts, "block_start", "list"))
	testimony.assert_equal(2, count_events(evts, "block_start", "list_item"))
end)

testify:that("single item list", function()
	local input = "- Only item"
	local evts = markdown.parse(input, { inline = false })

	testimony.assert_equal(1, count_events(evts, "block_start", "list"))
	testimony.assert_equal(1, count_events(evts, "block_start", "list_item"))
end)

-- ============================================
-- Task List Tests (GFM)
-- ============================================

testify:that("state detects unchecked task list item", function()
	local block_type, attrs = state.detect_list_item("- [ ] Task")
	testimony.assert_equal("list_item", block_type)
	testimony.assert_true(attrs.task)
	testimony.assert_false(attrs.checked)
	testimony.assert_equal("Task", attrs.content)
end)

testify:that("state detects checked task list item with x", function()
	local block_type, attrs = state.detect_list_item("- [x] Done")
	testimony.assert_equal("list_item", block_type)
	testimony.assert_true(attrs.task)
	testimony.assert_true(attrs.checked)
end)

testify:that("state detects checked task list item with X", function()
	local block_type, attrs = state.detect_list_item("- [X] Done")
	testimony.assert_equal("list_item", block_type)
	testimony.assert_true(attrs.task)
	testimony.assert_true(attrs.checked)
end)

testify:that("parses task list", function()
	local input = "- [ ] Todo\n- [x] Done"
	local evts = markdown.parse(input, { inline = false })

	testimony.assert_equal(1, count_events(evts, "block_start", "list"))
	testimony.assert_equal(2, count_events(evts, "block_start", "list_item"))

	-- Find the list_item events and check task attrs
	local items = {}
	for _, e in ipairs(evts) do
		if e.type == "block_start" and e.tag == "list_item" then
			items[#items + 1] = e
		end
	end
	testimony.assert_true(items[1].attrs and items[1].attrs.task)
	testimony.assert_false(items[1].attrs.checked)
	testimony.assert_true(items[2].attrs and items[2].attrs.task)
	testimony.assert_true(items[2].attrs.checked)
end)

testify:that("task list with other markers", function()
	local input = "* [ ] Star task\n+ [x] Plus task"
	local evts = markdown.parse(input, { inline = false })

	-- Different markers create different lists
	testimony.assert_equal(2, count_events(evts, "block_start", "list"))
end)

-- ============================================
-- Table Detection Tests (GFM)
-- ============================================

testify:that("state parses table row", function()
	local cells = state.parse_table_row("| a | b | c |")
	testimony.assert_equal(3, #cells)
	testimony.assert_equal("a", cells[1])
	testimony.assert_equal("b", cells[2])
	testimony.assert_equal("c", cells[3])
end)

testify:that("state parses table row without leading pipe", function()
	local cells = state.parse_table_row("a | b | c |")
	testimony.assert_equal(3, #cells)
end)

testify:that("state parses table row without trailing pipe", function()
	local cells = state.parse_table_row("| a | b | c")
	testimony.assert_equal(3, #cells)
end)

testify:that("state trims cell whitespace", function()
	local cells = state.parse_table_row("|  a  |  b  |")
	testimony.assert_equal("a", cells[1])
	testimony.assert_equal("b", cells[2])
end)

testify:that("state detects left-aligned delimiter", function()
	local alignments = state.detect_table_delimiter("|:---|---|")
	testimony.assert_true(alignments ~= nil)
	testimony.assert_equal("left", alignments[1])
	testimony.assert_equal("left", alignments[2])
end)

testify:that("state detects center-aligned delimiter", function()
	local alignments = state.detect_table_delimiter("|:---:|")
	testimony.assert_true(alignments ~= nil)
	testimony.assert_equal("center", alignments[1])
end)

testify:that("state detects right-aligned delimiter", function()
	local alignments = state.detect_table_delimiter("|---:|")
	testimony.assert_true(alignments ~= nil)
	testimony.assert_equal("right", alignments[1])
end)

testify:that("state detects mixed alignments", function()
	local alignments = state.detect_table_delimiter("|:---|:---:|---:|")
	testimony.assert_true(alignments ~= nil)
	testimony.assert_equal("left", alignments[1])
	testimony.assert_equal("center", alignments[2])
	testimony.assert_equal("right", alignments[3])
end)

testify:that("state rejects invalid delimiter", function()
	-- No dashes
	testimony.assert_nil(state.detect_table_delimiter("| : | : |"))
	-- Text instead of dashes
	testimony.assert_nil(state.detect_table_delimiter("| abc | def |"))
end)

-- ============================================
-- Table Parsing Tests (GFM)
-- ============================================

testify:that("parses simple table", function()
	local input = "| a | b |\n|---|---|\n| 1 | 2 |"
	local evts = markdown.parse(input, { inline = false })

	testimony.assert_equal(1, count_events(evts, "block_start", "table"))
	testimony.assert_equal(1, count_events(evts, "block_end", "table"))
	testimony.assert_equal(1, count_events(evts, "block_start", "table_head"))
	testimony.assert_equal(1, count_events(evts, "block_start", "table_body"))
	testimony.assert_equal(2, count_events(evts, "block_start", "table_row"))
end)

testify:that("parses table with alignments", function()
	local input = "| Left | Center | Right |\n|:-----|:------:|------:|\n| a | b | c |"
	local evts = markdown.parse(input, { inline = false })

	testimony.assert_equal(1, count_events(evts, "block_start", "table"))

	-- Find cell events and check alignments
	local cells = {}
	for _, e in ipairs(evts) do
		if e.type == "block_start" and e.tag == "table_cell" then
			cells[#cells + 1] = e
		end
	end
	-- First row cells (header)
	testimony.assert_true(#cells >= 3)
	testimony.assert_equal("left", cells[1].attrs.align)
	testimony.assert_equal("center", cells[2].attrs.align)
	testimony.assert_equal("right", cells[3].attrs.align)
end)

testify:that("parses table with multiple body rows", function()
	local input = "| h1 | h2 |\n|---|---|\n| a | b |\n| c | d |\n| e | f |"
	local evts = markdown.parse(input, { inline = false })

	-- 1 header row + 3 body rows = 4 rows
	testimony.assert_equal(4, count_events(evts, "block_start", "table_row"))
end)

testify:that("table ends at blank line", function()
	local input = "| a | b |\n|---|---|\n| 1 | 2 |\n\nParagraph after"
	local evts = markdown.parse(input, { inline = false })

	testimony.assert_equal(1, count_events(evts, "block_start", "table"))
	testimony.assert_equal(1, count_events(evts, "block_start", "para"))
end)

testify:that("row without delimiter is not a table", function()
	local input = "| a | b |\nNot a table"
	local evts = markdown.parse(input, { inline = false })

	testimony.assert_equal(0, count_events(evts, "block_start", "table"))
	-- Should be paragraphs instead
	testimony.assert_true(count_events(evts, "block_start", "para") >= 1)
end)

testify:that("table cells have inline content", function()
	local input = "| **bold** | *italic* |\n|---|---|\n| text | more |"
	local evts = markdown.parse(input, { streaming_inline = false })

	-- Should have inline events for the header cells
	testimony.assert_true(count_events(evts, "inline_start", "strong") >= 1)
	testimony.assert_true(count_events(evts, "inline_start", "emph") >= 1)
end)

testify:conclude()
