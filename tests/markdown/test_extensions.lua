-- SPDX-FileCopyrightText: © 2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: OWL-1.0 or later
-- Licensed under the Open Weights License v1.0. See LICENSE for details.

-- Tests for Djot Extensions and GFM extensions requiring document-level processing

local testimony = require("testimony")
local markdown = require("markdown")
local state = require("markdown.state")

local testify = testimony.new("== markdown.extensions ==")

-- Helper to find event by type and tag
local function find_event(evts, type, tag)
	for _, e in ipairs(evts) do
		if e.type == type and (tag == nil or e.tag == tag) then
			return e
		end
	end
	return nil
end

-- Helper to find all events matching type and tag
local function find_all_events(evts, type, tag)
	local found = {}
	for _, e in ipairs(evts) do
		if e.type == type and (tag == nil or e.tag == tag) then
			found[#found + 1] = e
		end
	end
	return found
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
-- Link Reference Definition Tests
-- ============================================

testify:that("state detects link reference definition", function()
	local label, dest, title = state.detect_link_reference("[example]: https://example.com")
	testimony.assert_equal("example", label)
	testimony.assert_equal("https://example.com", dest)
	testimony.assert_nil(title)
end)

testify:that("state detects link reference with title", function()
	local label, dest, title = state.detect_link_reference('[example]: https://example.com "Example Site"')
	testimony.assert_equal("example", label)
	testimony.assert_equal("https://example.com", dest)
	testimony.assert_equal("Example Site", title)
end)

testify:that("state detects link reference with single quote title", function()
	local label, dest, title = state.detect_link_reference("[example]: https://example.com 'Example Site'")
	testimony.assert_equal("example", label)
	testimony.assert_equal("https://example.com", dest)
	testimony.assert_equal("Example Site", title)
end)

testify:that("state detects link reference with paren title", function()
	local label, dest, title = state.detect_link_reference("[example]: https://example.com (Example Site)")
	testimony.assert_equal("example", label)
	testimony.assert_equal("https://example.com", dest)
	testimony.assert_equal("Example Site", title)
end)

testify:that("state detects link reference with angle brackets", function()
	local label, dest, title = state.detect_link_reference("[example]: <https://example.com>")
	testimony.assert_equal("example", label)
	testimony.assert_equal("https://example.com", dest)
end)

testify:that("state normalizes link reference label", function()
	-- Labels should be case-insensitive and whitespace-normalized
	local label, dest, _ = state.detect_link_reference("[Example  Label]: https://example.com")
	testimony.assert_equal("example label", label)
end)

testify:that("state allows leading spaces in link reference", function()
	local label, dest, _ = state.detect_link_reference("   [example]: https://example.com")
	testimony.assert_equal("example", label)
	testimony.assert_equal("https://example.com", dest)
end)

testify:that("state rejects invalid link reference", function()
	-- No destination
	testimony.assert_nil(state.detect_link_reference("[example]:"))
	-- Too much indentation
	testimony.assert_nil(state.detect_link_reference("    [example]: https://example.com"))
end)

-- ============================================
-- Reference Link Parsing Tests
-- ============================================

testify:that("parses collapsed reference link", function()
	-- Note: Definition must come BEFORE usage in streaming mode
	local input = "[example]: https://example.com\n\n[example][]"
	local evts = markdown.parse(input, { streaming_inline = false })
	-- Should find a link with href
	local link_start = find_event(evts, "inline_start", "link")
	testimony.assert_true(link_start ~= nil)
	testimony.assert_equal("https://example.com", link_start.attrs.href)
end)

testify:that("parses full reference link", function()
	-- Note: Definition must come BEFORE usage in streaming mode
	local input = "[example]: https://example.com\n\n[click here][example]"
	local evts = markdown.parse(input, { streaming_inline = false })
	local link_start = find_event(evts, "inline_start", "link")
	testimony.assert_true(link_start ~= nil)
	testimony.assert_equal("https://example.com", link_start.attrs.href)
end)

testify:that("reference link with title", function()
	-- Note: Definition must come BEFORE usage in streaming mode
	local input = '[example]: https://example.com "Title"\n\n[example][]'
	local evts = markdown.parse(input, { streaming_inline = false })
	local link_start = find_event(evts, "inline_start", "link")
	testimony.assert_true(link_start ~= nil)
	testimony.assert_equal("https://example.com", link_start.attrs.href)
	testimony.assert_equal("Title", link_start.attrs.title)
end)

testify:that("undefined reference link becomes literal", function()
	local input = "[text][undefined]"
	local evts = markdown.parse(input, { streaming_inline = false })
	-- Should NOT find a link (no definition)
	local link_start = find_event(evts, "inline_start", "link")
	testimony.assert_nil(link_start)
	-- Should have literal text
	local texts = find_all_events(evts, "text")
	local combined = ""
	for _, t in ipairs(texts) do
		combined = combined .. (t.text or "")
	end
	testimony.assert_match("%[text%]%[undefined%]", combined)
end)

testify:that("first reference definition wins", function()
	-- Note: Definition must come BEFORE usage in streaming mode
	local input = "[example]: https://first.com\n[example]: https://second.com\n\n[example][]"
	local evts = markdown.parse(input, { streaming_inline = false })
	local link_start = find_event(evts, "inline_start", "link")
	testimony.assert_true(link_start ~= nil)
	testimony.assert_equal("https://first.com", link_start.attrs.href)
end)

testify:that("reference link case insensitive", function()
	-- Note: Definition must come BEFORE usage in streaming mode
	local input = "[example]: https://example.com\n\n[EXAMPLE][]"
	local evts = markdown.parse(input, { streaming_inline = false })
	local link_start = find_event(evts, "inline_start", "link")
	testimony.assert_true(link_start ~= nil)
	testimony.assert_equal("https://example.com", link_start.attrs.href)
end)

-- ============================================
-- Footnote Definition Detection Tests
-- ============================================

testify:that("state detects footnote definition", function()
	local label, content, indent = state.detect_footnote_definition("[^note]: This is the content")
	testimony.assert_equal("note", label)
	testimony.assert_equal("This is the content", content)
end)

testify:that("state normalizes footnote label", function()
	local label, content, _ = state.detect_footnote_definition("[^MyNote]: Content")
	testimony.assert_equal("mynote", label)
end)

testify:that("state allows leading spaces in footnote", function()
	local label, content, indent = state.detect_footnote_definition("  [^note]: Content")
	testimony.assert_equal("note", label)
	testimony.assert_equal(2, indent)
end)

testify:that("state rejects invalid footnote definition", function()
	-- Missing caret
	testimony.assert_nil(state.detect_footnote_definition("[note]: Content"))
	-- Too much indentation
	testimony.assert_nil(state.detect_footnote_definition("    [^note]: Content"))
end)

-- ============================================
-- Footnote Parsing Tests
-- ============================================

testify:that("parses footnote reference", function()
	-- Note: Definition must come BEFORE usage in streaming mode
	local input = "[^note]: Footnote content.\n\nText with footnote[^note]."
	local evts = markdown.parse(input, { streaming_inline = false })
	-- Should have footnote_ref inline event
	local fn_ref = find_event(evts, "inline_start", "footnote_ref")
	testimony.assert_true(fn_ref ~= nil)
	testimony.assert_equal("note", fn_ref.attrs.label)
end)

testify:that("emits footnotes block at document end", function()
	-- Note: Definition must come BEFORE usage in streaming mode
	local input = "[^note]: Content.\n\nText[^note]."
	local evts = markdown.parse(input, { streaming_inline = false })
	-- Should have footnotes block
	local fn_block = find_event(evts, "block_start", "footnotes")
	testimony.assert_true(fn_block ~= nil)
	-- Should have footnote block
	local fn = find_event(evts, "block_start", "footnote")
	testimony.assert_true(fn ~= nil)
	testimony.assert_equal("note", fn.attrs.label)
end)

testify:that("unused footnote is not emitted", function()
	local input = "Text without reference.\n\n[^note]: Unused content."
	local evts = markdown.parse(input, { streaming_inline = false })
	-- Should NOT have footnotes block
	local fn_block = find_event(evts, "block_start", "footnotes")
	testimony.assert_nil(fn_block)
end)

testify:that("multiple footnotes", function()
	-- Note: Definitions must come BEFORE usage in streaming mode
	local input = "[^a]: Note A.\n[^b]: Note B.\n\nFirst[^a] and second[^b]."
	local evts = markdown.parse(input, { streaming_inline = false })
	-- Should have 2 footnote references
	testimony.assert_equal(2, count_events(evts, "inline_start", "footnote_ref"))
	-- Should have 2 footnote definitions
	testimony.assert_equal(2, count_events(evts, "block_start", "footnote"))
end)

testify:that("undefined footnote reference becomes literal", function()
	local input = "Text[^undefined]."
	local evts = markdown.parse(input, { streaming_inline = false })
	-- Should still have footnote_ref (markers are always emitted)
	local fn_ref = find_event(evts, "inline_start", "footnote_ref")
	testimony.assert_true(fn_ref ~= nil)
	-- But no footnotes block (no definitions to render)
	local fn_block = find_event(evts, "block_start", "footnotes")
	testimony.assert_nil(fn_block)
end)

-- ============================================
-- Fenced Div Detection Tests
-- ============================================

testify:that("state detects div fence opening", function()
	local len, class, indent = state.detect_div_fence_open("::: warning")
	testimony.assert_equal(3, len)
	testimony.assert_equal("warning", class)
	testimony.assert_equal(0, indent)
end)

testify:that("state detects div fence without class", function()
	local len, class, indent = state.detect_div_fence_open(":::")
	testimony.assert_equal(3, len)
	testimony.assert_equal("", class)
end)

testify:that("state detects longer div fence", function()
	local len, class, indent = state.detect_div_fence_open("::::: note")
	testimony.assert_equal(5, len)
	testimony.assert_equal("note", class)
end)

testify:that("state detects div fence with indent", function()
	local len, class, indent = state.detect_div_fence_open("  ::: tip")
	testimony.assert_equal(3, len)
	testimony.assert_equal("tip", class)
	testimony.assert_equal(2, indent)
end)

testify:that("state detects div fence close", function()
	testimony.assert_true(state.is_div_fence_close(":::", 3))
	testimony.assert_true(state.is_div_fence_close("::::", 3))
	testimony.assert_false(state.is_div_fence_close("::", 3))
end)

testify:that("state rejects invalid div fence", function()
	-- Too few colons
	testimony.assert_nil(state.detect_div_fence_open("::"))
	-- Too much indentation
	testimony.assert_nil(state.detect_div_fence_open("    ::: note"))
end)

-- ============================================
-- Fenced Div Parsing Tests
-- ============================================

testify:that("parses simple div", function()
	local input = "::: warning\nWarning content.\n:::"
	local evts = markdown.parse(input, { inline = false })
	-- Should have div start and end
	local div_start = find_event(evts, "block_start", "div")
	testimony.assert_true(div_start ~= nil)
	testimony.assert_equal("warning", div_start.attrs.class)
	testimony.assert_equal(1, count_events(evts, "block_end", "div"))
end)

testify:that("parses div without class", function()
	local input = ":::\nContent.\n:::"
	local evts = markdown.parse(input, { inline = false })
	local div_start = find_event(evts, "block_start", "div")
	testimony.assert_true(div_start ~= nil)
	testimony.assert_nil(div_start.attrs) -- No class = no attrs
end)

testify:that("div contains paragraphs", function()
	local input = "::: note\nFirst para.\n\nSecond para.\n:::"
	local evts = markdown.parse(input, { inline = false })
	testimony.assert_equal(1, count_events(evts, "block_start", "div"))
	testimony.assert_equal(2, count_events(evts, "block_start", "para"))
end)

testify:that("nested divs", function()
	local input = "::: outer\n:::: inner\nContent.\n::::\n:::"
	local evts = markdown.parse(input, { inline = false })
	-- Should have 2 div starts
	local divs = find_all_events(evts, "block_start", "div")
	testimony.assert_equal(2, #divs)
	testimony.assert_equal("outer", divs[1].attrs.class)
	testimony.assert_equal("inner", divs[2].attrs.class)
end)

testify:that("unclosed div is closed at finish", function()
	local input = "::: warning\nContent without close."
	local evts = markdown.parse(input, { inline = false })
	-- Should still have matching start and end
	testimony.assert_equal(1, count_events(evts, "block_start", "div"))
	testimony.assert_equal(1, count_events(evts, "block_end", "div"))
end)

-- ============================================
-- Inline Attribute Tests
-- ============================================

testify:that("parses inline code with class attribute", function()
	local input = "`code`{.lua}"
	local evts = markdown.parse(input, { streaming_inline = false })
	local code_start = find_event(evts, "inline_start", "code")
	testimony.assert_true(code_start ~= nil)
	testimony.assert_true(code_start.attrs ~= nil)
	testimony.assert_equal("lua", code_start.attrs.class)
end)

testify:that("parses inline code with id attribute", function()
	local input = "`code`{#myid}"
	local evts = markdown.parse(input, { streaming_inline = false })
	local code_start = find_event(evts, "inline_start", "code")
	testimony.assert_true(code_start ~= nil)
	testimony.assert_true(code_start.attrs ~= nil)
	testimony.assert_equal("myid", code_start.attrs.id)
end)

testify:that("parses inline code with multiple attributes", function()
	local input = "`code`{.highlight #example}"
	local evts = markdown.parse(input, { streaming_inline = false })
	local code_start = find_event(evts, "inline_start", "code")
	testimony.assert_true(code_start ~= nil)
	testimony.assert_true(code_start.attrs ~= nil)
	testimony.assert_equal("highlight", code_start.attrs.class)
	testimony.assert_equal("example", code_start.attrs.id)
end)

testify:that("parses link with attributes", function()
	local input = "[text](url){.special}"
	local evts = markdown.parse(input, { streaming_inline = false })
	local link_start = find_event(evts, "inline_start", "link")
	testimony.assert_true(link_start ~= nil)
	testimony.assert_equal("url", link_start.attrs.href)
	testimony.assert_equal("special", link_start.attrs.class)
end)

testify:that("parses image with attributes", function()
	local input = "![alt](src.png){.thumbnail}"
	local evts = markdown.parse(input, { streaming_inline = false })
	local img_start = find_event(evts, "inline_start", "image")
	testimony.assert_true(img_start ~= nil)
	testimony.assert_equal("src.png", img_start.attrs.href)
	testimony.assert_equal("thumbnail", img_start.attrs.class)
end)

testify:that("parses key=value attribute", function()
	local input = "`code`{lang=python}"
	local evts = markdown.parse(input, { streaming_inline = false })
	local code_start = find_event(evts, "inline_start", "code")
	testimony.assert_true(code_start ~= nil)
	testimony.assert_true(code_start.attrs ~= nil)
	testimony.assert_equal("python", code_start.attrs.lang)
end)

testify:that("parses quoted attribute value", function()
	local input = '`code`{title="My Title"}'
	local evts = markdown.parse(input, { streaming_inline = false })
	local code_start = find_event(evts, "inline_start", "code")
	testimony.assert_true(code_start ~= nil)
	testimony.assert_true(code_start.attrs ~= nil)
	testimony.assert_equal("My Title", code_start.attrs.title)
end)

testify:that("invalid attribute block becomes literal", function()
	local input = "text{invalid"
	local evts = markdown.parse(input, { streaming_inline = false })
	-- Should have literal text including the brace
	local texts = find_all_events(evts, "text")
	local combined = ""
	for _, t in ipairs(texts) do
		combined = combined .. (t.text or "")
	end
	testimony.assert_match("{invalid", combined)
end)

-- ============================================
-- Integration Tests
-- ============================================

testify:that("reference link and footnote in same document", function()
	-- Note: Definitions must come BEFORE usage in streaming mode
	local input = "[ref]: https://example.com\n[^note]: A footnote.\n\nSee [example][ref] for details[^note]."
	local evts = markdown.parse(input, { streaming_inline = false })
	-- Should have both link and footnote
	local link = find_event(evts, "inline_start", "link")
	testimony.assert_true(link ~= nil)
	testimony.assert_equal("https://example.com", link.attrs.href)
	local fn_ref = find_event(evts, "inline_start", "footnote_ref")
	testimony.assert_true(fn_ref ~= nil)
	local fn_block = find_event(evts, "block_start", "footnote")
	testimony.assert_true(fn_block ~= nil)
end)

testify:that("div with reference link inside", function()
	-- Note: Definition must come BEFORE usage in streaming mode
	local input = "[example]: https://example.com\n\n::: note\nSee [example][].\n:::"
	local evts = markdown.parse(input, { streaming_inline = false })
	local div = find_event(evts, "block_start", "div")
	testimony.assert_true(div ~= nil)
	local link = find_event(evts, "inline_start", "link")
	testimony.assert_true(link ~= nil)
	testimony.assert_equal("https://example.com", link.attrs.href)
end)

testify:that("footnote with inline markup", function()
	-- Note: Definition must come BEFORE usage in streaming mode
	local input = "[^note]: This is **bold** in a footnote.\n\nText[^note]."
	local evts = markdown.parse(input, { streaming_inline = false })
	-- Footnote content should be parsed for inline elements
	local strong = find_event(evts, "inline_start", "strong")
	testimony.assert_true(strong ~= nil)
end)

-- ============================================
-- Inline Code Class Styling Tests
-- ============================================

-- These tests verify that class attributes on inline code
-- are used for TSS styling (e.g., `value`{.num} renders with code.num style)

local theme = require("markdown.renderer.theme")

-- Create a test RSS (raw style sheet) with distinctive markers for classes
-- Note: markdown.render expects an RSS table, not a TSS object
local function create_test_rss()
	-- Override code with distinctive markers for testing
	return {
		code = {
			fg = 249,
			before = "[C:",
			after = ":C]",
			num = { before = "[NUM:", after = ":NUM]" },
			str = { before = "[STR:", after = ":STR]" },
			req = { s = "bold", before = "[REQ:", after = ":REQ]" },
		},
	}
end

testify:that("inline code with single class applies class style", function()
	local test_rss = create_test_rss()
	local input = "`123`{.num}"
	local result = markdown.render(input, { tss = test_rss })
	-- Should have the num markers
	testimony.assert_true(result:find("[NUM:", 1, true) ~= nil)
	testimony.assert_true(result:find(":NUM]", 1, true) ~= nil)
	-- Should NOT have base code markers (num style overrides)
	testimony.assert_nil(result:find("[C:", 1, true))
end)

testify:that("inline code with multiple classes applies all class styles", function()
	local test_rss = create_test_rss()
	local input = "`value`{.num .req}"
	local result = markdown.render(input, { tss = test_rss })
	-- Should have both num and req markers (cascaded)
	-- TSS cascading: base code -> code.num -> code.req
	-- The last one's before/after should win
	testimony.assert_true(result:find("[REQ:", 1, true) ~= nil)
	testimony.assert_true(result:find(":REQ]", 1, true) ~= nil)
end)

testify:that("inline code without class uses base code style", function()
	local test_rss = create_test_rss()
	local input = "`plain`"
	local result = markdown.render(input, { tss = test_rss })
	-- Should have base code markers
	testimony.assert_true(result:find("[C:", 1, true) ~= nil)
	testimony.assert_true(result:find(":C]", 1, true) ~= nil)
	-- Should NOT have class-specific markers
	testimony.assert_nil(result:find("[NUM:", 1, true))
	testimony.assert_nil(result:find("[STR:", 1, true))
end)

testify:that("inline code class works in paragraph context", function()
	local test_rss = create_test_rss()
	local input = "The value is `42`{.num} which is a number."
	local result = markdown.render(input, { tss = test_rss })
	-- Should have the num markers around the code
	testimony.assert_true(result:find("[NUM:", 1, true) ~= nil)
	testimony.assert_true(result:find("42", 1, true) ~= nil)
end)

testify:that("multiple inline codes with different classes", function()
	local test_rss = create_test_rss()
	local input = "Number: `123`{.num}, String: `hello`{.str}"
	local result = markdown.render(input, { tss = test_rss })
	-- Should have both num and str markers
	testimony.assert_true(result:find("[NUM:", 1, true) ~= nil)
	testimony.assert_true(result:find("[STR:", 1, true) ~= nil)
end)

testify:conclude()
