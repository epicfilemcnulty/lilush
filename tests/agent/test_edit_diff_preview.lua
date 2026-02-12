-- SPDX-FileCopyrightText: © 2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: OWL-1.0 or later
-- Licensed under the Open Weights License v1.0. See LICENSE for details.

local testimony = require("testimony")
local std = require("std")
local preview_mod = require("agent.edit_diff_preview")

local testify = testimony.new("== agent.edit_diff_preview ==")

local function make_temp_file(content)
	local path = string.format("/tmp/agent_edit_preview_%d_%d.tmp", os.time(), math.random(100000, 999999))
	testimony.assert_true(std.fs.write_file(path, content))
	return path
end

testify:that("build creates unified preview with file line metadata", function()
	local file = make_temp_file("prefix\nold line\nsuffix\n")
	local preview, err = preview_mod.build({
		filepath = file,
		old_text = "old line",
		new_text = "new line",
	})
	testimony.assert_nil(err)
	testimony.assert_true(type(preview) == "table")
	testimony.assert_false(preview.truncated)
	testimony.assert_equal(2, preview.start_line)
	testimony.assert_equal("@@ -2,1 +2,1 @@", preview.inline_lines[1])
	testimony.assert_equal("-old line", preview.inline_lines[2])
	testimony.assert_equal("+new line", preview.inline_lines[3])
	testimony.assert_true(std.fs.remove(file))
end)

testify:that("build truncates by changed line count", function()
	local old_lines = {}
	local new_lines = {}
	for i = 1, 35 do
		old_lines[#old_lines + 1] = "old_" .. tostring(i)
		new_lines[#new_lines + 1] = "new_" .. tostring(i)
	end

	local preview, err = preview_mod.build({
		filepath = "/tmp/does_not_matter",
		old_text = table.concat(old_lines, "\n"),
		new_text = table.concat(new_lines, "\n"),
	})
	testimony.assert_nil(err)
	testimony.assert_true(preview.truncated)
	testimony.assert_equal("line_limit", preview.truncated_reason)
	testimony.assert_equal(0, #preview.inline_lines)
	testimony.assert_true(#preview.full_lines > 0)
end)

testify:that("build truncates by byte size when changed lines are under limit", function()
	local old_text = string.rep("x", 2500)
	local new_text = string.rep("y", 2500)
	local preview, err = preview_mod.build({
		old_text = old_text,
		new_text = new_text,
	})
	testimony.assert_nil(err)
	testimony.assert_true(preview.truncated)
	testimony.assert_equal("byte_limit", preview.truncated_reason)
	testimony.assert_equal(2, preview.stats.changed_lines)
	testimony.assert_true(preview.stats.full_bytes > 4096)
end)

testify:that("build falls back to unknown start line when file cannot be read", function()
	local preview, err = preview_mod.build({
		filepath = "/tmp/this_file_does_not_exist_999999",
		old_text = "alpha",
		new_text = "beta",
	})
	testimony.assert_nil(err)
	testimony.assert_nil(preview.start_line)
	testimony.assert_equal("@@ -?,1 +?,1 @@", preview.full_lines[1])
end)

testify:conclude()
