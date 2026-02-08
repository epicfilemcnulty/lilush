-- SPDX-FileCopyrightText: © 2022—2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: LicenseRef-OWL-1.0-or-later OR GPL-3.0-or-later
-- Dual-licensed under OWL v1.0+ and GPLv3+. See LICENSE and LICENSE-GPL3.

-- API docs:
-- https://platform.openai.com/docs/api-reference/chat
-- https://platform.openai.com/docs/api-reference/responses

local json = require("cjson.safe")
local web = require("web")
local std = require("std")
local buffer = require("string.buffer")

local DEFAULT_ENDPOINT = "/chat/completions"

local cleanup_text = function(text)
	return tostring(text or "")
		:gsub("^\n+", "")
		:gsub("<|im_end|>%s*$", "")
		:gsub("<|eot_id|>%s*$", "")
		:gsub("</s>%s*$", "")
		:gsub("%s+$", "")
end

local stringify_content = function(content)
	if content == nil then
		return ""
	end
	if type(content) == "string" then
		return content
	end
	if type(content) == "table" then
		if #content > 0 then
			local parts = {}
			for _, part in ipairs(content) do
				if type(part) == "table" then
					local text = part.text or part.content
					if type(text) == "string" and #text > 0 then
						table.insert(parts, text)
					end
				elseif type(part) == "string" and #part > 0 then
					table.insert(parts, part)
				end
			end
			if #parts > 0 then
				return table.concat(parts)
			end
		end
		return json.encode(content) or ""
	end
	local s = tostring(content)
	if s:match("^userdata:") or s:match("^cdata:") then
		return ""
	end
	return s
end

local parse_usage = function(usage)
	usage = usage or {}
	local tokens = usage.completion_tokens
	if not tokens then
		tokens = usage.output_tokens or 0
	end
	local ctx = usage.total_tokens
	if not ctx then
		ctx = (usage.input_tokens or 0) + tokens
	end
	return tokens, ctx
end

local resolve_endpoint = function(opts)
	local endpoint = opts and opts.endpoint
	if not endpoint or endpoint == "" then
		return DEFAULT_ENDPOINT
	end
	if endpoint:sub(1, 1) ~= "/" then
		endpoint = "/" .. endpoint
	end
	return endpoint
end

local sanitize_chat_messages = function(messages)
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
			local id = c.id or c.call_id
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

local extract_chat_tool_calls = function(choice)
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

local extract_chat_text = function(choice)
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
			end
			local s = tostring(c)
			if s and not s:match("^userdata:") and not s:match("^cdata:") then
				if #s > 0 then
					return s
				end
			end
		end
		if type(c) == "table" then
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

local convert_tool_to_responses = function(tool)
	if type(tool) ~= "table" then
		return nil
	end
	if tool.type == "function" and type(tool["function"]) == "table" then
		local fn = tool["function"]
		return {
			type = "function",
			name = fn.name,
			description = fn.description,
			parameters = fn.parameters,
		}
	end
	if tool.type == "function" and tool.name then
		return {
			type = "function",
			name = tool.name,
			description = tool.description,
			parameters = tool.parameters,
		}
	end
	return tool
end

local convert_tools_to_responses = function(tools)
	local out = {}
	for _, tool in ipairs(tools or {}) do
		local converted = convert_tool_to_responses(tool)
		if converted then
			table.insert(out, converted)
		end
	end
	return out
end

local convert_tool_choice_to_responses = function(choice)
	if choice == nil then
		return nil
	end
	if type(choice) == "string" then
		return choice
	end
	if type(choice) ~= "table" then
		return choice
	end
	if choice.type == "function" and choice.name then
		return { type = "function", name = choice.name }
	end
	if choice.type == "function" and type(choice["function"]) == "table" then
		return { type = "function", name = choice["function"].name }
	end
	return choice
end

local build_function_call_output_item = function(msg)
	local call_id = msg.tool_call_id or msg.call_id or msg.id
	return {
		type = "function_call_output",
		call_id = call_id,
		output = stringify_content(msg.content),
	}
end

