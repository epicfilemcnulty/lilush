-- SPDX-FileCopyrightText: © 2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: OWL-1.0 or later
-- Licensed under the Open Weights License v1.0. See LICENSE for details.

local testimony = require("testimony")
local helpers = require("tests.shell._helpers")

local testify = testimony.new("== llm clients phase3 ==")

local make_std_stub = function()
	local tick = 1000
	return {
		time_ms = function()
			tick = tick + 100
			return tick
		end,
		sleep_ms = function()
			return true
		end,
	}
end

local make_sse_client = function(events, callbacks)
	local index = 0
	local connected = true
	local closed = false
	local close = nil

	close = function()
		if closed then
			return true
		end
		closed = true
		connected = false
		if callbacks.close then
			callbacks.close()
		end
		return true
	end

	return {
		connect = function()
			return true
		end,
		update = function()
			index = index + 1
			local event = events[index]
			if not event then
				return false
			end
			if event.kind == "message" and callbacks.message then
				callbacks.message(event.value)
			elseif event.kind == "error" and callbacks.error then
				callbacks.error(event.value)
			elseif event.kind == "close" then
				close()
			end
			return true
		end,
		is_connected = function()
			return connected
		end,
		close = close,
	}
end

testify:that("oaic stream extracts text/tool_calls and propagates sse errors", function()
	helpers.clear_modules({
		"std",
		"web",
		"llm.oaic",
	})

	local sse_events = {
		{
			kind = "message",
			value = {
				choices = {
					{
						delta = {
							content = "Hi ",
							tool_calls = {
								{
									index = 0,
									id = "call_1",
									type = "function",
									["function"] = { name = "read_file", arguments = '{"filepath":"RE' },
								},
							},
						},
					},
				},
			},
		},
		{
			kind = "message",
			value = {
				usage = {
					completion_tokens = 3,
					total_tokens = 9,
				},
				choices = {
					{
						delta = {
							content = "there",
							tool_calls = {
								{
									index = 0,
									["function"] = { arguments = 'ADME.md"}' },
								},
							},
						},
					},
				},
			},
		},
		{ kind = "message", value = "[DONE]" },
	}

	helpers.stub_module("std", make_std_stub())
	helpers.stub_module("web", {
		request = function()
			return nil, "not used"
		end,
		sse_client = function(url, req, callbacks)
			return make_sse_client(sse_events, callbacks)
		end,
	})

	local oaic = helpers.load_module_from_src("llm.oaic", "src/llm/llm/oaic.lua")
	local client = oaic.new("http://oaic.local/v1", "token")

	local resp, err = client:stream("gpt", { { role = "user", content = "hello" } }, { max_new_tokens = 32 }, {}, {})
	testimony.assert_nil(err)
	testimony.assert_equal("Hi there", resp.text)
	testimony.assert_equal(1, #resp.tool_calls)
	testimony.assert_equal("read_file", resp.tool_calls[1].name)
	testimony.assert_equal('{"filepath":"README.md"}', resp.tool_calls[1].arguments)
	testimony.assert_equal(3, resp.tokens)
	testimony.assert_equal(9, resp.ctx)

	-- Error propagation from SSE callback.
	helpers.clear_modules({ "std", "web", "llm.oaic" })
	helpers.stub_module("std", make_std_stub())
	helpers.stub_module("web", {
		request = function()
			return nil, "not used"
		end,
		sse_client = function(url, req, callbacks)
			return make_sse_client({
				{ kind = "error", value = "http status: 401" },
				{ kind = "message", value = "[DONE]" },
			}, callbacks)
		end,
	})
	oaic = helpers.load_module_from_src("llm.oaic", "src/llm/llm/oaic.lua")
	client = oaic.new("http://oaic.local/v1", "token")

	local failed, stream_err = client:stream(
		"gpt",
		{ { role = "user", content = "hello" } },
		{ max_new_tokens = 32 },
		{},
		{}
	)
	testimony.assert_nil(failed)
	testimony.assert_equal("http status: 401", stream_err)
end)

testify:that("anthropic stream extracts text/tool_calls and tracks usage", function()
	helpers.clear_modules({
		"std",
		"web",
		"llm.anthropic",
	})
	helpers.stub_module("std", make_std_stub())
	helpers.stub_module("web", {
		request = function()
			return nil, "not used"
		end,
		sse_client = function(url, req, callbacks)
			return make_sse_client({
				{
					kind = "message",
					value = {
						data = {
							type = "message_start",
							message = { model = "claude-x", usage = { input_tokens = 8 } },
						},
					},
				},
				{
					kind = "message",
					value = { data = { type = "content_block_start", index = 0, content_block = { type = "text" } } },
				},
				{
					kind = "message",
					value = { data = { type = "content_block_delta", delta = { type = "text_delta", text = "A" } } },
				},
				{
					kind = "message",
					value = { data = { type = "content_block_stop" } },
				},
				{
					kind = "message",
					value = {
						data = {
							type = "content_block_start",
							index = 1,
							content_block = { type = "tool_use", id = "tool_1", name = "read_file" },
						},
					},
				},
				{
					kind = "message",
					value = {
						data = {
							type = "content_block_delta",
							delta = { type = "input_json_delta", partial_json = '{"filepath":"README.md"}' },
						},
					},
				},
				{
					kind = "message",
					value = { data = { type = "content_block_stop" } },
				},
				{
					kind = "message",
					value = {
						data = {
							type = "message_delta",
							delta = { stop_reason = "tool_use" },
							usage = { output_tokens = 2 },
						},
					},
				},
				{
					kind = "message",
					value = { data = { type = "message_stop" } },
				},
			}, callbacks)
		end,
	})

	local anthropic = helpers.load_module_from_src("llm.anthropic", "src/llm/llm/anthropic.lua")
	local client = anthropic.new("http://anthropic.local/v1", "token")

	local resp, err = client:stream("claude", { { role = "user", content = "hello" } }, { max_new_tokens = 20 }, {}, {})
	testimony.assert_nil(err)
	testimony.assert_equal("A", resp.text)
	testimony.assert_equal("claude-x", resp.model)
	testimony.assert_equal(2, resp.tokens)
	testimony.assert_equal(10, resp.ctx)
	testimony.assert_equal(1, #resp.tool_calls)
	testimony.assert_equal("read_file", resp.tool_calls[1].name)
	testimony.assert_true(resp.tool_calls[1].arguments:match("README%.md") ~= nil)
end)

testify:that("llamacpp stream extracts xml tool_calls and complete propagates http errors", function()
	helpers.clear_modules({
		"std",
		"web",
		"llm.llamacpp",
	})
	helpers.stub_module("std", make_std_stub())
	helpers.stub_module("web", {
		request = function()
			return { status = 503, body = "upstream unavailable" }
		end,
		sse_client = function(url, req, callbacks)
			return make_sse_client({
				{
					kind = "message",
					value = {
						content = '<tool_call>{"name":"bash","arguments":{"command":"pwd"}}</tool_call>',
						timings = { predicted_n = 2, prompt_n = 3, cache_n = 1, predicted_per_second = 10 },
						stop = true,
					},
				},
			}, callbacks)
		end,
	})

	local llamacpp = helpers.load_module_from_src("llm.llamacpp", "src/llm/llm/llamacpp.lua")
	local client = llamacpp.new("http://llama.local", "token")

	local stream_resp, stream_err = client:stream("glm", "prompt", { max_new_tokens = 20 }, nil, nil, {})
	testimony.assert_nil(stream_err)
	testimony.assert_equal(1, #stream_resp.tool_calls)
	testimony.assert_equal("bash", stream_resp.tool_calls[1].name)
	testimony.assert_equal(2, stream_resp.tokens)
	testimony.assert_equal(6, stream_resp.ctx)

	local complete_resp, complete_err = client:complete("glm", "prompt", { max_new_tokens = 20 }, nil, nil)
	testimony.assert_nil(complete_resp)
	testimony.assert_match("bad response status:", complete_err)
end)

testify:conclude()
