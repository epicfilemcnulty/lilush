-- SPDX-FileCopyrightText: © 2022—2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: LicenseRef-OWL-1.0-or-later OR GPL-3.0-or-later
-- Dual-licensed under OWL v1.0+ and GPLv3+. See LICENSE and LICENSE-GPL3.

-- Anthropic Messages API client
-- API docs: https://docs.anthropic.com/en/api/messages

local json = require("cjson.safe")
local web = require("web")
local std = require("std")
local buffer = require("string.buffer")

-- Sanitize messages for Anthropic format
-- Returns: system (string or nil), messages (array)
local sanitize_messages = function(messages)
	local system_parts = {}
	local anthropic_msgs = {}
	local pending_tool_results = {}

	for _, msg in ipairs(messages or {}) do
		local role = msg.role

		if role == "system" then
			if msg.content then
				table.insert(system_parts, msg.content)
			end
		elseif role == "tool" then
			table.insert(pending_tool_results, {
				type = "tool_result",
				tool_use_id = msg.tool_call_id,
				content = msg.content,
			})
		elseif role == "assistant" then
			local content = {}

			if msg.content and type(msg.content) == "string" and #msg.content > 0 then
				table.insert(content, { type = "text", text = msg.content })
			elseif msg.content and type(msg.content) == "table" then
				-- Content is already in block format
				for _, block in ipairs(msg.content) do
					table.insert(content, block)
				end
			end

			if msg.tool_calls then
				for _, tc in ipairs(msg.tool_calls) do
					local input = tc.arguments
					if type(input) == "string" then
						input = json.decode(input) or {}
					end
					-- Handle OpenAI-style tool_calls with function wrapper
					local name = tc.name
					if not name and tc["function"] then
						name = tc["function"].name
						if tc["function"].arguments then
							input = tc["function"].arguments
							if type(input) == "string" then
								input = json.decode(input) or {}
							end
						end
					end
					table.insert(content, {
						type = "tool_use",
						id = tc.id,
						name = name,
						input = input or {},
					})
				end
			end

			-- Use string content if no blocks
			if #content == 0 and msg.content then
				content = msg.content
			elseif #content == 1 and content[1].type == "text" then
				content = content[1].text
			end

			table.insert(anthropic_msgs, { role = "assistant", content = content })
		elseif role == "user" then
			if #pending_tool_results > 0 then
				-- Add tool results as a user message
				table.insert(anthropic_msgs, { role = "user", content = pending_tool_results })
				pending_tool_results = {}
			end

			-- Add user message
			local content = msg.content
			if msg.tool_responses then
				-- XML-style tool responses - convert to content blocks
				content = {}
				for _, tr in ipairs(msg.tool_responses) do
					table.insert(content, {
						type = "tool_result",
						tool_use_id = tr.id or ("tool_" .. (tr.name or "unknown")),
						content = json.encode(tr),
					})
				end
			end
			table.insert(anthropic_msgs, { role = "user", content = content })
		end
	end

	if #pending_tool_results > 0 then
		table.insert(anthropic_msgs, { role = "user", content = pending_tool_results })
	end

	-- Ensure alternating user/assistant messages
	local merged = {}
	for _, msg in ipairs(anthropic_msgs) do
		local prev = merged[#merged]
		if prev and prev.role == msg.role then
			-- Combine consecutive same-role messages
			local prev_content = prev.content
			local curr_content = msg.content

			-- Convert to arrays if needed
			if type(prev_content) == "string" then
				prev_content = { { type = "text", text = prev_content } }
			end
			if type(curr_content) == "string" then
				curr_content = { { type = "text", text = curr_content } }
			end

			-- Merge content arrays
			for _, block in ipairs(curr_content) do
				table.insert(prev_content, block)
			end
			prev.content = prev_content
		else
			table.insert(merged, msg)
		end
	end

	local system = nil
	if #system_parts > 0 then
		system = table.concat(system_parts, "\n\n")
	end

	return system, merged
end

-- Convert OpenAI-style tool to Anthropic format
local convert_tool_to_anthropic = function(tool)
	if tool.type == "function" and tool["function"] then
		local fn = tool["function"]
		return {
			name = fn.name,
			description = fn.description,
			input_schema = fn.parameters,
		}
	end
	-- Already in Anthropic format or unknown
	return tool
end

-- Convert array of tools
local convert_tools_to_anthropic = function(tools)
	local result = {}
	for _, tool in ipairs(tools or {}) do
		table.insert(result, convert_tool_to_anthropic(tool))
	end
	return result
end

-- Extract tool calls from Anthropic response content blocks
-- Returns normalized format matching oaic.lua
local extract_tool_calls = function(content_blocks)
	local calls = {}
	for _, block in ipairs(content_blocks or {}) do
		if block.type == "tool_use" then
			local args = block.input
			if type(args) == "table" then
				args = json.encode(args) or "{}"
			end
			table.insert(calls, {
				id = block.id,
				type = "function",
				name = block.name,
				arguments = args,
			})
		end
	end
	if #calls > 0 then
		return calls
	end
	return nil
end

-- Extract text from Anthropic response content blocks
local extract_text = function(content_blocks)
	local parts = {}
	for _, block in ipairs(content_blocks or {}) do
		if block.type == "text" and block.text then
			table.insert(parts, block.text)
		end
	end
	return table.concat(parts)
end

-- Non-streaming completion
local complete = function(self, model, messages, sampler, opts)
	opts = opts or {}
	local start = os.time()

	-- Sanitize messages and extract system
	local system, anthropic_messages = sanitize_messages(messages)

	-- Build request body
	local data = {
		model = model,
		max_tokens = sampler.max_new_tokens or 4096,
		messages = anthropic_messages,
		temperature = sampler.temperature,
		top_p = sampler.top_p,
		top_k = sampler.top_k,
	}

	if system and #system > 0 then
		data.system = system
	end

	if opts.tool_objects and #opts.tool_objects > 0 then
		data.tools = convert_tools_to_anthropic(opts.tool_objects)
		if opts.tool_choice then
			-- Convert tool_choice if needed
			local tc = opts.tool_choice
			if type(tc) == "string" then
				if tc == "none" then
					data.tool_choice = { type = "none" }
				elseif tc == "auto" then
					data.tool_choice = { type = "auto" }
				elseif tc == "required" then
					data.tool_choice = { type = "any" }
				else
					data.tool_choice = { type = "tool", name = tc }
				end
			elseif type(tc) == "table" then
				data.tool_choice = tc
			end
		end
	end

	if opts.stop_sequences then
		data.stop_sequences = opts.stop_sequences
	end

	local resp, err = web.request(
		self.cfg.api_url .. "/messages",
		{ method = "POST", body = json.encode(data), headers = self.__state.headers },
		self.cfg.timeout
	)

	if not resp then
		return nil, "request failed: " .. tostring(err)
	end

	if resp.status ~= 200 then
		return nil, "bad response status: " .. resp.status .. "\n" .. (resp.body or "")
	end

	local response, decode_err = json.decode(resp.body)
	if not response then
		return nil, "failed to decode response: " .. tostring(decode_err)
	end

	local duration = os.time() - start

	local tokens = response.usage and response.usage.output_tokens or 0
	local input_tokens = response.usage and response.usage.input_tokens or 0

	local answer = {
		text = extract_text(response.content),
		model = response.model or model,
		backend = "anthropic",
		tokens = tokens,
		ctx = input_tokens + tokens,
		rate = duration > 0 and (tokens / duration) or 0,
		stop_reason = response.stop_reason,
	}

	if self.cfg.debug_mode then
		answer.raw = response
	end

	local tool_calls = extract_tool_calls(response.content)
	if tool_calls then
		answer.tool_calls = tool_calls
	end

	return answer
end

local stream = function(self, model, messages, sampler, user_callbacks, opts)
	opts = opts or {}
	user_callbacks = user_callbacks or {}

	local system, anthropic_messages = sanitize_messages(messages)

	local data = {
		model = model,
		max_tokens = sampler.max_new_tokens or 4096,
		messages = anthropic_messages,
		temperature = sampler.temperature,
		top_p = sampler.top_p,
		top_k = sampler.top_k,
		stream = true,
	}

	if system and #system > 0 then
		data.system = system
	end

	if opts.tool_objects and #opts.tool_objects > 0 then
		data.tools = convert_tools_to_anthropic(opts.tool_objects)
		if opts.tool_choice then
			local tc = opts.tool_choice
			if type(tc) == "string" then
				if tc == "none" then
					data.tool_choice = { type = "none" }
				elseif tc == "auto" then
					data.tool_choice = { type = "auto" }
				elseif tc == "required" then
					data.tool_choice = { type = "any" }
				else
					data.tool_choice = { type = "tool", name = tc }
				end
			elseif type(tc) == "table" then
				data.tool_choice = tc
			end
		end
	end

	if opts.stop_sequences then
		data.stop_sequences = opts.stop_sequences
	end

	-- State for accumulating streamed content
	local full_text = buffer.new()
	local content_blocks = {}
	local current_block = nil
	local usage = nil
	local stop_reason = nil
	local message_model = nil
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
		message = function(event)
			-- SSE client passes {event=..., data=...} to message callback
			if type(event) ~= "table" or type(event.data) ~= "table" then
				return
			end

			local event_data = event.data
			local event_type = event_data.type

			if event_type == "message_start" then
				-- Extract model from initial message
				if event_data.message then
					message_model = event_data.message.model
					if event_data.message.usage then
						usage = event_data.message.usage
					end
				end
			elseif event_type == "content_block_start" then
				-- Start a new content block
				current_block = {
					index = event_data.index,
					type = event_data.content_block and event_data.content_block.type,
					id = event_data.content_block and event_data.content_block.id,
					name = event_data.content_block and event_data.content_block.name,
					text = "",
					input_json = "",
				}
			elseif event_type == "content_block_delta" then
				if current_block and event_data.delta then
					local delta = event_data.delta
					if delta.type == "text_delta" and delta.text then
						current_block.text = current_block.text .. delta.text
						full_text:put(delta.text)
						if user_callbacks.chunk then
							local chunk_data = { text = delta.text }
							if self.cfg.debug_mode then
								chunk_data.raw = event_data
							end
							user_callbacks.chunk(chunk_data)
						end
					elseif delta.type == "input_json_delta" and delta.partial_json then
						current_block.input_json = current_block.input_json .. delta.partial_json
					end
				end
			elseif event_type == "content_block_stop" then
				if current_block then
					-- Finalize and store the content block
					local block = { type = current_block.type }
					if current_block.type == "text" then
						block.text = current_block.text
					elseif current_block.type == "tool_use" then
						block.id = current_block.id
						block.name = current_block.name
						block.input = json.decode(current_block.input_json) or {}
					end
					content_blocks[current_block.index + 1] = block
					current_block = nil
				end
			elseif event_type == "message_delta" then
				if event_data.delta then
					stop_reason = event_data.delta.stop_reason
				end
				if event_data.usage then
					usage = usage or {}
					usage.output_tokens = event_data.usage.output_tokens
				end
			elseif event_type == "message_stop" then
				client:close()
			elseif event_type == "error" then
				if user_callbacks.error then
					user_callbacks.error(event_data.error)
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
		self.cfg.api_url .. "/messages",
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

	-- Check for HTTP errors (non-2xx status codes)
	if http_error then
		return nil, http_error
	end

	-- Build final response
	local tool_calls = extract_tool_calls(content_blocks)
	local tokens = usage and usage.output_tokens or 0
	local input_tokens = usage and usage.input_tokens or 0

	local rate = 0
	if start_ms and tokens > 0 and std.time_ms then
		local dt = (std.time_ms() - start_ms) / 1000
		if dt > 0 then
			rate = tokens / dt
		end
	end

	local out = {
		text = full_text:get(),
		backend = "anthropic",
		model = message_model or model,
		tokens = tokens,
		ctx = input_tokens + tokens,
		rate = rate,
		stop_reason = stop_reason,
	}

	if tool_calls and #tool_calls > 0 then
		out.tool_calls = tool_calls
	end

	return out
end

-- Chat completion wrapper
local chat_complete = function(self, model, messages, sampler, opts)
	opts = opts or {}
	local tools_mod = require("llm.tools")

	-- Get tool objects if tools are specified by name
	local tool_objects = {}
	if opts.tools then
		tool_objects = tools_mod.get_descriptions(opts.tools)
	elseif opts.tool_objects then
		tool_objects = opts.tool_objects
	end

	opts.tool_objects = tool_objects
	return self.complete(self, model, messages, sampler, opts)
end

-- Chat streaming wrapper
local chat_stream = function(self, model, messages, sampler, opts)
	opts = opts or {}
	local tools_mod = require("llm.tools")

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
	local resolved_api_url = api_url or os.getenv("ANTHROPIC_API_URL") or "https://api.anthropic.com/v1"
	local resolved_api_key = api_key or os.getenv("ANTHROPIC_API_KEY") or os.getenv("LLM_API_KEY")
	local timeout = tonumber(os.getenv("LLM_API_TIMEOUT")) or 600

	local instance = {
		cfg = {
			backend = "anthropic",
			timeout = timeout,
			api_key = resolved_api_key,
			api_url = resolved_api_url,
			debug_mode = os.getenv("LLM_DEBUG_MODE"),
		},
		__state = {
			headers = {
				["x-api-key"] = resolved_api_key,
				["anthropic-version"] = "2023-06-01",
				["Content-Type"] = "application/json",
			},
		},
		complete = complete,
		stream = stream,
		chat_complete = chat_complete,
		chat_stream = chat_stream,
	}

	return instance
end

return { new = new }
