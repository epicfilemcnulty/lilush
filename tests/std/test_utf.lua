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

testify:that("utf.len ignores ANSI escape sequences", function()
	local with_ansi = "\27[31mhello\27[0m"
	local len, esc_count = std.utf.len(with_ansi)
	testimony.assert_equal(5, len)
	testimony.assert_equal(2, esc_count)
end)

testify:that("utf.sub extracts UTF-8 substrings", function()
	local str = "hello世界"
	testimony.assert_equal("hello", std.utf.sub(str, 1, 5))
	testimony.assert_equal("世界", std.utf.sub(str, 6, 7))
	testimony.assert_equal("llo世", std.utf.sub(str, 3, 6))
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
