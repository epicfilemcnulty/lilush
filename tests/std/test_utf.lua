-- SPDX-FileCopyrightText: © 2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: OWL-1.0 or later
-- Licensed under the Open Weights License v1.0. See LICENSE for details.

local testimony = require("testimony")
local std = require("std")

local testify = testimony.new("== std.utf functions ==")

testify:that("utf.len counts UTF-8 characters correctly", function()
	local ascii = "hello"
	testimony.assert_equal(5, std.utf.len(ascii))

	local unicode = "hello世界"
	testimony.assert_equal(7, std.utf.len(unicode))

	local emoji = "👋🌍"
	testimony.assert_equal(2, std.utf.len(emoji))
end)

testify:that("utf.len ignores CSI sequences and returns one value", function()
	local with_csi = "\27[31mhe\27[2Allo\27[0m"
	local len, extra = std.utf.len(with_csi)
	testimony.assert_equal(5, len)
	testimony.assert_nil(extra)
end)

testify:that("utf.len ignores OSC 66 wrappers but counts payload text", function()
	local with_osc66 = "x\27]66;s=2;yz\27\\w"
	testimony.assert_equal(4, std.utf.len(with_osc66))
end)

testify:that("utf.len ignores non-printing OSC payloads", function()
	local with_title = "\27]0;window title\7abc"
	testimony.assert_equal(3, std.utf.len(with_title))
end)

testify:that("utf.len treats control bytes as non-printing", function()
	local with_controls = "ab\bcd\t\n\r"
	testimony.assert_equal(4, std.utf.len(with_controls))
end)

testify:that("utf.sub extracts printable substrings from styled input", function()
	local str = "\27[31mhe\27[0m\bllo\27]66;s=2;!\27\\"
	testimony.assert_equal("ello", std.utf.sub(str, 2, 5))
	testimony.assert_equal("o!", std.utf.sub(str, -2, -1))
end)

testify:that("utf.sub never returns escape sequence fragments", function()
	local str = "\27[31mhello\27[0m\27]66;s=2;!\27\\"
	local sub = std.utf.sub(str, 1, 6)
	testimony.assert_equal("hello!", sub)
	testimony.assert_false(sub:find("\27", 1, true) ~= nil)
end)

testify:that("utf.sub handles negative indices", function()
	local str = "hello"
	testimony.assert_equal("lo", std.utf.sub(str, -2, -1))
	testimony.assert_equal("ello", std.utf.sub(str, -4))
end)

testify:that("utf.valid validates UTF-8 strings", function()
	testimony.assert_true(std.utf.valid("hello world"))
	testimony.assert_true(std.utf.valid("hello世界"))
	testimony.assert_true(std.utf.valid("emoji👋"))

	-- Invalid UTF-8 sequence
	local invalid = string.char(0xFF, 0xFE)
	testimony.assert_false(std.utf.valid(invalid))
end)

testify:that("utf.valid_seq handles F4 and F0 boundaries correctly", function()
	-- U+10FFFF (maximum valid scalar value)
	local max_valid = string.char(0xF4, 0x8F, 0xBF, 0xBF)
	testimony.assert_true(std.utf.valid_seq(max_valid))

	-- > U+10FFFF is invalid
	local above_max = string.char(0xF4, 0x90, 0x80, 0x80)
	testimony.assert_false(std.utf.valid_seq(above_max))

	-- < U+10000 for F0 prefix is invalid (overlong)
	local below_min_f0 = string.char(0xF0, 0x8F, 0xBF, 0xBF)
	testimony.assert_false(std.utf.valid_seq(below_min_f0))
end)

testify:that("utf.display_len matches printable semantics for escapes and controls", function()
	local input = "\27[31m界\27[0m\27]66;s=2;A\27\\\bZ"
	testimony.assert_equal(3, std.utf.len(input))
	testimony.assert_equal(4, std.utf.display_len(input))
end)

testify:that("utf.display_len ignores non-printing OSC sequences", function()
	local input = "\27]0;window title\7ab"
	testimony.assert_equal(2, std.utf.display_len(input))
end)

testify:that("utf.cell_len matches printable width for plain text", function()
	local input = "hello世界"
	testimony.assert_equal(std.utf.display_len(input), std.utf.cell_len(input))
end)