local detect_responses_followup = function(messages)
	local last = #messages
	if last < 2 then
		return nil, nil
	end

	local first_tool = last + 1
	for i = last, 1, -1 do
		if messages[i] and messages[i].role == "tool" then
			first_tool = i
		else
			break
		end
	end
	if first_tool == last + 1 then
		return nil, nil
	end

	local assistant_idx = first_tool - 1
	local assistant = messages[assistant_idx]
	if not assistant or assistant.role ~= "assistant" then
		return nil, nil
	end
	local response_id = assistant.response_id
	if type(response_id) ~= "string" or #response_id == 0 then
		return nil, nil
	end

	local input = {}
	for i = first_tool, last do
		local item = build_function_call_output_item(messages[i])
		if type(item.call_id) == "string" and #item.call_id > 0 then
			table.insert(input, item)
		end
	end
	if #input == 0 then
		return nil, nil
	end

	return response_id, input
end

local convert_messages_to_responses_input = function(messages)
	local input = {}
	for _, msg in ipairs(messages or {}) do
		local role = msg.role
		if role == "tool" then
			local item = build_function_call_output_item(msg)
			if type(item.call_id) == "string" and #item.call_id > 0 then
				table.insert(input, item)
			end
		elseif role == "user" or role == "assistant" or role == "system" then
			if msg.tool_responses and type(msg.tool_responses) == "table" then
				for _, tool_response in ipairs(msg.tool_responses) do
					table.insert(input, {
						type = "function_call_output",
						call_id = tool_response.id,
						output = json.encode(tool_response) or "",
					})
				end
			else
				table.insert(input, {
					role = role,
					content = stringify_content(msg.content),
				})
			end
			if role == "assistant" and type(msg.tool_calls) == "table" then
				local tool_calls = normalize_tool_calls(msg.tool_calls) or {}
				for _, call in ipairs(tool_calls) do
					table.insert(input, {
						type = "function_call",
						call_id = call.id,
						name = call.name,
						arguments = type(call.arguments) == "string" and call.arguments
							or (json.encode(call.arguments) or "{}"),
					})
				end
			end
		end
	end
	return input
end

