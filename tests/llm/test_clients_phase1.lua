-- SPDX-FileCopyrightText: © 2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: OWL-1.0 or later
-- Licensed under the Open Weights License v1.0. See LICENSE for details.

local testimony = require("testimony")
local helpers = require("tests.shell._helpers")

local testify = testimony.new("== llm clients phase1 ==")

local setup_oaic = function()
	local calls = {}

	helpers.clear_modules({
		"web",
		"llm.oaic",
	})

	helpers.stub_module("web", {
		request = function(url, opts, timeout)
			table.insert(calls, { url = url, opts = opts, timeout = timeout })
			if url:match("/models$") then
				return { status = 200, body = '{"data":[{"id":"gpt-a"},{"id":"gpt-b"}]}' }
			end
			return {
				status = 200,
				body = '{"model":"oaic-model","usage":{"completion_tokens":5,"total_tokens":11},'
					.. '"choices":[{"message":{"content":"hello"}}]}',
			}
		end,
	})

	local mod = helpers.load_module_from_src("llm.oaic", "src/llm/llm/oaic.lua")
	return mod, calls
end

local setup_anthropic = function()
	local calls = {}

	helpers.clear_modules({
		"web",
		"llm.anthropic",
	})

	helpers.stub_module("web", {
		request = function(url, opts, timeout)
			table.insert(calls, { url = url, opts = opts, timeout = timeout })
			return {
				status = 200,
				body = '{"model":"claude-test","usage":{"input_tokens":9,"output_tokens":4},'
					.. '"content":[{"type":"text","text":"ok"}],"stop_reason":"end_turn"}',
			}
		end,
	})

	local mod = helpers.load_module_from_src("llm.anthropic", "src/llm/llm/anthropic.lua")
	return mod, calls
end

local setup_llamacpp = function()
	local calls = {}

	helpers.clear_modules({
		"web",
		"llm.llamacpp",
	})

	helpers.stub_module("web", {
		request = function(url, opts, timeout)
			table.insert(calls, { url = url, opts = opts, timeout = timeout })
			return {
				status = 200,
				body = '{"model":"glm-test","content":"<tool_call>{\\"name\\":\\"bash\\",\\"arguments\\":{\\"command\\":\\"pwd\\"}}</tool_call>",'
					.. '"timings":{"predicted_n":3,"prompt_n":5,"cache_n":1,"predicted_per_second":12}}',
			}
		end,
	})

	local mod = helpers.load_module_from_src("llm.llamacpp", "src/llm/llm/llamacpp.lua")
	return mod, calls
end