testify:that("utf.cell_len applies OSC 66 scale width", function()
	local input = "x\27]66;s=2;ab\27\\z"
	testimony.assert_equal(6, std.utf.cell_len(input))
end)

testify:that("utf.cell_len applies OSC 66 explicit width", function()
	local input = "x\27]66;w=3;abcdef\27\\z"
	testimony.assert_equal(5, std.utf.cell_len(input))
end)

testify:that("utf.cell_len handles ANSI mixed with OSC 66", function()
	local input = "\27[31mA\27[0m\27]66;s=2;B\27\\C"
	testimony.assert_equal(4, std.utf.cell_len(input))
end)

testify:that("utf.cell_len applies scale to explicit OSC 66 width", function()
	local input = "x\27]66;s=2:w=3;abcdef\27\\z"
	testimony.assert_equal(8, std.utf.cell_len(input))
end)

testify:that("utf.cell_len can use width-only ts mode", function()
	local old_mode = std.utf.get_ts_width_mode()
	std.utf.set_ts_width_mode("w_only")
	local input = "x\27]66;s=2:w=3;abcdef\27\\z"
	testimony.assert_equal(5, std.utf.cell_len(input))
	std.utf.set_ts_width_mode(old_mode)
end)

testify:that("utf.cell_len uses conservative width for fractional s+n/d+w", function()
	local input = "x\27]66;s=2:n=6:d=9:w=2;abc\27\\z"
	testimony.assert_equal(8, std.utf.cell_len(input))
end)

testify:that("utf.cell_height is 1 for plain text", function()
	local input = "hello世界"
	testimony.assert_equal(1, std.utf.cell_height(input))
end)

testify:that("utf.cell_height applies OSC 66 scale height", function()
	local input = "x\27]66;s=3;ab\27\\z"
	testimony.assert_equal(3, std.utf.cell_height(input))
end)

testify:that("utf.cell_height ignores OSC 66 explicit width for height", function()
	local input = "x\27]66;w=3;abcdef\27\\z"
	testimony.assert_equal(1, std.utf.cell_height(input))
end)

testify:that("utf.cell_height handles ANSI mixed with OSC 66", function()
	local input = "\27[31mA\27[0m\27]66;s=2;B\27\\C"
	testimony.assert_equal(2, std.utf.cell_height(input))
end)

testify:that("utf.char creates UTF-8 from codepoints", function()
	-- Basic ASCII
	testimony.assert_equal("A", std.utf.char(0x41))

	-- Multi-byte character
	testimony.assert_equal("世", std.utf.char(0x4E16))
end)

testify:that("utf.char returns nil for out of range codepoints", function()
	local result, err = std.utf.char(-1)
	testimony.assert_nil(result)
	testimony.assert_match("out of range", err)

	local result2, err2 = std.utf.char(0x110000)
	testimony.assert_nil(result2)
	testimony.assert_match("out of range", err2)
end)

testify:that("utf.find_all_spaces finds space positions", function()
	local spaces = std.utf.find_all_spaces("hello world test")
	testimony.assert_equal(2, #spaces)
	testimony.assert_equal(6, spaces[1])
	testimony.assert_equal(12, spaces[2])
end)

testify:that("utf.valid_b1 checks valid UTF-8 start bytes", function()
	-- Valid multi-byte start
	testimony.assert_true(std.utf.valid_b1(string.char(0xC2)))
	testimony.assert_true(std.utf.valid_b1(string.char(0xF4)))

	-- Invalid
	testimony.assert_false(std.utf.valid_b1(string.char(0x80)))
	testimony.assert_false(std.utf.valid_b1(nil))
end)

testify:that("utf.byte_count returns correct byte count", function()
	-- 2-byte sequence (0xC0-0xDF)
	testimony.assert_equal(1, std.utf.byte_count(string.char(0xC2)))

	-- 3-byte sequence (0xE0-0xEF)
	testimony.assert_equal(2, std.utf.byte_count(string.char(0xE0)))

	-- 4-byte sequence (0xF0-0xF4)
	testimony.assert_equal(3, std.utf.byte_count(string.char(0xF0)))
end)

testify:conclude()