local build_chat_data = function(model, messages, sampler, opts)
	local data = {
		model = model,
		max_tokens = sampler.max_new_tokens,
		messages = sanitize_chat_messages(messages),
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
	return data
end

local build_responses_data = function(model, messages, sampler, opts)
	local data = {
		model = model,
		max_output_tokens = sampler.max_new_tokens,
		temperature = sampler.temperature,
		top_p = sampler.top_p,
	}

	if opts.tool_objects and #opts.tool_objects > 0 then
		data.tools = convert_tools_to_responses(opts.tool_objects)
		if opts.tool_choice then
			data.tool_choice = convert_tool_choice_to_responses(opts.tool_choice)
		end
	end

	local previous_response_id, input = detect_responses_followup(messages or {})
	if previous_response_id and input then
		data.previous_response_id = previous_response_id
		data.input = input
	else
		data.input = convert_messages_to_responses_input(messages)
	end

	return data
end

local extract_responses_text_from_content = function(content)
	local parts = {}
	for _, part in ipairs(content or {}) do
		if type(part) == "table" then
			if part.type == "output_text" and type(part.text) == "string" then
				table.insert(parts, part.text)
			elseif type(part.text) == "string" then
				table.insert(parts, part.text)
			end
		elseif type(part) == "string" then
			table.insert(parts, part)
		end
	end
	return table.concat(parts)
end

local extract_responses_text = function(resp_json)
	local parts = {}
	for _, item in ipairs(resp_json.output or {}) do
		if type(item) == "table" then
			if item.type == "message" and type(item.content) == "table" then
				local text = extract_responses_text_from_content(item.content)
				if #text > 0 then
					table.insert(parts, text)
				end
			elseif item.type == "output_text" and type(item.text) == "string" then
				table.insert(parts, item.text)
			end
		end
	end
	if #parts == 0 and type(resp_json.output_text) == "string" then
		table.insert(parts, resp_json.output_text)
	elseif #parts == 0 and type(resp_json.output_text) == "table" then
		for _, text in ipairs(resp_json.output_text) do
			if type(text) == "string" then
				table.insert(parts, text)
			elseif type(text) == "table" and type(text.text) == "string" then
				table.insert(parts, text.text)
			end
		end
	end
	return table.concat(parts)
end

local extract_responses_tool_calls = function(resp_json)
	local calls = {}
	for _, item in ipairs(resp_json.output or {}) do
		if type(item) == "table" and item.type == "function_call" then
			table.insert(calls, {
				id = item.call_id or item.id,
				type = "function",
				name = item.name,
				arguments = item.arguments,
			})
		end
	end
	if #calls > 0 then
		return calls
	end
	return nil
end

local parse_chat_response = function(resp_json, duration, backend, debug_mode)
	local answer = {}
	local tokens, ctx = parse_usage(resp_json.usage)
	answer.tokens = tokens
	answer.ctx = ctx
	answer.model = resp_json.model
	answer.rate = duration > 0 and (tokens / duration) or 0
	if debug_mode then
		answer.raw = resp_json
	end
	if resp_json.choices then
		local c1 = resp_json.choices[1]
		local tc = extract_chat_tool_calls(c1)
		if tc then
			answer.tool_calls = tc
		end
		answer.text = extract_chat_text(c1)
	elseif resp_json.content then
		answer.text = resp_json.content[1].text
	end
	answer.text = cleanup_text(answer.text)
	answer.backend = backend
	return answer
end

local parse_responses_response = function(resp_json, duration, backend, debug_mode)
	local answer = {}
	local tokens, ctx = parse_usage(resp_json.usage)
	answer.tokens = tokens
	answer.ctx = ctx
	answer.model = resp_json.model
	answer.rate = duration > 0 and (tokens / duration) or 0
	answer.backend = backend
	answer.text = cleanup_text(extract_responses_text(resp_json))
	answer.response_id = resp_json.id
	answer.finish_reason = resp_json.status
	if debug_mode then
		answer.raw = resp_json
	end
	local calls = extract_responses_tool_calls(resp_json)
	if calls then
		answer.tool_calls = normalize_tool_calls(calls)
	end
	return answer
end

local request = function(url, data, headers, timeout, backend, debug_mode, response_kind)
	local start = os.time()
	local resp, err = web.request(url, { method = "POST", body = json.encode(data), headers = headers }, timeout)
	if resp then
		if resp.status == 200 then
			local duration = os.time() - start
			local resp_json, decode_err = json.decode(resp.body)
			if not resp_json then
				return nil, "failed to decode response: " .. tostring(decode_err)
			end
			if response_kind == "responses" then
				return parse_responses_response(resp_json, duration, backend, debug_mode)
			end
			return parse_chat_response(resp_json, duration, backend, debug_mode)
		end
		return nil, "bad response status: " .. resp.status .. "\n" .. (resp.body or "")
	end
	return nil, "request failed: " .. tostring(err)
end

local models = function(self)
	local resp, err =
		web.request(self.cfg.api_url .. "/models", { method = "GET", headers = self.__state.headers }, self.cfg.timeout)
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

local complete_chat = function(self, model, messages, sampler, opts)
	local data = build_chat_data(model, messages, sampler, opts)
	return request(
		self.cfg.api_url .. DEFAULT_ENDPOINT,
		data,
		self.__state.headers,
		self.cfg.timeout,
		self.cfg.backend,
		self.cfg.debug_mode,
		"chat"
	)
end

local complete_responses = function(self, model, messages, sampler, opts)
	local data = build_responses_data(model, messages, sampler, opts)
	return request(
		self.cfg.api_url .. "/responses",
		data,
		self.__state.headers,
		self.cfg.timeout,
		self.cfg.backend,
		self.cfg.debug_mode,
		"responses"
	)
end

local stream_chat = function(self, model, messages, sampler, user_callbacks, opts)
	local data = build_chat_data(model, messages, sampler, opts)
	data.stream = true
	data.stream_options = { include_usage = true }

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
						if self.cfg.debug_mode then
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
		self.cfg.api_url .. DEFAULT_ENDPOINT,
		{ method = "POST", body = json.encode(data), headers = self.__state.headers },
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

	if http_error then
		return nil, http_error
	end

	local ft = cleanup_text(full_text:get())
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
	local tokens, ctx = parse_usage(usage)
	local rate = 0
	if start_ms and tokens > 0 and std.time_ms then
		local dt = (std.time_ms() - start_ms) / 1000
		if dt > 0 then
			rate = tokens / dt
		end
	end
	local out = {
		text = ft,
		backend = self.cfg.backend,
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

local merge_response_tool_calls = function(tool_by_key, tool_order, calls)
	for _, call in ipairs(calls or {}) do
		if type(call) == "table" and call.name then
			local key = call.id or ("call_" .. tostring(#tool_order + 1))
			if not tool_by_key[key] then
				tool_by_key[key] = {
					id = call.id,
					name = call.name,
					arguments = "",
				}
				table.insert(tool_order, key)
			end
			local st = tool_by_key[key]
			st.id = call.id or st.id
			st.name = call.name or st.name
			if call.arguments ~= nil then
				st.arguments = type(call.arguments) == "string" and call.arguments
					or (json.encode(call.arguments) or "{}")
			end
		end
	end
end

local parse_sse_event = function(chunk)
	if type(chunk) ~= "table" then
		return nil, nil
	end
	if type(chunk.type) == "string" then
		return chunk.type, chunk
	end
	if type(chunk.event) == "string" and type(chunk.data) == "table" then
		return chunk.event, chunk.data
	end
	if type(chunk.data) == "table" and type(chunk.data.type) == "string" then
		return chunk.data.type, chunk.data
	end
	return nil, nil
end

local tool_state_key = function(payload)
	return payload.item_id or payload.call_id or payload.id or payload.output_item_id or payload.item_index
end

local ensure_tool_state = function(tool_by_key, tool_order, payload)
	local key = tool_state_key(payload)
	if not key then
		key = "tool_" .. tostring(#tool_order + 1)
	end
	if not tool_by_key[key] then
		tool_by_key[key] = {
			id = payload.call_id or payload.id,
			name = payload.name,
			arguments = "",
		}
		table.insert(tool_order, key)
	end
	local st = tool_by_key[key]
	st.id = payload.call_id or payload.id or st.id
	st.name = payload.name or st.name
	return st
end

local stream_responses = function(self, model, messages, sampler, user_callbacks, opts)
	local data = build_responses_data(model, messages, sampler, opts)
	data.stream = true

	local full_text = buffer.new()
	local usage = nil
	local tool_by_key = {}
	local tool_order = {}
	local response_id = nil
	local response_model = nil
	local finish_reason = nil
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

			local event_type, payload = parse_sse_event(chunk)
			if not event_type then
				return
			end

			if event_type == "response.output_text.delta" then
				local delta = payload.delta or payload.text
				if type(delta) == "string" and #delta > 0 then
					full_text:put(delta)
					if user_callbacks.chunk then
						local chunk_data = { text = delta }
						if self.cfg.debug_mode then
							chunk_data.raw = payload
						end
						user_callbacks.chunk(chunk_data)
					end
				end
			elseif event_type == "response.output_item.added" or event_type == "response.output_item.done" then
				local item = payload.item or payload.output_item
				if type(item) == "table" then
					if item.type == "function_call" then
						local call = {
							id = item.call_id or item.id,
							name = item.name,
							arguments = item.arguments,
						}
						merge_response_tool_calls(tool_by_key, tool_order, { call })
					elseif item.type == "message" and full_text:get() == "" then
						local text = extract_responses_text_from_content(item.content)
						if #text > 0 then
							full_text:put(text)
						end
					end
				end
			elseif event_type == "response.function_call_arguments.delta" then
				local st = ensure_tool_state(tool_by_key, tool_order, payload)
				if type(payload.delta) == "string" then
					st.arguments = (st.arguments or "") .. payload.delta
				end
			elseif event_type == "response.function_call_arguments.done" then
				local st = ensure_tool_state(tool_by_key, tool_order, payload)
				if type(payload.arguments) == "string" then
					st.arguments = payload.arguments
				end
			elseif event_type == "response.completed" then
				local response = payload.response or payload
				if type(response) == "table" then
					response_id = response.id or response_id
					response_model = response.model or response_model
					finish_reason = response.status or finish_reason
					usage = response.usage or usage
					local final_calls = normalize_tool_calls(extract_responses_tool_calls(response) or {})
					merge_response_tool_calls(tool_by_key, tool_order, final_calls)
					local text = extract_responses_text(response)
					if #text > 0 and full_text:get() == "" then
						full_text:put(text)
					end
				end
				client:close()
			elseif event_type == "response.failed" then
				local err_obj = payload.error
				local msg = "response failed"
				if type(err_obj) == "table" then
					msg = err_obj.message or (json.encode(err_obj) or msg)
				elseif type(err_obj) == "string" then
					msg = err_obj
				end
				http_error = msg
				if user_callbacks.error then
					user_callbacks.error(msg)
				end
				client:close()
			elseif event_type == "error" then
				local err_obj = payload.error
				local msg = type(err_obj) == "string" and err_obj
					or (type(err_obj) == "table" and err_obj.message)
					or "stream error"
				http_error = msg
				if user_callbacks.error then
					user_callbacks.error(msg)
				end
				client:close()
			end
		end,
		close = function()
			if user_callbacks.done then
				user_callbacks.done()
			end
		end,
	}

	client = web.sse_client(
		self.cfg.api_url .. "/responses",
		{ method = "POST", body = json.encode(data), headers = self.__state.headers },
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

	if http_error then
		return nil, http_error
	end

	local tool_calls = {}
	for _, key in ipairs(tool_order) do
		local st = tool_by_key[key]
		if st and st.name then
			table.insert(tool_calls, {
				id = st.id,
				type = "function",
				name = st.name,
				arguments = st.arguments,
			})
		end
	end
	tool_calls = normalize_tool_calls(tool_calls)

	local tokens, ctx = parse_usage(usage)
	local rate = 0
	if start_ms and tokens > 0 and std.time_ms then
		local dt = (std.time_ms() - start_ms) / 1000
		if dt > 0 then
			rate = tokens / dt
		end
	end
	local out = {
		text = cleanup_text(full_text:get()),
		backend = self.cfg.backend,
		model = response_model or model,
		tokens = tokens,
		ctx = ctx,
		rate = rate,
		response_id = response_id,
		finish_reason = finish_reason,
	}
	if tool_calls and #tool_calls > 0 then
		out.tool_calls = tool_calls
	end
	return out
end

local complete = function(self, model, messages, sampler, opts)
	opts = opts or {}
	local endpoint = resolve_endpoint(opts)
	if endpoint == "/responses" then
		return complete_responses(self, model, messages, sampler, opts)
	end
	return complete_chat(self, model, messages, sampler, opts)
end

local stream = function(self, model, messages, sampler, user_callbacks, opts)
	opts = opts or {}
	user_callbacks = user_callbacks or {}
	local endpoint = resolve_endpoint(opts)
	if endpoint == "/responses" then
		return stream_responses(self, model, messages, sampler, user_callbacks, opts)
	end
	return stream_chat(self, model, messages, sampler, user_callbacks, opts)
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
		return self.complete(self, model, { { role = "user", content = prompt } }, sampler, opts)
	end

	local tool_objects = {}
	if opts.tools then
		tool_objects = tools_mod.get_descriptions(opts.tools)
	elseif opts.tool_objects then
		tool_objects = opts.tool_objects
	end
	opts.tool_objects = tool_objects
	return self.complete(self, model, messages, sampler, opts)
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
		return self.stream(self, model, { { role = "user", content = prompt } }, sampler, callbacks, opts)
	end

	local tool_objects = {}
	if opts.tools then
		tool_objects = tools_mod.get_descriptions(opts.tools)
	elseif opts.tool_objects then
		tool_objects = opts.tool_objects
	end
	opts.tool_objects = tool_objects
	local callbacks = opts.callbacks or {}
	return self.stream(self, model, messages, sampler, callbacks, opts)
end

local new = function(api_url, api_key)
	-- Check OAIC-specific env var first, then generic LLM_API_URL (with /v1 suffix)
	local base_url = os.getenv("LLM_API_URL")
	local resolved_api_url = api_url
		or os.getenv("LLM_OAIC_API_URL")
		or (base_url and (base_url:match("/v1$") and base_url or base_url .. "/v1"))
		or "http://127.0.0.1:8080/v1"
	local resolved_api_key = api_key or os.getenv("LLM_API_KEY") or "n/a"
	local timeout = tonumber(os.getenv("LLM_API_TIMEOUT")) or 600

	local instance = {
		cfg = {
			backend = "oaic",
			timeout = timeout,
			api_key = resolved_api_key,
			api_url = resolved_api_url,
			debug_mode = os.getenv("LLM_DEBUG_MODE"),
		},
		__state = {
			headers = {
				["Authorization"] = "Bearer " .. resolved_api_key,
				["Content-Type"] = "application/json",
			},
		},
		complete = complete,
		stream = stream,
		chat_complete = chat_complete,
		chat_stream = chat_stream,
		models = models,
	}

	return instance
end

return { new = new }
