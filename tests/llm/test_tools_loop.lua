-- SPDX-FileCopyrightText: © 2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: OWL-1.0 or later
-- Licensed under the Open Weights License v1.0. See LICENSE for details.

local testimony = require("testimony")
local json = require("cjson.safe")
local helpers = require("tests.shell._helpers")

local testify = testimony.new("== llm.tools.loop ==")

local BUILTIN_TOOLS = { "read_file", "write_file", "edit_file", "bash", "web_search", "fetch_webpage" }

local setup_tools_module = function()
	local mods = { "llm.tools" }
	for _, name in ipairs(BUILTIN_TOOLS) do
		table.insert(mods, "llm.tools." .. name)
	end
	helpers.clear_modules(mods)

	for _, name in ipairs(BUILTIN_TOOLS) do
		helpers.stub_module("llm.tools." .. name, {
			name = name,
			description = { type = "function", ["function"] = { name = name } },
			execute = function(arguments)
				return { name = name, arguments = arguments or {} }
			end,
		})
	end

	return helpers.load_module_from_src("llm.tools", "src/llm/llm/tools.lua")
end

local make_client = function(backend, responders)
	responders = responders or {}
	local state = {
		complete_calls = {},
		stream_calls = {},
	}

	local client = { backend = backend }

	client.chat_complete = function(self, model, messages, sampler, opts)
		table.insert(state.complete_calls, {
			model = model,
			messages = messages,
			sampler = sampler,
			opts = opts,
		})
		local call_no = #state.complete_calls
		if responders.complete then
			return responders.complete(call_no, model, messages, sampler, opts)
		end
		return nil, "missing complete responder"
	end

	client.chat_stream = function(self, model, messages, sampler, opts)
		table.insert(state.stream_calls, {
			model = model,
			messages = messages,
			sampler = sampler,
			opts = opts,
		})
		local call_no = #state.stream_calls
		if responders.stream then
			return responders.stream(call_no, model, messages, sampler, opts)
		end
		return nil, "missing stream responder"
	end

	return client, state
end

