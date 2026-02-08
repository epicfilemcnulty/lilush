-- SPDX-FileCopyrightText: © 2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: OWL-1.0 or later
-- Licensed under the Open Weights License v1.0. See LICENSE for details.

local testimony = require("testimony")
local json = require("cjson.safe")
local helpers = require("tests.shell._helpers")

local testify = testimony.new("== agent.config ==")

local deep_copy

deep_copy = function(value, seen)
	if type(value) ~= "table" then
		return value
	end

	seen = seen or {}
	if seen[value] then
		return seen[value]
	end

	local out = {}
	seen[value] = out
	for k, v in pairs(value) do
		out[deep_copy(k, seen)] = deep_copy(v, seen)
	end
	return out
end

local deep_merge

deep_merge = function(base, override)
	local out = deep_copy(base or {})
	for k, v in pairs(override or {}) do
		if type(v) == "table" and type(out[k]) == "table" then
			out[k] = deep_merge(out[k], v)
		else
			out[k] = deep_copy(v)
		end
	end
	return out
end

local setup_config = function(file_cfg)
	local state = {
		reads = {},
		mkdir_calls = {},
		writes = {},
		last_pricing = nil,
	}

	helpers.clear_modules({
		"std",
		"llm.pricing",
		"agent.config",
	})

	helpers.stub_module("std", {
		fs = {
			read_file = function(path)
				table.insert(state.reads, path)
				if file_cfg and path:match("/%.config/lilush/agent%.json$") then
					return json.encode(file_cfg)
				end
				return nil
			end,
			mkdir = function(path)
				table.insert(state.mkdir_calls, path)
				return true
			end,
			write_file = function(path, content)
				table.insert(state.writes, { path = path, content = content })
				return true
			end,
		},
		tbl = {
			merge = deep_merge,
			copy = deep_copy,
		},
	})

	helpers.stub_module("llm.pricing", {
		set_custom_prices = function(prices)
			state.last_pricing = deep_copy(prices)
		end,
	})

	local mod = helpers.load_module_from_src("agent.config", "src/agent/agent/config.lua")
	return mod, state
end

testify:that("config applies file overrides and initializes pricing overrides", function()
	local mod, state = setup_config({
		backend = "oaic",
		model = "gpt-5",
		pricing = {
			["custom-model"] = { input = 1.1, output = 2.2 },
		},
		tools = {
			bash = { approval = "ask" },
		},
	})

	local cfg = mod.new()
	testimony.assert_equal("oaic", cfg:get_backend())
	testimony.assert_equal("gpt-5", cfg:get_model())
	testimony.assert_true(type(state.last_pricing) == "table")
	testimony.assert_equal(1.1, state.last_pricing["custom-model"].input)
	testimony.assert_true(cfg:tool_needs_approval("bash"))
	cfg:set_session_approval("bash", "auto")
	testimony.assert_false(cfg:tool_needs_approval("bash"))
	cfg:clear_session_approvals()
	testimony.assert_true(cfg:tool_needs_approval("bash"))
end)

testify:that("backend/model switching and model-config fallback are stable", function()
	local mod = setup_config(nil)
	local cfg = mod.new()

	local ok, err = cfg:set_backend("nope")
	testimony.assert_nil(ok)
	testimony.assert_match("unknown backend:", err)

	local set_ok = cfg:set_model("claude-opus-4-5", "zen")
	testimony.assert_true(set_ok)
	testimony.assert_equal("zen", cfg:get_backend())
	testimony.assert_equal("claude-opus-4-5", cfg:get_model())
	testimony.assert_equal("anthropic", cfg:get_model_config().api_style)

	cfg.cfg.backends.test_backend = {
		default_model = "foo",
	}
	cfg:set_backend("test_backend")
	local model_cfg = cfg:get_model_config("unknown-model")
	testimony.assert_equal("oaic", model_cfg.api_style)
	testimony.assert_equal("/chat/completions", model_cfg.endpoint)
end)

testify:that("sampler copy and save payload stay behavior-compatible", function()
	local mod, state = setup_config(nil)
	local cfg = mod.new()

	local sampler = cfg:get_sampler()
	sampler.max_new_tokens = 1
	local sampler_again = cfg:get_sampler()
	testimony.assert_false(sampler_again.max_new_tokens == 1)

	cfg:set_sampler({ temperature = 0.2 })
	cfg:set_system_prompt("sys")
	local save_ok, save_err = cfg:save()
	testimony.assert_true(save_ok)
	testimony.assert_nil(save_err)
	testimony.assert_equal(1, #state.writes)
	testimony.assert_true(state.writes[1].path:match("/%.config/lilush/agent%.json$") ~= nil)

	local decoded = json.decode(state.writes[1].content)
	testimony.assert_equal("sys", decoded.system_prompt)
	testimony.assert_true(decoded.sampler.temperature == 0.2)
	testimony.assert_nil(decoded.session_approvals)
end)

testify:conclude()
