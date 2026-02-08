-- SPDX-FileCopyrightText: © 2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: OWL-1.0 or later
-- Licensed under the Open Weights License v1.0. See LICENSE for details.

local testimony = require("testimony")
local helpers = require("tests.shell._helpers")

local testify = testimony.new("== agent.mode.agent ==")

local setup_mode = function(options)
	options = options or {}

	helpers.clear_modules({
		"std",
		"term",
		"cjson.safe",
		"llm",
		"term.tss",
		"agent.theme",
		"agent.config",
		"agent.conversation",
		"agent.system_prompt",
		"agent.stream",
		"agent.tools",
		"agent.mode.agent",
	})

	local state = {
		writes = {},
		prompt_calls = {},
		tools_list_calls = 0,
		tool_desc_calls = 0,
		tool_loop_calls = 0,
		last_tool_loop = nil,
	}

	helpers.stub_module("std", {
		utf = {
			len = function(text)
				return #(tostring(text or ""))
			end,
			sub = function(text, start_idx, end_idx)
				return tostring(text or ""):sub(start_idx, end_idx)
			end,
		},
		txt = {
			lines = function(text)
				local out = {}
				for line in tostring(text or ""):gmatch("([^\n]*)\n?") do
					if line ~= "" then
						table.insert(out, line)
					end
				end
				return out
			end,
		},
	})

	helpers.stub_module("term", {
		write = function(text)
			table.insert(state.writes, tostring(text or ""))
			return true
		end,
	})
	helpers.stub_module("cjson.safe", {
		decode = function()
			return {}
		end,
		encode = function()
			return "{}"
		end,
	})
	helpers.stub_module("llm", {
		new = function()
			return {}
		end,
	})
	helpers.stub_module("term.tss", {
		new = function()
			return {
				apply = function(self, key, value)
					return { text = tostring(value or "") }
				end,
			}
		end,
	})
	helpers.stub_module("agent.theme", {})
	helpers.stub_module("agent.config", {
		new = function()
			return {
				get_system_prompt = function()
					return "system"
				end,
				clear_session_approvals = function() end,
				set_model = function()
					return true
				end,
				get_model = function()
					return "m"
				end,
				get_backend = function()
					return "oaic"
				end,
				list_backends = function()
					return { "oaic" }
				end,
				set_backend = function()
					return true
				end,
				get_backend_config = function()
					return { api_style = "oaic", url = "http://localhost", api_key_env = nil }
				end,
				get_model_config = function()
					return { api_style = "oaic" }
				end,
				get_tool_config = function()
					return { approval = "auto" }
				end,
				get_max_tokens = function()
					return 4096
				end,
				get_sampler = function()
					return { temperature = 0, max_new_tokens = 128 }
				end,
				tool_needs_approval = function()
					return false
				end,
				set_session_approval = function() end,
				set_system_prompt = function() end,
			}
		end,
	})
	helpers.stub_module("agent.conversation", {
		new = function()
			return {
				tokens = function()
					return 0
				end,
				get_total_cost = function()
					return 0
				end,
				get_cost = function()
					return {
						request_count = 0,
						input_tokens = 0,
						output_tokens = 0,
						cached_tokens = 0,
						total_cost = 0,
					}
				end,
				count = function()
					return 0
				end,
				save = function()
					return "/tmp/chat.json"
				end,
				load = function()
					return true
				end,
				get_system_prompt = function()
					return "system"
				end,
				set_system_prompt = function() end,
				get_messages = function()
					return {}
				end,
				add_user = function() end,
				add_usage = function() end,
				add_assistant = function() end,
			}
		end,
		list = function()
			return {}
		end,
	})
	helpers.stub_module("agent.system_prompt", {
		get = function()
			return "system"
		end,
	})
	helpers.stub_module("agent.stream", {
		new = function()
			return {
				push = function() end,
				flush = function() end,
				had_output = function()
					return false
				end,
			}
		end,
	})
	helpers.stub_module("agent.tools", {
		list = function()
			state.tools_list_calls = state.tools_list_calls + 1
			return options.tools_list or { "read_file", "write_file" }
		end,
		get_descriptions = function(names)
			state.tool_desc_calls = state.tool_desc_calls + 1
			local out = {}
			for _, name in ipairs(names or {}) do
				table.insert(out, { type = "function", ["function"] = { name = name } })
			end
			return out
		end,
		loop = function(client, model, messages, sampler, opts)
			state.tool_loop_calls = state.tool_loop_calls + 1
			state.last_tool_loop = {
				model = model,
				tools = opts.tools,
				tool_objects = opts.tool_objects,
				execute_tools = opts.execute_tools,
				stream = opts.stream,
				style = opts.style,
			}
			if opts and opts.callbacks and opts.callbacks.chunk then
				opts.callbacks.chunk({ text = "assistant output" })
			end
			if opts and opts.callbacks and opts.callbacks.done then
				opts.callbacks.done()
			end
			return options.loop_response or { text = "ok", tokens = 1, ctx = 2, tool_calls = {} }
		end,
	})

	local prompt_set = function(self, payload)
		local copy = {}
		for k, v in pairs(payload or {}) do
			copy[k] = v
		end
		table.insert(state.prompt_calls, copy)
		return true
	end

	local input_obj = {
		content = options.content or "",
		get_content = function(self)
			return self.content
		end,
		prompt_set = prompt_set,
	}

	local mode_mod = helpers.load_module_from_src("agent.mode.agent", "src/agent/agent/mode/agent.lua")
	local mode = mode_mod.new(input_obj)
	return mode, state, input_obj
