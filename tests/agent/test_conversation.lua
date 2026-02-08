-- SPDX-FileCopyrightText: © 2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: OWL-1.0 or later
-- Licensed under the Open Weights License v1.0. See LICENSE for details.

local testimony = require("testimony")
local json = require("cjson.safe")
local helpers = require("tests.shell._helpers")

local testify = testimony.new("== agent.conversation ==")

local setup_conversation = function()
	local files = {}
	local state = {
		mkdirp_calls = {},
	}

	helpers.clear_modules({
		"std",
		"llm.pricing",
		"agent.conversation",
	})

	helpers.stub_module("std", {
		fs = {
			mkdirp = function(path)
				table.insert(state.mkdirp_calls, path)
				return true
			end,
			write_file = function(path, content)
				files[path] = content
				return true
			end,
			read_file = function(path)
				return files[path]
			end,
			list_files = function(path, ext)
				local out = {}
				for fpath, _ in pairs(files) do
					local prefix = path .. "/"
					if fpath:sub(1, #prefix) == prefix then
						local filename = fpath:sub(#prefix + 1)
						if filename:match("%." .. ext .. "$") then
							out[filename] = true
						end
					end
				end
				return out
			end,
		},
	})

	helpers.stub_module("llm.pricing", {
		calculate_cost = function(model, input_tokens, output_tokens, cached_tokens)
			return (input_tokens + output_tokens + cached_tokens) / 1000
		end,
	})

	local mod = helpers.load_module_from_src("agent.conversation", "src/agent/agent/conversation.lua")
	return mod, files, state
end

testify:that("conversation save/load keeps compatibility payload shape", function()
	local mod, files, state = setup_conversation()
	local conv = mod.new("sys")

	conv:add_user("hello")
	conv:add_assistant("world", { { id = "t1", name = "bash" } })
	conv:add_tool_result("t1", '{"ok":true}')
	conv:set_name("my chat!")

	local path, err = conv:save()
	testimony.assert_nil(err)
	testimony.assert_true(path:match("my_chat_%.json$") ~= nil)
	testimony.assert_equal(1, #state.mkdirp_calls)

	local payload = json.decode(files[path])
	testimony.assert_equal("my chat!", payload.name)
	testimony.assert_equal("sys", payload.system_prompt)
	testimony.assert_equal(3, #payload.messages)
	testimony.assert_true(type(payload.metadata) == "table")

	local loaded = mod.new(nil)
	local ok, load_err = loaded:load("my chat!")
	testimony.assert_true(ok)
	testimony.assert_nil(load_err)
	testimony.assert_equal("my chat!", loaded:get_name())
	testimony.assert_equal(3, loaded:count())
	testimony.assert_equal("sys", loaded:get_system_prompt())
end)

testify:that("conversation clear resets usage while preserving system prompt", function()
	local mod = setup_conversation()
	local conv = mod.new("system-a")

	conv:add_user("u")
	conv:add_usage("m", 10, 5, 1)
	testimony.assert_equal(15, conv:tokens())
	testimony.assert_true(conv:get_total_cost() > 0)

	conv:clear()
	testimony.assert_equal(0, conv:count())
	testimony.assert_equal(0, conv:tokens())
	testimony.assert_equal("system-a", conv:get_system_prompt())

	local cost = conv:get_cost()
	testimony.assert_equal(0, cost.request_count)
	testimony.assert_equal(0, cost.total_cost)
end)

testify:that("conversation list sorting and legacy load fallback work", function()
	local mod, files = setup_conversation()
	local home = os.getenv("HOME") or "/tmp"
	local save_dir = home .. "/.local/share/lilush/agent/conversations"

	files[save_dir .. "/newer.json"] = json.encode({
		name = "newer",
		messages = { { role = "user", content = "x" } },
		metadata = { updated_at = 20, created_at = 10 },
	})
	files[save_dir .. "/older.json"] = json.encode({
		name = "older",
		messages = {},
		metadata = { updated_at = 5, created_at = 1 },
	})
	files[save_dir .. "/legacy.json"] = json.encode({
		system_prompt = "legacy-sys",
		messages = { { role = "user", content = "legacy" } },
	})

	local listed = mod.list()
	testimony.assert_equal("newer", listed[1].name)
	testimony.assert_equal("older", listed[2].name)

	local conv = mod.new(nil)
	local ok = conv:load("legacy")
	testimony.assert_true(ok)
	testimony.assert_equal("legacy", conv:get_name())
	testimony.assert_equal("legacy-sys", conv:get_system_prompt())
	testimony.assert_equal(1, conv:count())

	local old_remove = os.remove
	local removed = nil
	os.remove = function(path)
		removed = path
		return true
	end
	local del_ok = mod.delete("legacy")
	os.remove = old_remove

	testimony.assert_true(del_ok)
	testimony.assert_true(removed:match("legacy%.json$") ~= nil)
end)

testify:conclude()