testify:that("oaic client uses cfg/__state and preserves complete/models API", function()
	local mod, calls = setup_oaic()
	local client = mod.new("http://api.local/v1", "token-oaic")

	testimony.assert_equal("oaic", client.cfg.backend)
	testimony.assert_equal("http://api.local/v1", client.cfg.api_url)
	testimony.assert_equal("token-oaic", client.cfg.api_key)
	testimony.assert_true(type(client.__state.headers) == "table")
	testimony.assert_equal("Bearer token-oaic", client.__state.headers.Authorization)
	testimony.assert_equal("function", type(client.complete))
	testimony.assert_equal("function", type(client.stream))
	testimony.assert_equal("function", type(client.chat_complete))
	testimony.assert_equal("function", type(client.chat_stream))
	testimony.assert_equal("function", type(client.models))

	local resp, err = client:complete("gpt-a", { { role = "user", content = "hi" } }, { max_new_tokens = 32 }, {})
	testimony.assert_nil(err)
	testimony.assert_equal("hello", resp.text)
	testimony.assert_equal("oaic", resp.backend)
	testimony.assert_equal(5, resp.tokens)
	testimony.assert_equal(11, resp.ctx)

	local models, models_err = client:models()
	testimony.assert_nil(models_err)
	testimony.assert_equal(2, #models)
	testimony.assert_equal("gpt-a", models[1])
	testimony.assert_equal("gpt-b", models[2])

	testimony.assert_equal("http://api.local/v1/chat/completions", calls[1].url)
	testimony.assert_equal("http://api.local/v1/models", calls[2].url)
end)

testify:that("anthropic client uses cfg/__state and preserves complete API", function()
	local mod, calls = setup_anthropic()
	local client = mod.new("http://anthropic.local/v1", "token-anthropic")

	testimony.assert_equal("anthropic", client.cfg.backend)
	testimony.assert_equal("http://anthropic.local/v1", client.cfg.api_url)
	testimony.assert_equal("token-anthropic", client.cfg.api_key)
	testimony.assert_equal("token-anthropic", client.__state.headers["x-api-key"])
	testimony.assert_equal("function", type(client.complete))
	testimony.assert_equal("function", type(client.stream))
	testimony.assert_equal("function", type(client.chat_complete))
	testimony.assert_equal("function", type(client.chat_stream))

	local resp, err = client:complete("claude", { { role = "user", content = "hello" } }, { max_new_tokens = 16 }, {})
	testimony.assert_nil(err)
	testimony.assert_equal("ok", resp.text)
	testimony.assert_equal("anthropic", resp.backend)
	testimony.assert_equal("claude-test", resp.model)
	testimony.assert_equal(4, resp.tokens)
	testimony.assert_equal(13, resp.ctx)

	testimony.assert_equal(1, #calls)
	testimony.assert_equal("http://anthropic.local/v1/messages", calls[1].url)
end)

testify:that("llamacpp client uses cfg/__state and preserves complete API", function()
	local mod, calls = setup_llamacpp()
	local client = mod.new("http://llama.local", "token-llama")

	testimony.assert_equal("llamacpp", client.cfg.backend)
	testimony.assert_equal("http://llama.local", client.cfg.api_url)
	testimony.assert_equal("token-llama", client.cfg.api_key)
	testimony.assert_true(type(client.__state) == "table")
	testimony.assert_equal("function", type(client.complete))
	testimony.assert_equal("function", type(client.stream))
	testimony.assert_equal("function", type(client.chat_complete))
	testimony.assert_equal("function", type(client.chat_stream))

	local resp, err = client:complete("glm", "prompt", { max_new_tokens = 8 }, nil, nil)
	testimony.assert_nil(err)
	testimony.assert_equal("llamacpp", resp.backend)
	testimony.assert_equal("glm-test", resp.model)
	testimony.assert_equal(3, resp.tokens)
	testimony.assert_equal(9, resp.ctx)
	testimony.assert_equal(1, #resp.tool_calls)
	testimony.assert_equal("bash", resp.tool_calls[1].name)

	testimony.assert_equal(1, #calls)
	testimony.assert_equal("http://llama.local/completion", calls[1].url)
end)

testify:that("llm factory keeps backend routing and unknown-backend error", function()
	helpers.clear_modules({
		"llm",
		"llm.oaic",
		"llm.llamacpp",
		"llm.anthropic",
	})

	helpers.stub_module("llm.oaic", {
		new = function(url, key)
			return { backend = "oaic", url = url, key = key }
		end,
	})
	helpers.stub_module("llm.llamacpp", {
		new = function(url, key)
			return { backend = "llamacpp", url = url, key = key }
		end,
	})
	helpers.stub_module("llm.anthropic", {
		new = function(url, key)
			return { backend = "anthropic", url = url, key = key }
		end,
	})

	local llm = helpers.load_module_from_src("llm", "src/llm/llm.lua")

	local default_client = llm.new(nil, "http://default", "k1")
	testimony.assert_equal("llamacpp", default_client.backend)

	local oaic_client = llm.new("oaic", "http://oaic", "k2")
	testimony.assert_equal("oaic", oaic_client.backend)

	local anthropic_client = llm.new("anthropic", "http://anthropic", "k3")
	testimony.assert_equal("anthropic", anthropic_client.backend)

	local unknown, err = llm.new("unknown", "http://x", "k4")
	testimony.assert_nil(unknown)
	testimony.assert_match("unknown backend:", err)
end)

testify:conclude()
