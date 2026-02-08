-- SPDX-FileCopyrightText: © 2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: OWL-1.0 or later
-- Licensed under the Open Weights License v1.0. See LICENSE for details.

local testimony = require("testimony")
local std = require("std")
local term = require("term")

local testify = testimony.new("== term.text_size fractional scaling ==")

local function count_escape_sequences(str)
	local count = 0
	for _ in str:gmatch("\027%]66;") do
		count = count + 1
	end
	return count
end

testify:that("fractional scaling chunks text correctly (4 chars)", function()
	-- Test with n=1, d=2, w=1 (half-size, 2 display columns per cell)
	local opts = { n = 1, d = 2, w = 1 }
	-- 4 ASCII chars (each width 1) -> 2 chunks of 2 chars each
	local result = term.text_size("abcd", opts)
	testimony.assert_equal(2, count_escape_sequences(result))
end)

testify:that("fractional scaling chunks text correctly (5 chars)", function()
	local opts = { n = 1, d = 2, w = 1 }
	-- 5 ASCII chars -> 3 chunks: "ab", "cd", "e"
	local result = term.text_size("abcde", opts)
	testimony.assert_equal(3, count_escape_sequences(result))
end)

testify:that("fractional scaling handles 2-char input", function()
	local opts = { n = 1, d = 2, w = 1 }
	-- 2 ASCII chars -> 1 chunk
	local result = term.text_size("ab", opts)
	testimony.assert_equal(1, count_escape_sequences(result))
end)

testify:that("fractional scaling handles 1-char input", function()
	local opts = { n = 1, d = 2, w = 1 }
	-- 1 ASCII char -> 1 chunk
	local result = term.text_size("a", opts)
	testimony.assert_equal(1, count_escape_sequences(result))
end)

testify:that("fractional scaling chunks longer text correctly", function()
	local opts = { n = 1, d = 2, w = 1 }
	-- 11 chars "hello world" -> 6 chunks: "he", "ll", "o ", "wo", "rl", "d"
	local result = term.text_size("hello world", opts)
	testimony.assert_equal(6, count_escape_sequences(result))
end)

testify:that("non-fractional scaling does not chunk", function()
	-- Scale only (no fractional) should produce single sequence
	local opts = { s = 2 }
	local result = term.text_size("hello world", opts)
	testimony.assert_equal(1, count_escape_sequences(result))
end)

testify:that("scale+w without fractional does not chunk", function()
	-- Even with w specified, no fractional = no chunking
	local opts = { s = 2, w = 1 }
	local result = term.text_size("hello world", opts)
	testimony.assert_equal(1, count_escape_sequences(result))
end)

testify:that("empty string returns empty", function()
	local opts = { n = 1, d = 2, w = 1 }
	local result = term.text_size("", opts)
	testimony.assert_equal("", result)
end)

testify:that("nil text returns empty", function()
	local opts = { n = 1, d = 2, w = 1 }
	local result = term.text_size(nil, opts)
	testimony.assert_equal("", result)
end)

testify:that("nil opts returns text unchanged", function()
	local result = term.text_size("hello", nil)
	testimony.assert_equal("hello", result)
end)

testify:that("ts_presets superscript has w=1", function()
	testimony.assert_equal(1, term.TS_PRESETS.superscript.w)
end)

testify:that("ts_presets subscript has w=1", function()
	testimony.assert_equal(1, term.TS_PRESETS.subscript.w)
end)

testify:that("ts_presets half has w=1", function()
	testimony.assert_equal(1, term.TS_PRESETS.half.w)
end)

testify:that("ts_presets compact has w=1", function()
	testimony.assert_equal(1, term.TS_PRESETS.compact.w)
end)

testify:that("ts_presets double does not have w", function()
	testimony.assert_nil(term.TS_PRESETS.double.w)
end)

testify:that("ts_presets triple does not have w", function()
	testimony.assert_nil(term.TS_PRESETS.triple.w)
end)

testify:that("ts_presets quadruple does not have w", function()
	testimony.assert_nil(term.TS_PRESETS.quadruple.w)
end)

testify:that("wide characters are handled correctly (single emoji)", function()
	-- Wide characters (display width 2) should be handled correctly
	local opts = { n = 1, d = 2, w = 1 }
	-- A single emoji (width 2) should be its own chunk
	local result = term.text_size("🐈", opts)
	testimony.assert_equal(1, count_escape_sequences(result))
end)

testify:that("wide characters are handled correctly (two emojis)", function()
	local opts = { n = 1, d = 2, w = 1 }
	-- Two emojis (each width 2) -> 2 chunks
	local result = term.text_size("🐈🐕", opts)
	testimony.assert_equal(2, count_escape_sequences(result))
end)

testify:that("mixed ASCII and wide characters are chunked correctly", function()
	local opts = { n = 1, d = 2, w = 1 }
	-- Mixed: "a🐈" -> "a" can't fit with emoji (1+2=3 > 2), so "a" first, then "🐈"
	local result = term.text_size("a🐈", opts)
	testimony.assert_equal(2, count_escape_sequences(result))
end)

testify:that("escape sequence format is correct", function()
	local opts = { n = 1, d = 2, w = 1, v = 0 }
	local result = term.text_size("ab", opts)

	-- Should contain the OSC 66 escape code with correct parameters
	testimony.assert_match("\027%]66;", result)
	testimony.assert_match("n=1", result)
	testimony.assert_match("d=2", result)
	testimony.assert_match("w=1", result)
	testimony.assert_match("v=0", result)
end)

testify:conclude()
