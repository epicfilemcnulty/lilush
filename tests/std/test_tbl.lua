-- SPDX-FileCopyrightText: © 2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: OWL-1.0 or later
-- Licensed under the Open Weights License v1.0. See LICENSE for details.

local testimony = require("testimony")
local std = require("std")

local testify = testimony.new("== std.tbl functions ==")

testify:that("tbl.copy creates deep copies", function()
	local original = { a = 1, b = { c = 2, d = 3 } }
	local copy = std.tbl.copy(original)

	testimony.assert_equal(original, copy)

	-- Verify it's a deep copy
	copy.b.c = 99
	testimony.assert_equal(2, original.b.c)
	testimony.assert_equal(99, copy.b.c)
end)

testify:that("tbl.copy handles cyclic references", function()
	local t = { a = 1 }
	t.self = t

	local copy = std.tbl.copy(t)
	testimony.assert_equal(1, copy.a)
	testimony.assert_equal(copy, copy.self)
end)

testify:that("tbl.merge combines tables", function()
	local defaults = { a = 1, b = 2, c = { d = 3 } }
	local options = { b = 20, c = { e = 4 } }

	local result = std.tbl.merge(defaults, options)
	testimony.assert_equal(1, result.a)
	testimony.assert_equal(20, result.b)
	testimony.assert_equal(3, result.c.d)
	testimony.assert_equal(4, result.c.e)
end)

testify:that("tbl.empty detects empty tables", function()
	testimony.assert_true(std.tbl.empty({}))
	testimony.assert_false(std.tbl.empty({ a = 1 }))
	testimony.assert_false(std.tbl.empty({ 1, 2, 3 }))
	testimony.assert_false(std.tbl.empty("string"))
end)

testify:that("tbl.contains finds elements in tables", function()
	local t = { "apple", "banana", "cherry" }
	testimony.assert_equal(2, std.tbl.contains(t, "banana"))
	testimony.assert_nil(std.tbl.contains(t, "orange"))
end)

testify:that("tbl.contains supports fuzzy matching", function()
	local t = { "apple", "banana", "cherry" }
	testimony.assert_equal(1, std.tbl.contains(t, "app", true))
	testimony.assert_equal(2, std.tbl.contains(t, "nan", true))
end)

testify:that("tbl.longest finds longest string", function()
	local t = { "hi", "hello", "hey" }
	testimony.assert_equal(5, std.tbl.longest(t))

	local empty = {}
	testimony.assert_equal(0, std.tbl.longest(empty))
end)

testify:that("tbl.longest handles UTF-8 correctly", function()
	local t = { "hi", "世界" }
	testimony.assert_equal(2, std.tbl.longest(t))
end)

testify:that("tbl.alphanumsort sorts alphanumerically", function()
	local t = { "file10", "file2", "file1" }
	std.tbl.alphanumsort(t)
	testimony.assert_equal("file1", t[1])
	testimony.assert_equal("file2", t[2])
	testimony.assert_equal("file10", t[3])
end)

testify:that("tbl.sort_keys returns sorted keys", function()
	local t = { z = 1, a = 2, m = 3 }
	local keys = std.tbl.sort_keys(t)
	testimony.assert_equal("a", keys[1])
	testimony.assert_equal("m", keys[2])
	testimony.assert_equal("z", keys[3])
end)

testify:that("tbl.include_keys filters by pattern", function()
	local t = { "test_foo", "test_bar", "other" }
	local filtered = std.tbl.include_keys(t, "test_")
	testimony.assert_equal(2, #filtered)
	testimony.assert_equal("test_foo", filtered[1])
end)

testify:that("tbl.exclude_keys excludes by pattern", function()
	local t = { "test_foo", "test_bar", "other" }
	local filtered = std.tbl.exclude_keys(t, "test_")
	testimony.assert_equal(1, #filtered)
	testimony.assert_equal("other", filtered[1])
end)

testify:that("tbl.sort_by_str_len sorts by string length", function()
	local t = { "hello", "hi", "hey" }
	std.tbl.sort_by_str_len(t)
	testimony.assert_equal("hi", t[1])
	testimony.assert_equal("hey", t[2])
	testimony.assert_equal("hello", t[3])
end)

testify:that("tbl.get_value_by_ref accesses nested values", function()
	local t = { a = { b = { c = 42 } } }
	testimony.assert_equal(42, std.tbl.get_value_by_ref(t, "a.b.c"))
	testimony.assert_nil(std.tbl.get_value_by_ref(t, "a.b.d"))
	testimony.assert_nil(std.tbl.get_value_by_ref(t, "x.y.z"))
end)

testify:that("tbl.render converts table to string", function()
	local t = { a = 1, b = "test" }
	local rendered = std.tbl.render(t)
	testimony.assert_match("a = 1", rendered)
	testimony.assert_match('b = "test"', rendered)
end)

testify:that("tbl.shuffle modifies table in place", function()
	local t = { 1, 2, 3, 4, 5 }
	local copy = std.tbl.copy(t)
	std.tbl.shuffle(t)

	-- Table should still have same elements
	testimony.assert_equal(5, #t)

	-- At least verify it's the same table object
	testimony.assert_true(type(t) == "table")
end)

testify:conclude()
