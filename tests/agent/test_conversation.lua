-- SPDX-FileCopyrightText: © 2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: OWL-1.0 or later
-- Licensed under the Open Weights License v1.0. See LICENSE for details.

local testimony = require("testimony")
local std = require("std")
local json = require("cjson.safe")
local conversation_mod = require("agent.conversation")

local testify = testimony.new("== agent.conversation save/load ==")

local function with_temp_home(fn)
	local previous_home = os.getenv("HOME")
	local temp_home = "/tmp/agent_conversation_test_" .. std.nanoid()

	testimony.assert_true(std.fs.mkdir(temp_home, nil, true))
	testimony.assert_true(std.ps.setenv("HOME", temp_home))

	local ok, err = pcall(fn, temp_home)

	if previous_home and previous_home ~= "" then
		std.ps.setenv("HOME", previous_home)
	else
		std.ps.unsetenv("HOME")
	end
	std.fs.remove(temp_home, true)

	if not ok then
		error(err)
	end
end

testify:that("save accepts spaced names and can reuse previous name", function()
	with_temp_home(function()
		local conv = conversation_mod.new("system prompt")
		conv:add_user("hello")

		local path, err = conv:save("alpha beta")
		testimony.assert_nil(err)
		testimony.assert_not_nil(path)
		testimony.assert_match("alpha_beta%.json$", path)

		local saved_raw = std.fs.read_file(path)
		testimony.assert_not_nil(saved_raw)
		local saved = json.decode(saved_raw)
		testimony.assert_not_nil(saved)
		testimony.assert_equal("alpha beta", saved.name)
		testimony.assert_equal("alpha beta", saved.metadata.name)
		testimony.assert_nil(saved.cost)

		conv:add_assistant("world")
		local path2, err2 = conv:save()
		testimony.assert_nil(err2)
		testimony.assert_equal(path, path2)
		testimony.assert_equal("alpha beta", conv:get_name())
	end)
end)

testify:that("save rejects whitespace-only names", function()
	with_temp_home(function()
		local conv = conversation_mod.new("system")
		local path, err = conv:save("   ")
		testimony.assert_nil(path)
		testimony.assert_match("conversation name required", err)
	end)
end)

testify:that("load restores metadata/messages and does not restore cost", function()
	with_temp_home(function()
		local conv = conversation_mod.new("system one")
		conv:add_user("u1")
		conv:add_assistant("a1")
		conv:add_usage(10, 4, 2, 80, 4096, 0.000001, 0.000002, 0.0000005)

		local path, err = conv:save("loaded convo")
		testimony.assert_nil(err)
		testimony.assert_not_nil(path)

		local other = conversation_mod.new("different prompt")
		other:add_usage(3, 1, 0, 20, 4096, 0.000001, 0.000002, 0.0000005)
		local ok, load_err = other:load("loaded convo")
		testimony.assert_true(ok)
		testimony.assert_nil(load_err)
		testimony.assert_equal("loaded convo", other:get_name())
		testimony.assert_equal("system one", other:get_system_prompt())
		testimony.assert_equal(2, other:count())

		local cost = other:get_cost()
		testimony.assert_equal(3, cost.input_tokens)
		testimony.assert_equal(1, cost.output_tokens)
		testimony.assert_equal(0, cost.cached_tokens)
		testimony.assert_equal(1, cost.request_count)
		testimony.assert_equal(20, cost.last_ctx_tokens)
	end)
end)

testify:that("load trims surrounding whitespace in names", function()
	with_temp_home(function()
		local conv = conversation_mod.new("sys")
		local path, err = conv:save("trim me")
		testimony.assert_nil(err)
		testimony.assert_not_nil(path)

		local other = conversation_mod.new("sys2")
		local ok, load_err = other:load("   trim me   ")
		testimony.assert_true(ok)
		testimony.assert_nil(load_err)
		testimony.assert_equal("trim me", other:get_name())
	end)
end)

testify:conclude()
