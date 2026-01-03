-- SPDX-FileCopyrightText: © 2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: GPL-3.0-or-later
local testimony = require("testimony")
local std = require("std")

local testify = testimony.new("== std.fs functions ==")

testify:that("write_file and read_file are functional", function()
	local content = "test content\n"
	local fname = "/tmp/" .. std.nanoid()
	local ok = std.fs.write_file(fname, content)
	testimony.assert_true(ok)

	local read = std.fs.read_file(fname)
	testimony.assert_equal(content, read)

	std.fs.remove(fname)
end)

testify:that("read_file returns nil for non-existent file", function()
	local fname = "/tmp/" .. std.nanoid()
	local content = std.fs.read_file(fname)
	testimony.assert_nil(content)
end)

testify:that("mkdir and dir_exists are functional", function()
	local fname = "/tmp/" .. std.nanoid()
	local ok = std.fs.mkdir(fname)
	testimony.assert_true(ok)
	testimony.assert_true(std.fs.dir_exists(fname))
	std.fs.remove(fname)
end)

testify:conclude()
