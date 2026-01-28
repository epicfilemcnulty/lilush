-- SPDX-FileCopyrightText: © 2022—2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: OWL-1.0 or later
-- Licensed under the Open Weights License v1.0. See LICENSE for details.

local json = require("cjson.safe")
local std = require("std")
local buffer = require("string.buffer")
local web = require("web")

-- Parse XML tool calls from text
local parse_tool_calls = function(text)
	text = text or ""
	local calls = {}
	for call_info in text:gmatch("<tool_call>(.-)</tool_call>") do
		local info = json.decode(call_info)
		if info then
			table.insert(calls, {
				id = info.id,
				type = info.type or "function",
				name = info.name,
				arguments = info.arguments,
			})
		end
	end
	return calls
end

local complete = function(self, model, query, sampler, sc, uuid)
	local data = {
		model = model,
		temperature = sampler.temperature,
		top_k = sampler.top_k,
		top_p = sampler.top_p,
		min_p = sampler.min_p,
		dry_multiplier = sampler.dry_multiplier,
		repeat_penalty = sampler.repetition_penalty,
		presence_penalty = sampler.presence_penalty,
		n_predict = sampler.max_new_tokens,
		prompt = query,
	}
	if sc and #sc > 0 then
		data.stop = sc
	end
	local headers = { ["Content-Type"] = "application/json" }
	if self.api_key then
		headers["Authorization"] = "Bearer " .. self.api_key
	end
	local resp, err = web.request(
		self.api_url .. "/completion",
		{ method = "POST", body = json.encode(data), headers = headers },
		self.timeout
	)
	if resp then
		if resp.status == 200 then
			local response, err = json.decode(resp.body)
			if err then
				return nil, err
			end
			local text = response.content or ""
			local timings = response.timings or {}
			local predicted_n = timings.predicted_n or 0
			local prompt_n = timings.prompt_n or 0
			local cache_n = timings.cache_n or 0
			local answer = {
				text = text,
				model = response.model or model,
				backend = "llamacpp",
				tokens = predicted_n,
				ctx = prompt_n + cache_n + predicted_n,
				rate = timings.predicted_per_second or 0,
				raw = response,
			}
			local tool_calls = parse_tool_calls(answer.text)
			if #tool_calls > 0 then
				answer.tool_calls = tool_calls
			end
			return answer
		end
		return nil, "bad response status: " .. resp.status .. "\n" .. resp.body
	end
	return nil, "request failed: " .. tostring(err)
end

local stream = function(self, model, query, sampler, sc, uuid, user_callbacks)
	user_callbacks = user_callbacks or {}
	local req_body = {
		model = model,
		prompt = query,
		temperature = sampler.temperature,
		top_k = sampler.top_k,
		top_p = sampler.top_p,
		min_p = sampler.min_p,
		dry_multiplier = sampler.dry_multiplier,
		repeat_penalty = sampler.repetition_penalty,
		presence_penalty = sampler.presence_penalty,
		n_predict = sampler.max_new_tokens,
		stream = true,
	}
	if sc and #sc > 0 then
		req_body.stop = sc
	end

	local headers = { ["Content-Type"] = "application/json" }
	if self.api_key then
		headers["Authorization"] = "Bearer " .. self.api_key
	end

	local full_text = buffer.new()
	local last_event = nil
	local client
	local callbacks = {
		message = function(data)
			if type(data) == "string" then
				if data == "[DONE]" then
					client:close()
				end
				return
			end
			if type(data) ~= "table" then
				return
			end
			last_event = data
			if data.content then
				full_text:put(data.content)
				if user_callbacks.chunk then
					user_callbacks.chunk({ text = data.content, raw = data })
				end
			end
			if data.stop then
				client:close()
			end
		end,
		close = function()
			if user_callbacks.done then
				user_callbacks.done(last_event)
			end
		end,
	}

	client = web.sse_client(
		self.api_url .. "/completion",
		{ method = "POST", body = json.encode(req_body), headers = headers },
		callbacks
	)
	local ok, err = client:connect()
	if not ok then
		return nil, err
	end

	local running = true
	while running do
		running = client:update() and client:is_connected()
		std.sleep_ms(50)
	end

	local ft = full_text:get()
	local tool_calls = parse_tool_calls(ft)
	local timings = (type(last_event) == "table" and last_event.timings) or {}
	local predicted_n = timings.predicted_n or 0
	local prompt_n = timings.prompt_n or 0
	local cache_n = timings.cache_n or 0
	local response = {
		text = ft,
		backend = "llamacpp",
		model = model,
		tokens = predicted_n,
		ctx = prompt_n + cache_n + predicted_n,
		rate = timings.predicted_per_second or 0,
		raw = last_event,
	}
	if #tool_calls > 0 then
		response.tool_calls = tool_calls
	end
	return response
end

-- Chat methods
local chat_complete = function(self, model, messages, sampler, opts)
	opts = opts or {}
	local templates = require("llm.templates")
	local tools_mod = require("llm.tools")

	local tool_descs = {}
	if opts.tools then
		tool_descs = tools_mod.get_descriptions(opts.tools)
	elseif opts.tool_descriptions then
		tool_descs = opts.tool_descriptions
	end

	local prompt = templates.apply(opts.template, messages, tool_descs, opts.dont_start)
	return self:complete(model, prompt, sampler, opts.stop_conditions, opts.uuid)
end

local chat_stream = function(self, model, messages, sampler, opts)
	opts = opts or {}
	local templates = require("llm.templates")
	local tools_mod = require("llm.tools")

	local tool_descs = {}
	if opts.tools then
		tool_descs = tools_mod.get_descriptions(opts.tools)
	elseif opts.tool_descriptions then
		tool_descs = opts.tool_descriptions
	end

	local prompt = templates.apply(opts.template, messages, tool_descs, opts.dont_start)
	local callbacks = opts.callbacks or {}
	return self:stream(model, prompt, sampler, opts.stop_conditions, opts.uuid, callbacks)
end

local new = function(api_url, api_key)
	api_url = api_url or os.getenv("LLM_API_URL") or "http://127.0.0.1:8080"
	local timeout = tonumber(os.getenv("LLM_API_TIMEOUT")) or 600
	local client = {
		api_url = api_url,
		api_key = api_key or os.getenv("LLM_API_KEY") or os.getenv("OPENAI_API_KEY"),
		backend = "llamacpp",
		timeout = timeout,
		complete = complete,
		stream = stream,
		chat_complete = chat_complete,
		chat_stream = chat_stream,
	}
	return client
end

return { new = new }
