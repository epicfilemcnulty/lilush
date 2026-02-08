-- SPDX-FileCopyrightText: © 2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: OWL-1.0 or later
-- Licensed under the Open Weights License v1.0. See LICENSE for details.

local testimony = require("testimony")
local helpers = require("tests.shell._helpers")

local testify = testimony.new("== shell.mode.lua repl ==")

local make_std_stub = function()
	return {
		tbl = {
			merge = function(dst, src)
				dst = dst or {}
				for k, v in pairs(src or {}) do
					dst[k] = v
				end
				return dst
			end,
			sort_keys = function(tbl)
				local keys = {}
				for k, _ in pairs(tbl or {}) do
					table.insert(keys, k)
				end
				table.sort(keys)
				return keys
			end,
		},
		escape_magic_chars = function(text)
			return tostring(text or ""):gsub("([^%w])", "%%%1")
		end,
	}
end

local setup_mode = function()
	local output = { text = "" }
	local completion_updates = {}

	helpers.clear_modules({
		"std",
		"term",
		"term.tss",
		"shell.theme",
		"shell.mode.lua",
	})
	helpers.stub_module("std", make_std_stub())
	helpers.stub_module("shell.theme", {})
	helpers.stub_module("term.tss", {
		new = function()
			return {
				apply = function(self, key, value)
					if value ~= nil then
						return { text = tostring(value) }
					end
					return { text = "--------------------------------" }
				end,
			}
		end,
	})
	helpers.stub_module("term", {
		write = function(text)
			output.text = output.text .. tostring(text)
		end,
	})

	local mode_mod = helpers.load_module_from_src("shell.mode.lua", "src/shell/shell/mode/lua.lua")
	local input = {
		content = "",
		get_content = function(self)
			return self.content
		end,
		completion_update_source = function(self, source_name, env)
			table.insert(completion_updates, { source = source_name, env = env })
		end,
	}

	local mode = mode_mod.new(input)
	return mode, input, output, completion_updates
end

testify:that("keeps global state between commands and auto-echoes expressions", function()
	local mode, input, output, completion_updates = setup_mode()

	input.content = "x = 41"
	local status = mode:run()
	testimony.assert_equal(0, status)

	input.content = "x + 1"
	status = mode:run()
	testimony.assert_equal(0, status)
	testimony.assert_match("42", output.text)

	testimony.assert_true(#completion_updates >= 2)
	testimony.assert_equal("lua_symbols", completion_updates[1].source)
end)

testify:that("returns continuation payload for incomplete chunks", function()
	local mode, input = setup_mode()

	input.content = "for i = 1, 2 do"
	local status, err, next_input, skip_history = mode:run()

	testimony.assert_equal(0, status)
	testimony.assert_nil(err)
	testimony.assert_equal("for i = 1, 2 do\n\n", next_input)
	testimony.assert_true(skip_history)
end)

testify:that("supports :reset and clears repl state", function()
	local mode, input = setup_mode()

	input.content = "x = 10"
	local status = mode:run()
	testimony.assert_equal(0, status)

	input.content = ":reset"
	status = mode:run()
	testimony.assert_equal(0, status)

	input.content = "x + 1"
	status = mode:run()
	testimony.assert_equal(255, status)
end)

testify:that("supports :type and :modules meta commands", function()
	local mode, input, output = setup_mode()

	input.content = ":type 1 + 2"
	local status = mode:run()
	testimony.assert_equal(0, status)
	testimony.assert_match("number", output.text)

	input.content = ":modules"
	status = mode:run()
	testimony.assert_equal(0, status)
	testimony.assert_match("std", output.text)
end)

testify:conclude()
