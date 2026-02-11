-- SPDX-FileCopyrightText: © 2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: OWL-1.0 or later
-- Licensed under the Open Weights License v1.0. See LICENSE for details.

local testimony = require("testimony")
local inline = require("markdown.inline")
local buffer = require("markdown.buffer")
local markdown = require("markdown")

local testify = testimony.new("== markdown.inline ==")

-- Helper to collect events from inline parser
local function parse_inline(text)
	local events = {}
	local parser = inline.new(function(e)
		events[#events + 1] = e
	end)
	parser:parse(text)
	return events
end

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

-- Helper to extract all text from events
local function extract_text(evts)
	local texts = {}
	for _, e in ipairs(evts) do
		if e.type == "text" then
			texts[#texts + 1] = e.text
		end
	end
	return table.concat(texts)
end

-- ============================================
-- Basic Emphasis Tests
-- ============================================

testify:that("parses single asterisk emphasis", function()
	local evts = parse_inline("*italic*")
	testimony.assert_equal(1, count_events(evts, "inline_start", "emph"))
	testimony.assert_equal(1, count_events(evts, "inline_end", "emph"))
	testimony.assert_equal("italic", extract_text(evts))
end)

testify:that("parses single underscore emphasis", function()
	local evts = parse_inline("_italic_")
	testimony.assert_equal(1, count_events(evts, "inline_start", "emph"))
	testimony.assert_equal(1, count_events(evts, "inline_end", "emph"))
	testimony.assert_equal("italic", extract_text(evts))
end)

testify:that("parses double asterisk strong", function()
	local evts = parse_inline("**bold**")
	testimony.assert_equal(1, count_events(evts, "inline_start", "strong"))
	testimony.assert_equal(1, count_events(evts, "inline_end", "strong"))
	testimony.assert_equal("bold", extract_text(evts))
end)

testify:that("parses double underscore strong", function()
	local evts = parse_inline("__bold__")
	testimony.assert_equal(1, count_events(evts, "inline_start", "strong"))
	testimony.assert_equal(1, count_events(evts, "inline_end", "strong"))
	testimony.assert_equal("bold", extract_text(evts))
end)

testify:that("parses nested emphasis inside strong", function()
	local evts = parse_inline("**bold _and italic_**")
	testimony.assert_equal(1, count_events(evts, "inline_start", "strong"))
	testimony.assert_equal(1, count_events(evts, "inline_start", "emph"))
	testimony.assert_equal(1, count_events(evts, "inline_end", "emph"))
	testimony.assert_equal(1, count_events(evts, "inline_end", "strong"))
end)

testify:that("parses emphasis at start of text", function()
	local evts = parse_inline("*italic* text")
	testimony.assert_equal(1, count_events(evts, "inline_start", "emph"))
	testimony.assert_equal(1, count_events(evts, "inline_end", "emph"))
end)

testify:that("parses emphasis at end of text", function()
	local evts = parse_inline("text *italic*")
	testimony.assert_equal(1, count_events(evts, "inline_start", "emph"))
	testimony.assert_equal(1, count_events(evts, "inline_end", "emph"))
end)

testify:that("parses emphasis in middle of text", function()
	local evts = parse_inline("before *italic* after")
	testimony.assert_equal(1, count_events(evts, "inline_start", "emph"))
	testimony.assert_equal(1, count_events(evts, "inline_end", "emph"))
	testimony.assert_true(extract_text(evts):find("before"))
	testimony.assert_true(extract_text(evts):find("after"))
end)

-- ============================================
-- CommonMark Flanking Rules Tests
-- ============================================

testify:that("intra-word underscores are literal", function()
	-- CommonMark: foo_bar_baz should not have emphasis
	local evts = parse_inline("foo_bar_baz")
	testimony.assert_equal(0, count_events(evts, "inline_start", "emph"))
	testimony.assert_equal("foo_bar_baz", extract_text(evts))
end)

testify:that("intra-word asterisks create emphasis", function()
	-- CommonMark: asterisks don't have the intra-word restriction
	local evts = parse_inline("foo*bar*baz")
	testimony.assert_equal(1, count_events(evts, "inline_start", "emph"))
	testimony.assert_equal(1, count_events(evts, "inline_end", "emph"))
end)

testify:that("underscore after punctuation can open", function()
	-- Punctuation before underscore allows opening
	local evts = parse_inline("(_italic_)")
	testimony.assert_equal(1, count_events(evts, "inline_start", "emph"))
end)

testify:that("underscore before punctuation can close", function()
	local evts = parse_inline("_italic_.")
	testimony.assert_equal(1, count_events(evts, "inline_start", "emph"))
	testimony.assert_equal(1, count_events(evts, "inline_end", "emph"))
end)

testify:that("asterisk followed by space does not open", function()
	local evts = parse_inline("* not emphasis")
	testimony.assert_equal(0, count_events(evts, "inline_start", "emph"))
	testimony.assert_true(extract_text(evts):find("^%* "))
end)

testify:that("asterisk preceded by space does not close", function()
	local evts = parse_inline("*not emphasis *")
	-- The first * opens but the second can't close (preceded by space)
	-- So should be literal
	testimony.assert_equal(0, count_events(evts, "inline_end", "emph"))
end)

-- ============================================
-- Inline Code Tests
-- ============================================

testify:that("parses inline code with single backtick", function()
	local evts = parse_inline("`code`")
	testimony.assert_equal(1, count_events(evts, "inline_start", "code"))
	testimony.assert_equal(1, count_events(evts, "inline_end", "code"))
	testimony.assert_equal("code", extract_text(evts))
end)

testify:that("parses inline code with double backticks", function()
	local evts = parse_inline("``code with `backtick` inside``")
	testimony.assert_equal(1, count_events(evts, "inline_start", "code"))
	testimony.assert_equal(1, count_events(evts, "inline_end", "code"))
	-- Content should preserve the inner backticks
	testimony.assert_true(extract_text(evts):find("`backtick`"))
end)

testify:that("inline code strips surrounding spaces", function()
	-- CommonMark: strip one leading and trailing space if both present
	local evts = parse_inline("` code `")
	testimony.assert_equal("code", extract_text(evts))
end)

testify:that("inline code preserves internal spaces", function()
	local evts = parse_inline("`code  here`")
	testimony.assert_equal("code  here", extract_text(evts))
end)

testify:that("inline code content is not parsed for emphasis", function()
	local evts = parse_inline("`*not italic*`")
	testimony.assert_equal(0, count_events(evts, "inline_start", "emph"))
	testimony.assert_equal("*not italic*", extract_text(evts))
end)

testify:that("unmatched backticks are literal", function()
	local evts = parse_inline("a ` b")
	testimony.assert_equal(0, count_events(evts, "inline_start", "code"))
	testimony.assert_true(extract_text(evts):find("`"))
end)

testify:that("backtick count must match exactly", function()
	local evts = parse_inline("``code`")
	-- Two backticks open, one backtick can't close
	testimony.assert_equal(0, count_events(evts, "inline_end", "code"))
end)

-- ============================================
-- Link Tests
-- ============================================

testify:that("parses inline link", function()
	local evts = parse_inline("[link text](https://example.com)")
	local start_evt = find_event(evts, "inline_start", "link")
	testimony.assert_true(start_evt ~= nil, "expected link event")
	testimony.assert_equal("https://example.com", start_evt.attrs.href)
	testimony.assert_equal(1, count_events(evts, "inline_end", "link"))
end)

testify:that("parses link with title", function()
	local evts = parse_inline('[link](url "title")')
	local start_evt = find_event(evts, "inline_start", "link")
	testimony.assert_true(start_evt ~= nil, "expected link event")
	testimony.assert_equal("url", start_evt.attrs.href)
	testimony.assert_equal("title", start_evt.attrs.title)
end)

testify:that("parses link text with emphasis", function()
	local evts = parse_inline("[*italic* link](url)")
	testimony.assert_equal(1, count_events(evts, "inline_start", "link"))
	testimony.assert_equal(1, count_events(evts, "inline_start", "emph"))
end)

testify:that("parses link with angle-bracketed URL", function()
	local evts = parse_inline("[link](<url with spaces>)")
	local start_evt = find_event(evts, "inline_start", "link")
	testimony.assert_true(start_evt ~= nil, "expected link event")
	testimony.assert_equal("url with spaces", start_evt.attrs.href)
end)

testify:that("handles nested parentheses in URL", function()
	local evts = parse_inline("[link](url(with)parens)")
	local start_evt = find_event(evts, "inline_start", "link")
	testimony.assert_true(start_evt ~= nil, "expected link event")
	testimony.assert_equal("url(with)parens", start_evt.attrs.href)
end)

testify:that("unmatched bracket is literal", function()
	local evts = parse_inline("[not a link")
	testimony.assert_equal(0, count_events(evts, "inline_start", "link"))
	testimony.assert_true(extract_text(evts):find("%["))
end)

testify:that("bracket without destination is literal", function()
	local evts = parse_inline("[text] no link")
	testimony.assert_equal(0, count_events(evts, "inline_start", "link"))
end)

-- ============================================
-- Image Tests
-- ============================================

testify:that("parses image", function()
	local evts = parse_inline("![alt text](image.png)")
	local start_evt = find_event(evts, "inline_start", "image")
	testimony.assert_true(start_evt ~= nil, "expected image event")
	testimony.assert_equal("image.png", start_evt.attrs.href)
	testimony.assert_equal(1, count_events(evts, "inline_end", "image"))
end)

testify:that("parses image with title", function()
	local evts = parse_inline('![alt](img.png "title")')
	local start_evt = find_event(evts, "inline_start", "image")
	testimony.assert_true(start_evt ~= nil, "expected image event")
	testimony.assert_equal("title", start_evt.attrs.title)
end)

testify:that("image alt text is parsed for inline", function()
	local evts = parse_inline("![*italic* alt](img.png)")
	testimony.assert_equal(1, count_events(evts, "inline_start", "image"))
	testimony.assert_equal(1, count_events(evts, "inline_start", "emph"))
end)

-- ============================================
-- Escape Tests
-- ============================================

testify:that("backslash escapes asterisk", function()
	local evts = parse_inline("\\*not italic\\*")
	testimony.assert_equal(0, count_events(evts, "inline_start", "emph"))
	testimony.assert_equal("*not italic*", extract_text(evts))
end)

testify:that("backslash escapes underscore", function()
	local evts = parse_inline("\\_not italic\\_")
	testimony.assert_equal(0, count_events(evts, "inline_start", "emph"))
	testimony.assert_equal("_not italic_", extract_text(evts))
end)

testify:that("backslash escapes backtick", function()
	local evts = parse_inline("\\`not code\\`")
	testimony.assert_equal(0, count_events(evts, "inline_start", "code"))
	testimony.assert_equal("`not code`", extract_text(evts))
end)

testify:that("backslash escapes bracket", function()
	local evts = parse_inline("\\[not a link\\](url)")
	testimony.assert_equal(0, count_events(evts, "inline_start", "link"))
end)

testify:that("backslash before non-punctuation is literal", function()
	local evts = parse_inline("\\a")
	testimony.assert_equal("\\a", extract_text(evts))
end)

testify:that("double backslash produces single backslash", function()
	local evts = parse_inline("\\\\")
	testimony.assert_equal("\\", extract_text(evts))
end)

-- ============================================
-- Edge Cases
-- ============================================

testify:that("handles empty input", function()
	local evts = parse_inline("")
	testimony.assert_equal(0, #evts)
end)

testify:that("handles plain text only", function()
	local evts = parse_inline("just plain text")
	testimony.assert_equal(1, count_events(evts, "text"))
	testimony.assert_equal("just plain text", extract_text(evts))
end)

testify:that("handles multiple emphasis in sequence", function()
	local evts = parse_inline("*a* *b* *c*")
	testimony.assert_equal(3, count_events(evts, "inline_start", "emph"))
	testimony.assert_equal(3, count_events(evts, "inline_end", "emph"))
end)

testify:that("handles triple asterisks as strong+emph", function()
	-- ***text*** = strong wrapping emph, or emph wrapping strong
	local evts = parse_inline("***text***")
	-- Should have both strong and emph
	testimony.assert_true(count_events(evts, "inline_start", "strong") >= 1)
	testimony.assert_true(count_events(evts, "inline_start", "emph") >= 1)
end)

testify:that("handles empty emphasis gracefully", function()
	-- ** ** = no emphasis (empty)
	local evts = parse_inline("****")
	-- Should be literal asterisks or empty emphasis
	-- CommonMark treats **** as literal
	testimony.assert_equal(0, count_events(evts, "inline_start", "strong"))
end)

testify:that("handles adjacent emphasis", function()
	local evts = parse_inline("*a**b*")
	-- This is tricky: could be interpreted different ways
	-- At minimum, should not crash
	testimony.assert_true(#evts >= 1)
end)

-- ============================================
-- Streaming Buffer Tests
-- ============================================

testify:that("buffer handles chunk boundary in emphasis", function()
	local evts = {}
	local buf = buffer.new({
		emit = function(e)
			evts[#evts + 1] = e
		end,
	})
	buf:feed("**bo")
	buf:feed("ld**")
	buf:flush()
	testimony.assert_equal(1, count_events(evts, "inline_start", "strong"))
	testimony.assert_equal(1, count_events(evts, "inline_end", "strong"))
end)

testify:that("buffer handles chunk boundary in link", function()
	local evts = {}
	local buf = buffer.new({
		emit = function(e)
			evts[#evts + 1] = e
		end,
	})
	buf:feed("[lin")
	buf:feed("k](url)")
	buf:flush()
	testimony.assert_equal(1, count_events(evts, "inline_start", "link"))
end)

testify:that("buffer emits at word boundary when safe", function()
	local evts = {}
	local buf = buffer.new({
		emit = function(e)
			evts[#evts + 1] = e
		end,
	})
	buf:feed("hello world ")
	-- Should emit "hello world " since no unclosed syntax
	testimony.assert_true(#evts > 0 or buf:get_buffer() == "")
end)

testify:that("buffer handles stale opener timeout", function()
	local evts = {}
	local buf = buffer.new({
		emit = function(e)
			evts[#evts + 1] = e
		end,
		stale_opener_threshold = 10,
	})
	-- Feed an opener followed by lots of text without closing
	buf:feed("**" .. string.rep("x", 20))
	-- Should have emitted something due to threshold
	testimony.assert_true(#evts > 0)
end)

-- ============================================
-- Integration with Block Parser
-- (Using streaming_inline=false for deterministic behavior)
-- ============================================

testify:that("paragraph content is parsed for inline", function()
	local evts = markdown.parse("This is **bold** text", { streaming_inline = false })
	testimony.assert_equal(1, count_events(evts, "inline_start", "strong"))
	testimony.assert_equal(1, count_events(evts, "inline_end", "strong"))
end)

testify:that("heading content is parsed for inline", function()
	local evts = markdown.parse("# Heading with *emphasis*", { streaming_inline = false })
	testimony.assert_equal(1, count_events(evts, "inline_start", "emph"))
	testimony.assert_equal(1, count_events(evts, "inline_end", "emph"))
end)

testify:that("code block content is NOT parsed for inline", function()
	local evts = markdown.parse("```\n**not bold**\n```", { streaming_inline = false })
	testimony.assert_equal(0, count_events(evts, "inline_start", "strong"))
	-- But we should have the text
	testimony.assert_true(extract_text(evts):find("%*%*not bold%*%*"))
end)

testify:that("inline parsing can be disabled", function()
	local evts = {}
	local parser = markdown.stream({
		on_event = function(e)
			evts[#evts + 1] = e
		end,
		inline = false,
	})
	parser:feed("**not parsed**")
	parser:finish()
	testimony.assert_equal(0, count_events(evts, "inline_start", "strong"))
	testimony.assert_true(extract_text(evts):find("%*%*"))
end)

testify:that("multi-line paragraph with inline elements", function()
	local evts = markdown.parse("First *italic*\nSecond **bold**", { streaming_inline = false })
	testimony.assert_equal(1, count_events(evts, "inline_start", "emph"))
	testimony.assert_equal(1, count_events(evts, "inline_start", "strong"))
end)

-- ============================================
-- Cross-Line Emphasis Tests (inline parser with \n)
-- ============================================

testify:that("parses strong emphasis across lines", function()
	local evts = parse_inline("**bold\nacross lines**")
	testimony.assert_equal(1, count_events(evts, "inline_start", "strong"))
	testimony.assert_equal(1, count_events(evts, "inline_end", "strong"))
	testimony.assert_equal(1, count_events(evts, "softbreak"))
end)

testify:that("parses emphasis across lines", function()
	local evts = parse_inline("*italic\nacross lines*")
	testimony.assert_equal(1, count_events(evts, "inline_start", "emph"))
	testimony.assert_equal(1, count_events(evts, "inline_end", "emph"))
	testimony.assert_equal(1, count_events(evts, "softbreak"))
end)

testify:that("parses nested emphasis across lines", function()
	local evts = parse_inline("**bold\nwith *nested italic*\nacross lines**")
	testimony.assert_equal(1, count_events(evts, "inline_start", "strong"))
	testimony.assert_equal(1, count_events(evts, "inline_end", "strong"))
	testimony.assert_equal(1, count_events(evts, "inline_start", "emph"))
	testimony.assert_equal(1, count_events(evts, "inline_end", "emph"))
	testimony.assert_equal(2, count_events(evts, "softbreak"))
end)

testify:that("mixed same-line and cross-line emphasis", function()
	local evts = parse_inline("*a* and **bold\nacross** here")
	testimony.assert_equal(1, count_events(evts, "inline_start", "emph"))
	testimony.assert_equal(1, count_events(evts, "inline_end", "emph"))
	testimony.assert_equal(1, count_events(evts, "inline_start", "strong"))
	testimony.assert_equal(1, count_events(evts, "inline_end", "strong"))
	testimony.assert_equal(1, count_events(evts, "softbreak"))
end)

-- ============================================
-- Cross-Line Emphasis Integration Tests (block parser)
-- ============================================

testify:that("multi-line paragraph with cross-line strong", function()
	local evts =
		markdown.parse("This is **bold text that\ncontinues on the next line** here.", { streaming_inline = false })
	testimony.assert_equal(1, count_events(evts, "inline_start", "strong"))
	testimony.assert_equal(1, count_events(evts, "inline_end", "strong"))
	testimony.assert_equal(1, count_events(evts, "softbreak"))
end)

testify:that("multi-line paragraph with cross-line emph", function()
	local evts = markdown.parse("This is *italic text that\ncontinues* here.", { streaming_inline = false })
	testimony.assert_equal(1, count_events(evts, "inline_start", "emph"))
	testimony.assert_equal(1, count_events(evts, "inline_end", "emph"))
end)

testify:that("multi-line paragraph preserves same-line emphasis", function()
	-- Existing behavior must still work
	local evts = markdown.parse("First *italic*\nSecond **bold**", { streaming_inline = false })
	testimony.assert_equal(1, count_events(evts, "inline_start", "emph"))
	testimony.assert_equal(1, count_events(evts, "inline_start", "strong"))
end)

-- ============================================
-- GFM Strikethrough Tests
-- ============================================

testify:that("parses double tilde strikethrough", function()
	local evts = parse_inline("~~deleted~~")
	testimony.assert_equal(1, count_events(evts, "inline_start", "strikethrough"))
	testimony.assert_equal(1, count_events(evts, "inline_end", "strikethrough"))
	testimony.assert_equal("deleted", extract_text(evts))
end)

testify:that("single tilde is literal", function()
	local evts = parse_inline("~not deleted~")
	-- Single tilde should not create strikethrough
	testimony.assert_equal(0, count_events(evts, "inline_start", "strikethrough"))
	testimony.assert_true(extract_text(evts):find("~"))
end)

testify:that("strikethrough with emphasis inside", function()
	local evts = parse_inline("~~deleted *and italic*~~")
	testimony.assert_equal(1, count_events(evts, "inline_start", "strikethrough"))
	testimony.assert_equal(1, count_events(evts, "inline_start", "emph"))
end)

testify:that("strikethrough in middle of text", function()
	local evts = parse_inline("before ~~deleted~~ after")
	testimony.assert_equal(1, count_events(evts, "inline_start", "strikethrough"))
	testimony.assert_true(extract_text(evts):find("before"))
	testimony.assert_true(extract_text(evts):find("after"))
end)

testify:that("unmatched strikethrough is literal", function()
	local evts = parse_inline("~~not closed")
	testimony.assert_equal(0, count_events(evts, "inline_end", "strikethrough"))
	testimony.assert_true(extract_text(evts):find("~~"))
end)

testify:that("triple tilde creates strikethrough with extra tilde", function()
	-- ~~~text~~~ = strikethrough with one extra tilde on each side
	local evts = parse_inline("~~~text~~~")
	-- Should have at least one strikethrough
	testimony.assert_true(count_events(evts, "inline_start", "strikethrough") >= 1)
end)

-- ============================================
-- GFM Autolink Tests
-- ============================================

testify:that("parses URL autolink", function()
	local evts = parse_inline("<https://example.com>")
	local start_evt = find_event(evts, "inline_start", "link")
	testimony.assert_true(start_evt ~= nil, "expected link event")
	testimony.assert_equal("https://example.com", start_evt.attrs.href)
	testimony.assert_true(start_evt.attrs.autolink)
end)

testify:that("parses HTTP autolink", function()
	local evts = parse_inline("<http://example.com/path>")
	local start_evt = find_event(evts, "inline_start", "link")
	testimony.assert_true(start_evt ~= nil, "expected link event")
	testimony.assert_equal("http://example.com/path", start_evt.attrs.href)
end)

testify:that("parses email autolink", function()
	local evts = parse_inline("<user@example.com>")
	local start_evt = find_event(evts, "inline_start", "link")
	testimony.assert_true(start_evt ~= nil, "expected link event")
	testimony.assert_equal("mailto:user@example.com", start_evt.attrs.href)
	testimony.assert_true(start_evt.attrs.autolink)
end)

testify:that("autolink displays URL text", function()
	local evts = parse_inline("<https://example.com>")
	testimony.assert_equal("https://example.com", extract_text(evts))
end)

testify:that("email autolink displays email text", function()
	local evts = parse_inline("<user@example.com>")
	testimony.assert_equal("user@example.com", extract_text(evts))
end)

testify:that("invalid autolink is literal", function()
	local evts = parse_inline("<not a link>")
	testimony.assert_equal(0, count_events(evts, "inline_start", "link"))
	testimony.assert_true(extract_text(evts):find("<"))
end)

testify:that("autolink with other schemes", function()
	local evts = parse_inline("<ftp://files.example.com>")
	local start_evt = find_event(evts, "inline_start", "link")
	testimony.assert_true(start_evt ~= nil, "expected link event")
	testimony.assert_equal("ftp://files.example.com", start_evt.attrs.href)
end)

testify:that("autolink in context", function()
	local evts = parse_inline("Check out <https://example.com> for more")
	testimony.assert_equal(1, count_events(evts, "inline_start", "link"))
	testimony.assert_true(extract_text(evts):find("Check out"))
end)

-- ============================================
-- Footnote Reference Tests
-- ============================================

testify:that("parses footnote reference", function()
	local evts = {}
	local parser = inline.new({
		emit = function(e)
			evts[#evts + 1] = e
		end,
		footnote_tracker = { used = {} },
	})
	parser:parse("text[^1] more")
	local start_evt = find_event(evts, "inline_start", "footnote_ref")
	testimony.assert_true(start_evt ~= nil, "expected footnote_ref event")
	testimony.assert_equal("1", start_evt.attrs.label)
end)

testify:that("footnote reference after exclamation mark", function()
	-- This was a bug: ![^1] was being parsed as image open, not ! + footnote
	local evts = {}
	local parser = inline.new({
		emit = function(e)
			evts[#evts + 1] = e
		end,
		footnote_tracker = { used = {} },
	})
	parser:parse("text![^1]")
	local start_evt = find_event(evts, "inline_start", "footnote_ref")
	testimony.assert_true(start_evt ~= nil, "expected footnote_ref after !")
	testimony.assert_equal("1", start_evt.attrs.label)
	-- Should also have the ! in the text
	testimony.assert_true(extract_text(evts):find("!"))
end)

testify:that("footnote reference with alpha label", function()
	local evts = {}
	local parser = inline.new({
		emit = function(e)
			evts[#evts + 1] = e
		end,
		footnote_tracker = { used = {} },
	})
	parser:parse("[^note]")
	local start_evt = find_event(evts, "inline_start", "footnote_ref")
	testimony.assert_true(start_evt ~= nil, "expected footnote_ref event")
	testimony.assert_equal("note", start_evt.attrs.label)
end)

testify:that("footnote reference label is normalized to lowercase", function()
	local evts = {}
	local parser = inline.new({
		emit = function(e)
			evts[#evts + 1] = e
		end,
		footnote_tracker = { used = {} },
	})
	parser:parse("[^NOTE]")
	local start_evt = find_event(evts, "inline_start", "footnote_ref")
	testimony.assert_equal("note", start_evt.attrs.label)
end)

testify:that("regular image still works", function()
	-- Make sure we didn't break images
	local evts = parse_inline("![alt text](image.png)")
	local start_evt = find_event(evts, "inline_start", "image")
	testimony.assert_true(start_evt ~= nil, "expected image event")
end)

testify:conclude()
