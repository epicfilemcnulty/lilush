-- SPDX-FileCopyrightText: © 2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: OWL-1.0 or later
-- Licensed under the Open Weights License v1.0. See LICENSE for details.

local testimony = require("testimony")
local style = require("term.tss")
local std = require("std")

local testify = testimony.new("== term.tss ==")

-- Helper function to strip ANSI codes for easier testing
local strip_ansi = function(str)
	-- Strip all ANSI escape sequences
	return str:gsub("\027%[[%d;]*m", "")
end

-- =============================================================================
-- BASIC TSS OBJECT CREATION
-- =============================================================================

testify:that("new creates TSS object with default window", function()
	local tss = style.new({})
	testimony.assert_true(tss.__window ~= nil)
	testimony.assert_true(tss.__window.w ~= nil)
	testimony.assert_true(tss.__window.h ~= nil)
end)

testify:that("new creates TSS object with provided RSS", function()
	local rss = { test = { fg = "red" } }
	local tss = style.new(rss)
	testimony.assert_equal(rss, tss.__style)
end)

testify:that("merge combines two RSS tables", function()
	local rss1 = { base = { fg = "red" } }
	local rss2 = { base = { bg = "blue" }, extra = { fg = "green" } }
	local tss = style.merge(rss1, rss2)
	testimony.assert_true(tss.__style.base.bg == "blue")
	testimony.assert_true(tss.__style.extra ~= nil)
end)

testify:that("scope creates isolated derived tss with deep overrides", function()
	local rss = {
		code_block = {
			w = 10,
			align = "none",
			border = { w = 10, v = { content = "|" } },
		},
	}
	local tss = style.new(rss, { supports_ts = false })
	tss.__window.w = 120
	tss.__window.h = 40

	local scoped = tss:scope({
		code_block = {
			w = 20,
			border = { w = 20 },
		},
	})

	testimony.assert_equal(10, tss.__style.code_block.w)
	testimony.assert_equal(10, tss.__style.code_block.border.w)
	testimony.assert_equal(20, scoped.__style.code_block.w)
	testimony.assert_equal(20, scoped.__style.code_block.border.w)
	testimony.assert_equal("|", scoped.__style.code_block.border.v.content)
	testimony.assert_equal(120, scoped.__window.w)
	testimony.assert_equal(40, scoped.__window.h)
	testimony.assert_equal(false, scoped.__supports_ts)
end)

testify:that("scope is independent from parent mutations", function()
	local rss = { test = { w = 0.5, align = "none", border = { w = 8 } } }
	local tss = style.new(rss)
	tss.__window.w = 80
	tss.__window.h = 24

	local scoped = tss:scope()
	scoped:set_property("test", "align", "left")
	scoped:set_property("test.border", "w", 30)

	testimony.assert_equal("none", tss:get_property("test", "align"))
	testimony.assert_equal(8, tss:get_property("test.border", "w"))

	local props, _ = scoped:get("test")
	testimony.assert_equal(40, props.w)
end)

-- =============================================================================
-- STYLE RESET BUG FIX (CRITICAL)
-- =============================================================================

