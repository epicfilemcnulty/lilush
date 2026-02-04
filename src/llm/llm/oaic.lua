-- SPDX-FileCopyrightText: © 2022—2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: OWL-1.0 or later
-- Licensed under the Open Weights License v1.0. See LICENSE for details.

-- API docs:
-- https://platform.openai.com/docs/api-reference/chat

local json = require("cjson.safe")
local web = require("web")
local std = require("std")
local buffer = require("string.buffer")

local sanitize = function(messages)
	local sanitized = {}
	for _, v in ipairs(messages or {}) do
		local m = { role = v.role, content = v.content }
		if m.role == "tool" and type(m.content) ~= "string" then
			m.content = json.encode(m.content) or tostring(m.content)
		end
		if v.name then
			m.name = v.name
		end
		if v.tool_call_id then
			m.tool_call_id = v.tool_call_id
		end
		if v.tool_calls then
			m.tool_calls = v.tool_calls
		end
		table.insert(sanitized, m)
	end
	return sanitized
end

-- Normalize tool calls to canonical format
local normalize_tool_calls = function(calls)
	if type(calls) ~= "table" then
		return nil
	end
	local out = {}
	for _, c in ipairs(calls) do
		if type(c) == "table" then
			local id = c.id
			local name = c.name
			local args = c.arguments
			local kind = c.type
			if not name and type(c["function"]) == "table" then
				name = c["function"].name
				args = c["function"].arguments
				kind = kind or "function"
			end
			if not name and type(c.function_call) == "table" then
				name = c.function_call.name
				args = c.function_call.arguments
				kind = kind or "function"
			end
			if name then
				table.insert(out, { id = id, type = kind or "function", name = name, arguments = args })
			end
		end
	end
	return out
end

local extract_oai_tool_calls = function(choice)
	local msg = choice and choice.message
	if not msg then
		return nil
	end
	if msg.tool_calls then
		return normalize_tool_calls(msg.tool_calls)
	end
	if msg.function_call then
		return normalize_tool_calls({ { type = "function", ["function"] = msg.function_call } })
	end
	return nil
end

local extract_oai_text = function(choice)
	if not choice then
		return ""
	end
	local msg = choice.message
	if msg then
		local c = msg.content
		if c ~= nil then
			if type(c) == "string" then
				if #c > 0 then
					return c
				end
				-- Empty content: fall through to reasoning/tool results.
			end
			local s = tostring(c)
			if s and not s:match("^userdata:") and not s:match("^cdata:") then
				if #s > 0 then
					return s
				end
			end
		end
		if type(c) == "table" then
			-- Some servers use an array of content parts.
			local parts = {}
			for _, p in ipairs(c) do
				if type(p) == "table" then
					local t = p.text or p.content
					if t ~= nil then
						local s = t
						if type(s) ~= "string" then
							s = tostring(s)
							if s:match("^userdata:") or s:match("^cdata:") then
								s = nil
							end
						end
						if s and #s > 0 then
							table.insert(parts, s)
						end
					end
				end
			end
			if #parts > 0 then
				return table.concat(parts)
			end
		end
		if type(msg.reasoning_content) == "string" then
			return msg.reasoning_content
		end
		return ""
	end
	if type(choice.text) == "string" then
		return choice.text
	end
	return ""
end

local request = function(url, json_data, headers, timeout, backend, debug_mode)
	local start = os.time()
	local resp, err = web.request(url, { method = "POST", body = json_data, headers = headers }, timeout)
	if resp then
		if resp.status == 200 then
			local duration = os.time() - start
			local resp_json = json.decode(resp.body)
			local answer = {}
			if resp_json then
				local usage = resp_json.usage or {}
				answer.tokens = usage.completion_tokens
				if not answer.tokens then
					answer.tokens = usage.output_tokens or 0
				end
				answer.ctx = usage.total_tokens
				if not answer.ctx then
					answer.ctx = (usage.input_tokens or 0) + answer.tokens
				end
				answer.model = resp_json.model
				answer.rate = duration > 0 and (answer.tokens / duration) or 0
				if debug_mode then
					answer.raw = resp_json
				end
				if resp_json.choices then
					local c1 = resp_json.choices[1]
					local tc = extract_oai_tool_calls(c1)
					if tc then
						answer.tool_calls = tc
					end
					answer.text = extract_oai_text(c1)
				elseif resp_json.content then
					answer.text = resp_json.content[1].text
				end
				-- Clean up response text: remove leading newlines and common EOS token artifacts
			answer.text = tostring(answer.text or "")
				:gsub("^\n+", "")
				:gsub("<|im_end|>%s*$", "")
				:gsub("<|eot_id|>%s*$", "")
				:gsub("</s>%s*$", "")
				:gsub("%s+$", "")
				answer.backend = backend
				return answer
			end
			return nil, "failed to decode response"
		end
		return nil, "bad response status: " .. resp.status .. "\n" .. resp.body
	end
	return nil, "request failed: " .. tostring(err)