end

local has_prompt_status = function(calls, status)
	for _, payload in ipairs(calls or {}) do
		if payload.status == status then
			return true
		end
	end
	return false
end

testify:that("mode exposes required shell contract methods via public API", function()
	local mode, state, input_obj = setup_mode()

	testimony.assert_equal("function", type(mode.run))
	testimony.assert_equal("function", type(mode.get_input))
	testimony.assert_equal("function", type(mode.can_handle_combo))
	testimony.assert_equal("function", type(mode.handle_combo))
	testimony.assert_equal("function", type(mode.list_tools))
	testimony.assert_equal("function", type(mode.get_tool_descriptions))
	testimony.assert_equal("function", type(mode.is_debug_enabled))
	testimony.assert_equal(input_obj, mode:get_input())
	testimony.assert_equal(2, #mode:list_tools())
	testimony.assert_true(state.tools_list_calls >= 1)
	testimony.assert_false(mode:is_debug_enabled())
	testimony.assert_false(mode:can_handle_combo("ALT+x"))
	testimony.assert_false(mode:handle_combo("ALT+x"))
end)

testify:that("run returns zero for empty input", function()
	local mode = setup_mode({ content = "   " })
	local status = mode:run()
	testimony.assert_equal(0, status)
end)

testify:that("debug slash command toggles debug mode through public helper", function()
	local mode = setup_mode({ content = "/debug" })

	testimony.assert_false(mode:is_debug_enabled())
	local status = mode:run()
	testimony.assert_equal(0, status)
	testimony.assert_true(mode:is_debug_enabled())
end)

testify:that("tools slash command uses agent.tools list and renders approvals", function()
	local mode, state = setup_mode({
		content = "/tools",
		tools_list = { "read_file", "bash" },
	})

	local status = mode:run()
	testimony.assert_equal(0, status)
	testimony.assert_true(state.tools_list_calls >= 1)

	local output = table.concat(state.writes, "")
	testimony.assert_match("Available tools:", output)
	testimony.assert_match("read_file %[%s*auto%]", output)
	testimony.assert_match("bash %[%s*auto%]", output)
end)

testify:that("normal run triggers tool loop and prompt streaming transitions", function()
	local mode, state = setup_mode({
		content = "hello",
	})

	local status = mode:run()
	testimony.assert_equal(0, status)
	testimony.assert_equal(1, state.tool_loop_calls)
	testimony.assert_true(state.tool_desc_calls >= 1)
	testimony.assert_true(state.last_tool_loop.execute_tools)
	testimony.assert_true(state.last_tool_loop.stream)
	testimony.assert_equal("oaic", state.last_tool_loop.style)
	testimony.assert_equal(2, #state.last_tool_loop.tools)
	testimony.assert_true(has_prompt_status(state.prompt_calls, "streaming"))
	testimony.assert_true(has_prompt_status(state.prompt_calls, false))
end)

testify:that("unknown slash command returns non-zero and prints guidance", function()
	local mode, state = setup_mode({ content = "/unknown" })

	local status = mode:run()
	testimony.assert_equal(1, status)

	local output = table.concat(state.writes, "")
	testimony.assert_match("Unknown command: /unknown", output)
	testimony.assert_match("Type /help for available commands%.", output)
end)

testify:conclude()