testify:that("style reset properly clears accumulated styles", function()
	local rss = {
		base = {
			s = "bold,italic",
			test = { s = "reset,underlined" },
		},
	}
	local tss = style.new(rss)
	local props, _ = tss:get("base.test")

	-- After cascading base -> test, reset should clear bold,italic
	-- and only underlined should remain
	testimony.assert_equal(1, #props.s)
	testimony.assert_equal("underlined", props.s[1])
end)

testify:that("style reset in middle of list works", function()
	local rss = {
		test = { s = "bold,reset,italic" },
	}
	local tss = style.new(rss)
	local props, _ = tss:get("test")

	-- Reset should clear bold, then add italic
	testimony.assert_equal(1, #props.s)
	testimony.assert_equal("italic", props.s[1])
end)

testify:that("multiple resets work correctly", function()
	local rss = {
		test = { s = "bold,reset,italic,reset,underlined" },
	}
	local tss = style.new(rss)
	local props, _ = tss:get("test")

	testimony.assert_equal(1, #props.s)
	testimony.assert_equal("underlined", props.s[1])
end)

-- =============================================================================
-- WIDTH CALCULATION
-- =============================================================================

testify:that("calc_el_width handles absolute widths", function()
	local tss = style.new({})
	local width = tss:calc_el_width(10, 100)
	testimony.assert_equal(10, width)
end)

testify:that("calc_el_width treats w=1 as absolute one-cell width", function()
	local tss = style.new({})
	local width = tss:calc_el_width(1, 100)
	testimony.assert_equal(1, width)
end)

testify:that("calc_el_width handles fractional widths", function()
	local tss = style.new({})
	local width = tss:calc_el_width(0.5, 100)
	testimony.assert_equal(50, width)
end)

testify:that("calc_el_width floors fractional widths", function()
	local tss = style.new({})
	local width = tss:calc_el_width(0.99, 100)
	testimony.assert_equal(99, width)
end)

testify:that("calc_el_width clamps to max width", function()
	local tss = style.new({})
	local width = tss:calc_el_width(150, 100)
	testimony.assert_equal(100, width)
end)

testify:that("calc_el_width reaches full width via clamped absolute value", function()
	local tss = style.new({})
	local width = tss:calc_el_width(math.huge, 100)
	testimony.assert_equal(100, width)
end)

testify:that("calc_el_width returns 0 for zero or negative width", function()
	local tss = style.new({})
	testimony.assert_equal(0, tss:calc_el_width(0, 100))
	testimony.assert_equal(0, tss:calc_el_width(-5, 100))
end)

testify:that("calc_el_width handles fractional width with max=0", function()
	local tss = style.new({})
	-- Edge case fix: fractional width with max=0 should return 0, not 1
	local width = tss:calc_el_width(0.5, 0)
	testimony.assert_equal(0, width)
end)

testify:that("calc_el_width minimum fractional width is 1 when max>0", function()
	local tss = style.new({})
	local width = tss:calc_el_width(0.01, 100)
	testimony.assert_equal(1, width)
end)

-- =============================================================================
-- PROPERTY CASCADING
-- =============================================================================

testify:that("get cascades properties down dot-path", function()
	local rss = {
		base = { fg = "red", bg = "blue" },
		base = {
			fg = "red",
			child = { fg = "green" },
		},
	}
	local tss = style.new(rss)
	local props, _ = tss:get("base.child")

	-- child should inherit bg from base but override fg
	testimony.assert_equal("green", props.fg)
	testimony.assert_equal("reset", props.bg) -- base doesn't set bg, so it's default
end)

testify:that("get accumulates styles when cascading", function()
	local rss = {
		base = { s = "bold" },
		base = {
			s = "bold",
			child = { s = "italic" },
		},
	}
	local tss = style.new(rss)
	local props, _ = tss:get("base.child")

	-- Styles should accumulate: bold + italic
	testimony.assert_equal(2, #props.s)
	testimony.assert_true(std.tbl.contains(props.s, "bold") ~= nil)
	testimony.assert_true(std.tbl.contains(props.s, "italic") ~= nil)
end)

testify:that("get handles non-existent paths gracefully", function()
	local rss = { existing = { fg = "red" } }
	local tss = style.new(rss)
	local props, _ = tss:get("nonexistent.path")

	-- Should return default properties
	testimony.assert_equal("reset", props.fg)
	testimony.assert_equal("reset", props.bg)
end)

-- =============================================================================
-- PUBLIC API METHODS
-- =============================================================================

testify:that("set_property creates nested path and sets value", function()
	local tss = style.new({})
	tss:set_property("deep.nested.path", "fg", "cyan")

	testimony.assert_equal("cyan", tss.__style.deep.nested.path.fg)
end)

testify:that("set_property overwrites existing values", function()
	local rss = { test = { fg = "red" } }
	local tss = style.new(rss)
	tss:set_property("test", "fg", "blue")

	testimony.assert_equal("blue", tss.__style.test.fg)
end)

testify:that("get_property retrieves property value", function()
	local rss = { test = { fg = "magenta", w = 42 } }
	local tss = style.new(rss)

	testimony.assert_equal("magenta", tss:get_property("test", "fg"))
	testimony.assert_equal(42, tss:get_property("test", "w"))
end)

testify:that("get_property returns nil for non-existent path", function()
	local tss = style.new({})
	testimony.assert_nil(tss:get_property("nonexistent", "fg"))
end)

testify:that("get_property returns nil for non-existent property", function()
	local rss = { test = { fg = "red" } }
	local tss = style.new(rss)
	testimony.assert_nil(tss:get_property("test", "nonexistent"))
end)

-- =============================================================================
-- TEXT ALIGNMENT
-- =============================================================================

testify:that("apply aligns text left", function()
	local rss = { test = { w = 10, align = "left" } }
	local tss = style.new(rss)
	-- Set a reasonable window size for testing
	tss.__window.w = 80
	tss.__window.h = 24
	local result = strip_ansi(tss:apply("test", "hi").text)

	testimony.assert_equal(10, std.utf.len(result))
	testimony.assert_match("^hi", result)
end)

testify:that("apply aligns text right", function()
	local rss = { test = { w = 10, align = "right" } }
	local tss = style.new(rss)
	tss.__window.w = 80
	tss.__window.h = 24
	local result = strip_ansi(tss:apply("test", "hi").text)

	testimony.assert_equal(10, std.utf.len(result))
	testimony.assert_match("hi$", result)
end)

testify:that("apply aligns text center", function()
	local rss = { test = { w = 10, align = "center" } }
	local tss = style.new(rss)
	tss.__window.w = 80
	tss.__window.h = 24
	local result = strip_ansi(tss:apply("test", "hi").text)

	testimony.assert_equal(10, std.utf.len(result))
	-- Should have spaces on both sides
	testimony.assert_match("^%s+hi%s+$", result)
end)

-- =============================================================================
-- TEXT CLIPPING
-- =============================================================================

testify:that("apply clips text when too long (auto-clip)", function()
	local rss = { test = { w = 5, clip = 0 } } -- clip=0 means auto-clip to width
	local tss = style.new(rss)
	tss.__window.w = 80
	tss.__window.h = 24
	local result = strip_ansi(tss:apply("test", "very long text").text)

	-- Should be clipped to width 5 with ellipsis
	testimony.assert_equal(5, std.utf.len(result))
	testimony.assert_match("…", result)
end)

testify:that("apply respects explicit clip value", function()
	local rss = { test = { w = 10, clip = 3 } }
	local tss = style.new(rss)
	tss.__window.w = 80
	tss.__window.h = 24
	local result = strip_ansi(tss:apply("test", "hello world").text)

	-- Should show first 2 chars, ellipsis, then last 7 chars (10 - 3)
	testimony.assert_equal(10, std.utf.len(result))
	testimony.assert_match("he…", result)
end)

testify:that("apply with clip=-1 disables clipping", function()
	local rss = { test = { w = 5, clip = -1 } }
	local tss = style.new(rss)
	local result = strip_ansi(tss:apply("test", "longer text").text)

	-- Should NOT be clipped, but also won't be padded to width
	testimony.assert_true(std.utf.len(result) > 5)
end)

-- =============================================================================
-- CONTENT OVERRIDE AND DECORATORS
-- =============================================================================

testify:that("apply uses content override when specified", function()
	local rss = { test = { content = "OVERRIDE", clip = -1 } }
	local tss = style.new(rss)
	local result = strip_ansi(tss:apply("test", "original").text)

	testimony.assert_equal("OVERRIDE", result)
end)

testify:that("apply adds before decorator", function()
	local rss = { test = { before = "[", clip = -1 } }
	local tss = style.new(rss)
	local result = strip_ansi(tss:apply("test", "text").text)

	testimony.assert_equal("[text", result)
end)

testify:that("apply adds after decorator", function()
	local rss = { test = { after = "]", clip = -1 } }
	local tss = style.new(rss)
	local result = strip_ansi(tss:apply("test", "text").text)

	testimony.assert_equal("text]", result)
end)

testify:that("apply adds both before and after decorators", function()
	local rss = { test = { before = "[", after = "]", clip = -1 } }
	local tss = style.new(rss)
	local result = strip_ansi(tss:apply("test", "text").text)

	testimony.assert_equal("[text]", result)
end)

-- =============================================================================
-- FILL BEHAVIOR
-- =============================================================================

testify:that("apply fills content to width when fill is true", function()
	local rss = { test = { w = 10, fill = true, content = "-" } }
	local tss = style.new(rss)
	tss.__window.w = 80
	tss.__window.h = 24
	local result = strip_ansi(tss:apply("test", "ignored").text)

	testimony.assert_equal(10, std.utf.len(result))
	testimony.assert_equal("----------", result)
end)

testify:that("apply fills multi-char content", function()
	local rss = { test = { w = 10, fill = true, content = "ab" } }
	local tss = style.new(rss)
	tss.__window.w = 80
	tss.__window.h = 24
	local result = strip_ansi(tss:apply("test", "ignored").text)

	-- Should repeat "ab" and clip to exactly 10 chars
	testimony.assert_equal(10, std.utf.len(result))
	testimony.assert_equal("ababababab", result)
end)

-- =============================================================================
-- INDENTATION
-- =============================================================================

testify:that("apply adds text_indent indentation", function()
	local rss = { test = { text_indent = 4 } }
	local tss = style.new(rss)
	local result = strip_ansi(tss:apply("test", "text").text)

	testimony.assert_match("^    text", result)
end)

testify:that("apply combines text_indent with width and alignment", function()
	local rss = { test = { text_indent = 2, w = 10, align = "left" } }
	local tss = style.new(rss)
	tss.__window.w = 80
	tss.__window.h = 24
	local result = strip_ansi(tss:apply("test", "hi").text)

	-- text_indent adds 2 spaces to text, making it "  hi" (4 chars)
	-- Then it gets padded to width 10, so total is 10 chars
	testimony.assert_equal(10, std.utf.len(result))
	testimony.assert_match("^  hi", result)
end)

testify:that("apply ignores block_indent", function()
	local rss = { test = { block_indent = 4 } }
	local tss = style.new(rss)
	local result = strip_ansi(tss:apply("test", "text").text)

	testimony.assert_equal("text", result)
end)

testify:that("apply ignores legacy indent property", function()
	local rss = { test = { indent = 4 } }
	local tss = style.new(rss)
	local result = strip_ansi(tss:apply("test", "text").text)

	testimony.assert_equal("text", result)
end)

-- =============================================================================
-- WINDOW OVERFLOW PROTECTION (BUG FIX)
-- =============================================================================

testify:that("apply clips to available window width even when props.w is larger", function()
	local rss = { test = { w = 100 } } -- Request width larger than typical window
	local tss = style.new(rss)

	-- Manually set window size for testing (term.window_size() returns 0,0 in non-TTY)
	tss.__window.w = 80
	tss.__window.h = 24

	-- Simulate a position that leaves little room (position 75, so only 5 columns left)
	local result = strip_ansi(tss:apply("test", "short text", 75).text)

	-- Should be clipped to fit in remaining 5 columns
	testimony.assert_true(std.utf.len(result) <= 5)
end)

-- =============================================================================
-- INTEGRATION TESTS
-- =============================================================================

testify:that("apply handles complex nested styles", function()
	local rss = {
		border = {
			fg = 240,
			s = "bold",
			top = {
				before = "╭",
				content = "─",
				after = "╮",
				fill = true,
				w = 20,
			},
		},
	}
	local tss = style.new(rss)
	tss.__window.w = 80
	tss.__window.h = 24
	local result = strip_ansi(tss:apply("border.top", "ignored").text)

	-- Should be: ╭ + 20 dashes + ╮
	testimony.assert_equal(22, std.utf.len(result))
	testimony.assert_match("^╭", result)
	testimony.assert_match("╮$", result)
	-- The middle should be all dashes
	testimony.assert_equal("╭────────────────────╮", result)
end)

testify:that("apply with multiple element paths", function()
	local rss = {
		base = { fg = "blue" },
		highlight = { s = "bold" },
	}
	local tss = style.new(rss)

	-- Can pass array of element paths
	local result = tss:apply({ "base", "highlight" }, "text")

	-- Should have ANSI codes (we can't easily test exact codes, but it shouldn't be plain text)
	testimony.assert_true(result.text ~= "text")
	testimony.assert_match("text", result.text)
end)

testify:that("apply converts non-string content to string", function()
	local rss = { clip = -1 }
	local tss = style.new(rss)

	local result = strip_ansi(tss:apply("", 42).text)
	testimony.assert_equal("42", result)

	result = strip_ansi(tss:apply("", true).text)
	testimony.assert_equal("true", result)
end)

-- =============================================================================
-- TEXT SIZING PROTOCOL SUPPORT
-- =============================================================================

testify:that("apply with ts=nil produces no text sizing escape", function()
	local rss = { test = { ts = nil } }
	local tss = style.new(rss)
	local result = tss:apply("test", "hello")

	-- Should not contain OSC 66 escape sequence
	testimony.assert_false(result.text:match("\027%]66;"))
end)

testify:that("apply with ts preset string generates escape sequence", function()
	local rss = { test = { ts = "double" } }
	local tss = style.new(rss)
	local result = tss:apply("test", "hello")

	-- Should contain OSC 66 with s=2
	testimony.assert_true(result.text:match("\027%]66;"))
	testimony.assert_true(result.text:match("s=2"))
	testimony.assert_true(result.text:match("h=0"))
end)

testify:that("apply ignores ts when supports_ts is false", function()
	local rss = { test = { ts = "double" } }
	local tss = style.new(rss, { supports_ts = false })
	local result = tss:apply("test", "hello")

	testimony.assert_false(result.text:match("\027%]66;"))
	testimony.assert_equal(5, result.width)
	testimony.assert_equal(1, result.height)
end)

testify:that("apply_sized ignores ts when supports_ts is false", function()
	local rss = {
		test = { ts = "double" },
		strong = { s = "bold" },
	}
	local tss = style.new(rss, { supports_ts = false })
	local result = tss:apply_sized("test", {
		plain = "hello",
		ranges = { { start = 2, stop = 4, elements = { "strong" } } },
	})

	testimony.assert_false(result.text:match("\027%]66;"))
	testimony.assert_equal(5, result.width)
	testimony.assert_equal(1, result.height)
end)

testify:that("apply with ts table generates correct escape sequence", function()
	local rss = { test = { ts = { s = 3, v = 2 } } }
	local tss = style.new(rss)
	local result = tss:apply("test", "text")

	-- Should contain s=3 and v=2
	testimony.assert_true(result.text:match("s=3"))
	testimony.assert_true(result.text:match("v=2"))
end)

testify:that("ts with fractional scaling generates correct metadata", function()
	local rss = { test = { ts = { n = 1, d = 2, s = 2 } } }
	local tss = style.new(rss)
	local result = tss:apply("test", "text")

	-- Should contain all three parameters
	testimony.assert_true(result.text:match("s=2"))
	testimony.assert_true(result.text:match("n=1"))
	testimony.assert_true(result.text:match("d=2"))
end)

testify:that("ts with invalid fractional scaling (d <= n) ignores n and d", function()
	local rss = { test = { ts = { s = 2, n = 2, d = 2 } } }
	local tss = style.new(rss)
	local result = tss:apply("test", "text")

	-- Should contain s=2 but not n or d
	testimony.assert_true(result.text:match("s=2"))
	testimony.assert_false(result.text:match("n="))
	testimony.assert_false(result.text:match("d="))
end)

testify:that("ts preset 'superscript' resolves correctly", function()
	local rss = { test = { ts = "superscript" } }
	local tss = style.new(rss)
	local result = tss:apply("test", "2")

	-- Superscript: n=1, d=2, v=0
	testimony.assert_true(result.text:match("n=1"))
	testimony.assert_true(result.text:match("d=2"))
	testimony.assert_true(result.text:match("v=0"))
end)

testify:that("ts preset 'subscript' resolves correctly", function()
	local rss = { test = { ts = "subscript" } }
	local tss = style.new(rss)
	local result = tss:apply("test", "2")

	-- Subscript: n=1, d=2, v=1
	testimony.assert_true(result.text:match("n=1"))
	testimony.assert_true(result.text:match("d=2"))
	testimony.assert_true(result.text:match("v=1"))
end)

testify:that("ts does NOT cascade from parent to child", function()
	local rss = {
		parent = {
			ts = "double",
			child = { fg = "red" },
		},
	}
	local tss = style.new(rss)
	local result = tss:apply("parent.child", "text")

	-- Child should NOT inherit ts from parent
	testimony.assert_false(result.text:match("\027%]66;"))
end)

testify:that("child ts completely overrides parent ts", function()
	local rss = {
		parent = {
			ts = "double",
			child = { ts = "triple" },
		},
	}
	local tss = style.new(rss)
	local result = tss:apply("parent.child", "text")

	-- Should have s=3 (triple), not s=2 (double)
	testimony.assert_true(result.text:match("s=3"))
	testimony.assert_false(result.text:match("s=2"))
end)

testify:that("ts with string alignment values converts to numbers", function()
	local rss = { test = { ts = { s = 2, v = "center", h = "right" } } }
	local tss = style.new(rss)
	local result = tss:apply("test", "text")

	-- center=2, right=1
	testimony.assert_true(result.text:match("v=2"))
	testimony.assert_true(result.text:match("h=1"))
end)

testify:that("ts with invalid scale value is ignored", function()
	local rss = { test = { ts = { s = 10 } } } -- 10 is out of range (1-7)
	local tss = style.new(rss)
	local result = tss:apply("test", "text")

	-- Should not generate escape sequence
	testimony.assert_false(result.text:match("\027%]66;"))
end)

testify:that("ts with empty text does not generate escape sequence", function()
	local rss = { test = { ts = "double" } }
	local tss = style.new(rss)
	local result = tss:apply("test", "")

	-- Should not contain text sizing escape for empty content
	testimony.assert_false(result.text:match("\027%]66;"))
end)

testify:that("ts decorators (before/after) are inside escape sequence", function()
	local rss = { test = { ts = "double", before = "[", after = "]", clip = -1 } }
	local tss = style.new(rss)
	local result = tss:apply("test", "text")

	-- Decorators should be INSIDE the OSC 66 escape (both styled AND scaled)
	-- Format: ... OSC 66 ; params ; [text] ST ...
	-- Extract the text content from inside the OSC 66 sequence
	local text_content = result.text:match("\027%]66;[^;]*;([^\027]*)\027\\")

	-- The OSC 66 sequence should exist
	testimony.assert_not_nil(text_content)

	-- The text content should contain both decorators and the original text
	-- Note: with plain=true, we search for literal strings (no % escape needed)
	testimony.assert_true(text_content:find("[", 1, true) ~= nil)
	testimony.assert_true(text_content:find("]", 1, true) ~= nil)
	testimony.assert_true(text_content:find("text", 1, true) ~= nil)

	-- Verify the order: [ comes before text, ] comes after text
	local open_pos = text_content:find("[", 1, true)
	local close_pos = text_content:find("]", 1, true)
	local text_pos = text_content:find("text", 1, true)
	testimony.assert_true(open_pos < text_pos)
	testimony.assert_true(close_pos > text_pos)
end)

testify:that("ts with unknown preset string is ignored", function()
	local rss = { test = { ts = "nonexistent_preset" } }
	local tss = style.new(rss)
	local result = tss:apply("test", "text")

	-- Should not generate escape sequence
	testimony.assert_false(result.text:match("\027%]66;"))
end)

testify:that("ts width parameter generates w= in metadata", function()
	local rss = { test = { ts = { s = 2, w = 3 } } }
	local tss = style.new(rss)
	local result = tss:apply("test", "text")

	testimony.assert_true(result.text:match("w=3"))
end)

testify:that("get_property retrieves ts configuration", function()
	local rss = { test = { ts = "double" } }
	local tss = style.new(rss)

	testimony.assert_equal("double", tss:get_property("test", "ts"))
end)

testify:that("set_property can set ts configuration", function()
	local tss = style.new({})
	tss:set_property("test", "ts", { s = 2, v = 1 })

	local ts = tss:get_property("test", "ts")
	testimony.assert_equal(2, ts.s)
	testimony.assert_equal(1, ts.v)
end)

-- =============================================================================
-- APPLY RESULT TABLE (height/width properties)
-- =============================================================================

testify:that("apply returns result table with text, height, width", function()
	local rss = { test = { fg = 123 } }
	local tss = style.new(rss)
	local result = tss:apply("test", "hello")

	-- Result should be a table with required properties
	testimony.assert_true(type(result) == "table")
	testimony.assert_true(result.text ~= nil)
	testimony.assert_true(result.height ~= nil)
	testimony.assert_true(result.width ~= nil)
end)

testify:that("apply result height is 1 for non-scaled text", function()
	local rss = { test = { fg = 123 } }
	local tss = style.new(rss)
	local result = tss:apply("test", "hello")

	testimony.assert_equal(1, result.height)
end)

testify:that("apply result height equals scale factor", function()
	local rss = { test = { ts = { s = 3 } } }
	local tss = style.new(rss)
	local result = tss:apply("test", "hello")

	testimony.assert_equal(3, result.height)
end)

testify:that("apply result width reflects display width", function()
	local rss = { test = { fg = 123 } }
	local tss = style.new(rss)
	local result = tss:apply("test", "hello")

	-- "hello" is 5 characters, no scaling
	testimony.assert_equal(5, result.width)
end)

testify:that("apply result width accounts for scale factor", function()
	local rss = { test = { ts = { s = 2 } } }
	local tss = style.new(rss)
	local result = tss:apply("test", "hi")

	-- "hi" is 2 characters, scale=2, so width = 2 * 2 = 4
	testimony.assert_equal(4, result.width)
end)

testify:that("apply result width respects explicit ts.w cell width", function()
	local rss = { test = { ts = { w = 3 } } }
	local tss = style.new(rss)
	local result = tss:apply("test", "hello")

	testimony.assert_equal(3, result.width)
end)

testify:that("apply result width scales explicit ts.w when s is set", function()
	local rss = { test = { ts = { s = 2, w = 3 } } }
	local tss = style.new(rss)
	local result = tss:apply("test", "hello")

	testimony.assert_equal(6, result.width)
end)

testify:that("apply result width handles fractional ts presets with chunking", function()
	local rss = { test = { ts = "superscript" } }
	local tss = style.new(rss)
	local result = tss:apply("test", "ab")

	testimony.assert_equal(1, result.width)
end)

testify:that("apply result width includes decorators", function()
	local rss = { test = { before = "[", after = "]" } }
	local tss = style.new(rss)
	local result = tss:apply("test", "x")

	-- "[" + "x" + "]" = 3 characters
	testimony.assert_equal(3, result.width)
end)

testify:that("apply result tostring is standard table representation", function()
	local rss = { test = { fg = 123 } }
	local tss = style.new(rss)
	local result = tss:apply("test", "hello")

	-- tostring should not coerce to styled text.
	local str = tostring(result)
	testimony.assert_true(type(str) == "string")
	testimony.assert_true(str:find("^table:") ~= nil)
end)

testify:that("apply result does not support string concatenation", function()
	local rss = { test = { fg = 123 } }
	local tss = style.new(rss)
	local result = tss:apply("test", "world")

	local ok = pcall(function()
		return "hello " .. result
	end)
	testimony.assert_false(ok)
end)

testify:that("apply result text contains styled content", function()
	local rss = { test = { fg = 123 } }
	local tss = style.new(rss)
	local result = tss:apply("test", "hello")

	-- .text should contain the actual content
	testimony.assert_true(result.text:find("hello") ~= nil)
	-- And ANSI codes
	testimony.assert_true(result.text:find("\027%[") ~= nil)
end)

testify:conclude()