end

local models = function(self)
	local resp, err = web.request(self.api_url .. "/models", { method = "GET", headers = self.headers }, self.timeout)
	if not resp or resp.status ~= 200 then
		return nil, err or (resp and ("bad response status: " .. resp.status .. "\n" .. tostring(resp.body)))
	end
	local models = {}
	local decoded = json.decode(resp.body) or {}
	for _, model in ipairs(decoded.data) do
		table.insert(models, model.id)
	end
	return models
end

local complete = function(self, model, messages, sampler, opts)
	opts = opts or {}
	local data = {
		model = model,
		max_tokens = sampler.max_new_tokens,
		messages = sanitize(messages),
		temperature = sampler.temperature,
		top_p = sampler.top_p,
		top_k = sampler.top_k,
		min_p = sampler.min_p,
	}
	if opts.tool_objects and #opts.tool_objects > 0 then
		data.tools = opts.tool_objects
		if opts.tool_choice then
			data.tool_choice = opts.tool_choice
		end
	end
	return request(
		self.api_url .. "/chat/completions",
		json.encode(data),
		self.headers,
		self.timeout,
		self.backend,
		self.debug_mode
	)
end

local stream = function(self, model, messages, sampler, user_callbacks, opts)
	opts = opts or {}
	user_callbacks = user_callbacks or {}
	local data = {
		model = model,
		max_tokens = sampler.max_new_tokens,
		messages = sanitize(messages),
		temperature = sampler.temperature,
		top_p = sampler.top_p,
		top_k = sampler.top_k,
		min_p = sampler.min_p,
		stream = true,
		stream_options = { include_usage = true },
	}
	if opts.tool_objects and #opts.tool_objects > 0 then
		data.tools = opts.tool_objects
		if opts.tool_choice then
			data.tool_choice = opts.tool_choice
		end
	end

	local full_text = buffer.new()
	local usage = nil
	local tool_by_index = {}
	local legacy_fn = { name = nil, arguments = "" }
	local start_ms = (std.time_ms and std.time_ms()) or nil
	local http_error = nil
	local client
	local callbacks = {
		error = function(msg)
			http_error = msg
			if user_callbacks.error then
				user_callbacks.error(msg)
			end
		end,
		message = function(chunk)
			if type(chunk) == "string" then
				if chunk == "[DONE]" then
					client:close()
				end
				return
			end
			if type(chunk) ~= "table" then
				return
			end
			if chunk.usage then
				usage = chunk.usage
			end
			local choice = chunk.choices and chunk.choices[1]
			local delta = choice and choice.delta
			if delta and delta.tool_calls then
				for _, tc in ipairs(delta.tool_calls) do
					if type(tc) == "table" then
						local idx = tc.index or 0
						local st = tool_by_index[idx]
							or {
								id = tc.id,
								type = tc.type or "function",
								["function"] = { name = nil, arguments = "" },
							}
						tool_by_index[idx] = st
						if tc.id then
							st.id = tc.id
						end
						if tc["function"] then
							if tc["function"].name then
								st["function"].name = tc["function"].name
							end
							if tc["function"].arguments then
								st["function"].arguments = (st["function"].arguments or "") .. tc["function"].arguments
							end
						end
					end
				end
			end
			if delta and delta.function_call then
				legacy_fn.name = delta.function_call.name or legacy_fn.name
				if delta.function_call.arguments then
					legacy_fn.arguments = legacy_fn.arguments .. delta.function_call.arguments
				end
			end
			local delta_text = delta and (delta.content or delta.reasoning_content or delta.text)
			if delta_text ~= nil then
				local s = delta_text
				if type(s) ~= "string" then
					s = tostring(s)
					if s:match("^userdata:") or s:match("^cdata:") then
						s = nil
					end
				end
				if s and #s > 0 then
					full_text:put(s)
					if user_callbacks.chunk then
						local chunk_data = { text = s }
						if self.debug_mode then
							chunk_data.raw = chunk
						end
						user_callbacks.chunk(chunk_data)
					end
				end
			end
		end,
		close = function()
			if user_callbacks.done then
				user_callbacks.done()
			end
		end,
	}

	client = web.sse_client(
		self.api_url .. "/chat/completions",
		{ method = "POST", body = json.encode(data), headers = self.headers },
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

	-- Check for HTTP errors (non-2xx status codes)
	if http_error then
		return nil, http_error
	end

	local ft = full_text:get()
	local tool_calls = {}
	local indices = {}
	for idx, _ in pairs(tool_by_index) do
		table.insert(indices, idx)
	end
	table.sort(indices)
	for _, idx in ipairs(indices) do
		table.insert(tool_calls, tool_by_index[idx])
	end
	if #tool_calls == 0 and legacy_fn.name then
		tool_calls =
			{ { type = "function", ["function"] = { name = legacy_fn.name, arguments = legacy_fn.arguments } } }
	end
	tool_calls = normalize_tool_calls(tool_calls)
	local tokens = 0
	local ctx = 0
	if usage then
		tokens = usage.completion_tokens or usage.output_tokens or 0
		ctx = usage.total_tokens or ((usage.input_tokens or 0) + tokens)
	end
	local rate = 0
	if start_ms and tokens > 0 and std.time_ms then
		local dt = (std.time_ms() - start_ms) / 1000
		if dt > 0 then
			rate = tokens / dt
		end
	end
	local out = {
		text = ft,
		backend = self.backend,
		model = model,
		tokens = tokens,
		ctx = ctx,
		rate = rate,
	}
	if tool_calls and #tool_calls > 0 then
		out.tool_calls = tool_calls
	end
	return out
end

-- Chat methods
local chat_complete = function(self, model, messages, sampler, opts)
	opts = opts or {}
	local tools_mod = require("llm.tools")
	local templates = require("llm.templates")

	-- If force_template is set, use template-based approach
	if opts.force_template then
		local tool_descs = {}
		if opts.tools then
			tool_descs = tools_mod.get_descriptions(opts.tools)
		elseif opts.tool_descriptions then
			tool_descs = opts.tool_descriptions
		end
		local prompt = templates.apply(opts.template, messages, tool_descs, opts.dont_start)
		return self:complete(model, { { role = "user", content = prompt } }, sampler, opts)
	end

	-- Use OAIC-native tool calling
	local tool_objects = {}
	if opts.tools then
		tool_objects = tools_mod.get_descriptions(opts.tools)
	elseif opts.tool_objects then
		tool_objects = opts.tool_objects
	end
	opts.tool_objects = tool_objects
	return self:complete(model, messages, sampler, opts)
end

local chat_stream = function(self, model, messages, sampler, opts)
	opts = opts or {}
	local tools_mod = require("llm.tools")
	local templates = require("llm.templates")

	-- If force_template is set, use template-based approach
	if opts.force_template then
		local tool_descs = {}
		if opts.tools then
			tool_descs = tools_mod.get_descriptions(opts.tools)
		elseif opts.tool_descriptions then
			tool_descs = opts.tool_descriptions
		end
		local prompt = templates.apply(opts.template, messages, tool_descs, opts.dont_start)
		local callbacks = opts.callbacks or {}
		return self:stream(model, { { role = "user", content = prompt } }, sampler, callbacks, opts)
	end

	-- Use OAIC-native tool calling
	local tool_objects = {}
	if opts.tools then
		tool_objects = tools_mod.get_descriptions(opts.tools)
	elseif opts.tool_objects then
		tool_objects = opts.tool_objects
	end
	opts.tool_objects = tool_objects
	local callbacks = opts.callbacks or {}
	return self:stream(model, messages, sampler, callbacks, opts)
end

local new = function(api_url, api_key)
	-- Check OAIC-specific env var first, then generic LLM_API_URL (with /v1 suffix)
	local base_url = os.getenv("LLM_API_URL")
	local api_url = api_url
		or os.getenv("LLM_OAIC_API_URL")
		or (base_url and (base_url:match("/v1$") and base_url or base_url .. "/v1"))
		or "http://127.0.0.1:8080/v1"
	local api_key = api_key or os.getenv("LLM_API_KEY") or "n/a"
	local timeout = tonumber(os.getenv("LLM_API_TIMEOUT")) or 600
	local headers = {
		["Authorization"] = "Bearer " .. api_key,
		["Content-Type"] = "application/json",
	}
	local client = {
		headers = headers,
		backend = "oaic",
		timeout = timeout,
		api_key = api_key,
		api_url = api_url,
		debug_mode = os.getenv("LLM_DEBUG_MODE"),
		complete = complete,
		stream = stream,
		chat_complete = chat_complete,
		chat_stream = chat_stream,
		models = models,
	}
	return client
end

return { new = new }