testify:that("normalizes response contract for non-tool completions", function()
	local tools = setup_tools_module()
	local client, calls = make_client("oaic", {
		complete = function()
			return { text = "hello" }
		end,
	})

	local resp, err = tools.loop(client, "demo-model", { { role = "user", content = "hi" } }, {}, {})

	testimony.assert_nil(err)
	testimony.assert_equal(1, #calls.complete_calls)
	testimony.assert_equal("hello", resp.text)
	testimony.assert_equal(0, resp.tokens)
	testimony.assert_equal(0, resp.ctx)
	testimony.assert_equal(0, resp.rate)
	testimony.assert_equal("oaic", resp.backend)
	testimony.assert_equal("demo-model", resp.model)
end)

testify:that("runs OAIC tool loop, callbacks, and message append flow", function()
	local tools = setup_tools_module()
	tools.register("sum", {
		description = { type = "function", ["function"] = { name = "sum" } },
		execute = function(arguments)
			return { total = (arguments.a or 0) + (arguments.b or 0) }
		end,
	})

	local second_call_messages = nil
	local client, calls = make_client("oaic", {
		complete = function(call_no, model, messages)
			if call_no == 1 then
				return {
					text = "planning",
					response_id = "resp_1",
					tool_calls = {
						{ id = "call_1", name = "sum", arguments = '{"a":2,"b":3}' },
					},
				}
			end
			second_call_messages = messages
			return {
				text = "done",
				tokens = 7,
				ctx = 21,
				rate = 3,
				backend = "oaic",
				model = model,
			}
		end,
	})

	local callback_seen = {
		call = false,
		result = false,
	}

	local resp, err = tools.loop(client, "calc-model", { { role = "user", content = "compute" } }, {}, {
		execute_tools = true,
		style = "oaic",
		on_tool_call = function(call)
			callback_seen.call = (call.name == "sum")
			return { action = "allow" }
		end,
		on_tool_result = function(call, result, is_error)
			callback_seen.result = (call.name == "sum") and not is_error and (result.total == 5)
		end,
	})

	testimony.assert_nil(err)
	testimony.assert_equal(2, #calls.complete_calls)
	testimony.assert_equal("done", resp.text)
	testimony.assert_true(callback_seen.call)
	testimony.assert_true(callback_seen.result)

	testimony.assert_equal(3, #second_call_messages)
	testimony.assert_equal("assistant", second_call_messages[2].role)
	testimony.assert_equal("resp_1", second_call_messages[2].response_id)
	testimony.assert_equal("tool", second_call_messages[3].role)
	testimony.assert_equal("call_1", second_call_messages[3].tool_call_id)

	local tool_payload = json.decode(second_call_messages[3].content) or {}
	testimony.assert_equal(5, tool_payload.total)
end)

testify:that("uses Anthropic style append flow and deny path semantics", function()
	local tools = setup_tools_module()

	local second_call_messages = nil
	local callback_is_error = false
	local client, calls = make_client("anthropic", {
		complete = function(call_no, model, messages)
			if call_no == 1 then
				return {
					text = "checking",
					tool_calls = {
						{ id = "tool_1", name = "read_file", arguments = '{"filepath":"README.md"}' },
					},
				}
			end
			second_call_messages = messages
			return {
				text = "fallback answer",
			}
		end,
	})

	local resp, err = tools.loop(client, "claude-x", { { role = "user", content = "read file" } }, {}, {
		execute_tools = true,
		on_tool_call = function()
			return { action = "deny", error = "blocked by user" }
		end,
		on_tool_result = function(call, result, is_error)
			callback_is_error = (call.name == "read_file") and is_error and (result.error == "blocked by user")
		end,
	})

	testimony.assert_nil(err)
	testimony.assert_equal(2, #calls.complete_calls)
	testimony.assert_true(callback_is_error)
	testimony.assert_equal("fallback answer", resp.text)
	testimony.assert_equal("anthropic", resp.backend)
	testimony.assert_equal("claude-x", resp.model)
	testimony.assert_equal(0, resp.tokens)
	testimony.assert_equal(0, resp.ctx)

	testimony.assert_equal("assistant", second_call_messages[2].role)
	testimony.assert_equal("user", second_call_messages[3].role)
	testimony.assert_equal("tool_result", second_call_messages[3].content[1].type)
	testimony.assert_true(second_call_messages[3].content[1].is_error)

	local denied = json.decode(second_call_messages[3].content[1].content) or {}
	testimony.assert_equal("blocked by user", denied.error)
end)

testify:that("marks tool envelope errors as errors in callbacks and anthropic messages", function()
	local tools = setup_tools_module()
	tools.register("broken", {
		description = { type = "function", ["function"] = { name = "broken" } },
		execute = function()
			return { name = "broken", ok = false, error = "intentional failure" }
		end,
	})

	local second_call_messages = nil
	local callback_is_error = false
	local client, calls = make_client("anthropic", {
		complete = function(call_no, model, messages)
			if call_no == 1 then
				return {
					text = "trying",
					tool_calls = {
						{ id = "tool_err", name = "broken", arguments = "{}" },
					},
				}
			end
			second_call_messages = messages
			return { text = "done" }
		end,
	})

	local resp, err = tools.loop(client, "claude-x", { { role = "user", content = "go" } }, {}, {
		execute_tools = true,
		on_tool_result = function(call, result, is_error)
			callback_is_error = (call.name == "broken") and is_error and (result.error == "intentional failure")
		end,
	})

	testimony.assert_nil(err)
	testimony.assert_equal(2, #calls.complete_calls)
	testimony.assert_true(callback_is_error)
	testimony.assert_equal("done", resp.text)
	testimony.assert_true(second_call_messages[3].content[1].is_error)
end)

testify:that("returns aborted response when tool call is aborted in XML style", function()
	local tools = setup_tools_module()
	tools.register("echo", {
		description = { type = "function", ["function"] = { name = "echo" } },
		execute = function(arguments)
			return { ok = true, value = arguments.value }
		end,
	})

	local client, calls = make_client("llamacpp", {
		complete = function()
			return {
				text = "need a tool",
				tool_calls = {
					{ name = "echo", arguments = { value = "x" } },
				},
			}
		end,
	})

	local resp, err = tools.loop(client, "glm", { { role = "user", content = "run" } }, {}, {
		execute_tools = true,
		on_tool_call = function()
			return { action = "abort", message = "stop now" }
		end,
	})

	testimony.assert_nil(err)
	testimony.assert_equal(1, #calls.complete_calls)
	testimony.assert_true(resp.aborted)
	testimony.assert_equal("stop now", resp.abort_message)
	testimony.assert_equal("llamacpp", resp.backend)
	testimony.assert_equal("glm", resp.model)
	testimony.assert_equal(0, resp.tokens)
end)

testify:that("keeps raw malformed argument payloads for XML tool execution", function()
	local tools = setup_tools_module()
	tools.register("inspect", {
		description = { type = "function", ["function"] = { name = "inspect" } },
		execute = function(arguments)
			return { name = "inspect", ok = true, seen = arguments }
		end,
	})

	local second_call_messages = nil
	local client, calls = make_client("llamacpp", {
		complete = function(call_no, model, messages)
			if call_no == 1 then
				return {
					text = "inspect",
					tool_calls = {
						{ name = "inspect", arguments = "{bad-json" },
					},
				}
			end
			second_call_messages = messages
			return { text = "done" }
		end,
	})

	local resp, err = tools.loop(client, "glm", { { role = "user", content = "run" } }, {}, {
		execute_tools = true,
		style = "xml",
	})

	testimony.assert_nil(err)
	testimony.assert_equal(2, #calls.complete_calls)
	testimony.assert_equal("done", resp.text)
	testimony.assert_equal("{bad-json", second_call_messages[3].tool_responses[1].seen.raw)
end)

testify:that("uses chat_stream path and returns max_steps error when tool loop cannot finish", function()
	local tools = setup_tools_module()
	tools.register("echo", {
		description = { type = "function", ["function"] = { name = "echo" } },
		execute = function(arguments)
			return { ok = true, value = arguments.value }
		end,
	})

	local client, calls = make_client("oaic", {
		stream = function(call_no)
			return {
				text = "",
				tool_calls = {
					{ id = "stream_" .. call_no, name = "echo", arguments = { value = call_no } },
				},
			}
		end,
	})

	local resp, err = tools.loop(client, "stream-model", { { role = "user", content = "go" } }, {}, {
		stream = true,
		execute_tools = true,
		style = "oaic",
		max_steps = 2,
	})

	testimony.assert_nil(resp)
	testimony.assert_equal("tool loop exceeded max_steps", err)
	testimony.assert_equal(0, #calls.complete_calls)
	testimony.assert_equal(2, #calls.stream_calls)
end)

testify:conclude()
