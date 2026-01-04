-- SPDX-FileCopyrightText: © 2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: GPL-3.0-or-later
local testimony = require("testimony")
local std = require("std")

local testify = testimony.new("== std.txt functions ==")

testify:that("txt.lines splits text by newlines", function()
	local input = "line1\nline2\nline3"
	local result = std.txt.lines(input)
	testimony.assert_equal(3, #result)
	testimony.assert_equal("line1", result[1])
	testimony.assert_equal("line2", result[2])
	testimony.assert_equal("line3", result[3])
end)

testify:that("txt.lines handles CRLF line endings", function()
	local input = "line1\r\nline2\r\nline3"
	local result = std.txt.lines(input)
	testimony.assert_equal(3, #result)
	testimony.assert_equal("line1", result[1])
end)

testify:that("txt.lines handles single line", function()
	local result = std.txt.lines("single line")
	testimony.assert_equal(1, #result)
	testimony.assert_equal("single line", result[1])
end)

testify:that("txt.lines handles trailing content", function()
	local input = "line1\nline2\ntrailing"
	local result = std.txt.lines(input)
	testimony.assert_equal(3, #result)
	testimony.assert_equal("trailing", result[3])
end)

testify:that("txt.align aligns text left", function()
	local result = std.txt.align("hi", 5, "left")
	testimony.assert_equal("hi   ", result)
end)

testify:that("txt.align aligns text right", function()
	local result = std.txt.align("hi", 5, "right")
	testimony.assert_equal("   hi", result)
end)

testify:that("txt.align aligns text center", function()
	local result = std.txt.align("hi", 6, "center")
	testimony.assert_equal("  hi  ", result)
end)

testify:that("txt.limit truncates long strings", function()
	local result = std.txt.limit("hello world", 8)
	testimony.assert_equal("hello w…", result)
	local len = std.utf.display_len(result)
	testimony.assert_equal(len, 8)
	result = std.txt.limit("hello world", 8, 2)
	testimony.assert_equal("h… world", result)
	len = std.utf.display_len(result)
	testimony.assert_equal(len, 8)
end)

testify:that("txt.limit keeps short strings unchanged", function()
	local result = std.txt.limit("hello", 10)
	testimony.assert_equal("hello", result)
end)

testify:that("txt.limit respects display width for wide glyphs", function()
	local input = "ab界cd"
	local result = std.txt.limit(input, 4)
	testimony.assert_equal("ab…", result)
	testimony.assert_equal(3, std.utf.display_len(result))
	result = std.txt.limit(input, 5, 2)
	testimony.assert_equal("a…cd", result)
	testimony.assert_equal(4, std.utf.display_len(result))
end)

testify:that("txt.indent adds indentation", function()
	local result = std.txt.indent("line1\nline2", 2)
	-- indent_lines adds ANSI reset code before spaces
	testimony.assert_match("  line1", result)
	testimony.assert_match("  line2", result)
end)

testify:that("txt.indent_lines returns table of indented lines", function()
	local result = std.txt.indent_lines({ "line1", "line2" }, 2)
	testimony.assert_equal(2, #result)
	-- indent_lines adds ANSI reset code at the beginning of each line, so check without anchoring
	testimony.assert_match("  line1", result[1])
	testimony.assert_match("  line2", result[2])
end)

testify:that("txt.indent_all_lines_but_first skips first line", function()
	local result = std.txt.indent_all_lines_but_first({ "first", "second" }, 2)
	testimony.assert_equal("first", result[1])
	-- Second line should be indented (with ANSI codes)
	testimony.assert_match("  second", result[2])
end)

testify:that("txt.template substitutes environment variables", function()
	-- This test uses environment variables, may vary
	std.ps.setenv("SUBS_VAR", "replaced")
	local tmpl = "it got ${SUBS_VAR}"
	local result = std.txt.template(tmpl)
	std.ps.unsetenv("SUBS_VAR")
	testimony.assert_equal(result, "it got replaced")
end)

testify:that("txt.template substitutes from table", function()
	local tmpl = "Hello ${name}!"
	local result = std.txt.template(tmpl, { name = "World" })
	testimony.assert_equal("Hello World!", result)
end)

testify:that("txt.find_all_positions finds pattern positions", function()
	local input = "foo bar foo baz"
	local positions = std.txt.find_all_positions(input, "foo")
	testimony.assert_equal(2, #positions)
	testimony.assert_equal(1, positions[1][1])
	testimony.assert_equal(9, positions[2][1])
end)

testify:that("txt.find_all_positions returns nil for nil input", function()
	testimony.assert_nil(std.txt.find_all_positions(nil, "pattern"))
	testimony.assert_nil(std.txt.find_all_positions("input", nil))
end)

testify:that("txt.split_by splits and marks regions", function()
	local input = "hello WORLD hello"
	local result = std.txt.split_by(input, "WORLD")
	testimony.assert_true(#result >= 2)

	-- Check that we have both regular and captured parts
	local has_reg = false
	local has_cap = false
	for _, v in ipairs(result) do
		if v.t == "reg" then
			has_reg = true
		end
		if v.t == "cap" then
			has_cap = true
		end
	end
	testimony.assert_true(has_reg)
	testimony.assert_true(has_cap)
end)

testify:that("txt.split_by handles no match", function()
	local input = "hello world"
	local result = std.txt.split_by(input, "NOTFOUND")
	testimony.assert_equal(1, #result)
	testimony.assert_equal("reg", result[1].t)
	testimony.assert_equal(input, result[1].c)
end)

testify:that("txt.lines_of wraps long lines", function()
	local input = "This is a very long line that should be wrapped at some point"
	local result = std.txt.lines_of(input, 20)
	testimony.assert_true(#result > 1)
end)

testify:that("txt.lines_of respects existing newlines", function()
	local input = "line1\nline2"
	local result = std.txt.lines_of(input, 80)
	testimony.assert_equal(2, #result)
end)

testify:that("txt.lines_of force split works", function()
	local input = "verylongwordwithoutspaces"
	local result = std.txt.lines_of(input, 10, true)
	testimony.assert_true(#result > 1)
end)

testify:conclude()
