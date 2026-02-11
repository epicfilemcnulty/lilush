-- SPDX-FileCopyrightText: © 2022—2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: LicenseRef-OWL-1.0-or-later OR GPL-3.0-or-later
-- Dual-licensed under OWL v1.0+ and GPLv3+. See LICENSE and LICENSE-GPL3.

--[[
Conversation management for the agent.

Handles:
- Message history (system, user, assistant, tool messages)
- Cost tracking (using real token counts from API responses)
- Save/load conversations to/from files
]]

local std = require("std")
local json = require("cjson.safe")

local new_cost = function()
	return {
		input_tokens = 0,
		output_tokens = 0,
		cached_tokens = 0,
		total_cost = 0,
		request_count = 0,
		last_ctx_tokens = 0,
		last_ctx_pct = 0,
		peak_ctx_tokens = 0,
		peak_ctx_pct = 0,
		context_window = 0,
	}
end

local format_cost = function(cost)
	if not cost or cost < 0 then
		return "$0.00"
	end

	if cost < 0.01 then
		if cost < 0.001 then
			return string.format("$%.4f", cost)
		end
		return string.format("$%.3f", cost)
	end

	return string.format("$%.2f", cost)
end

-- Get the system prompt
local get_system_prompt = function(self)
	return self.__state.system_prompt
end

-- Set/update the system prompt
local set_system_prompt = function(self, prompt)
	self.__state.system_prompt = prompt
end

-- Add a user message
local add_user = function(self, content)
	local state = self.__state
	local msg = { role = "user", content = content }
	table.insert(state.messages, msg)
	state.metadata.updated_at = os.time()
	return msg
end

-- Add an assistant message
local add_assistant = function(self, content, tool_calls)
	local state = self.__state
	local msg = { role = "assistant", content = content }
	if tool_calls and #tool_calls > 0 then
		msg.tool_calls = tool_calls
	end
	table.insert(state.messages, msg)
	state.metadata.updated_at = os.time()
	return msg
end

-- Add a tool result message (OpenAI style)
local add_tool_result = function(self, tool_call_id, content)
	local state = self.__state
	local msg = { role = "tool", tool_call_id = tool_call_id, content = content }
	table.insert(state.messages, msg)
	state.metadata.updated_at = os.time()
	return msg
end

-- Get all messages (for sending to LLM)
-- Returns messages with system prompt prepended
local get_messages = function(self)
	local state = self.__state
	local messages = {}
	if state.system_prompt then
		table.insert(messages, { role = "system", content = state.system_prompt })
	end
	for _, msg in ipairs(state.messages) do
		table.insert(messages, msg)
	end
	return messages
end

-- Get messages for API with old tool results truncated.
-- Keeps the last `keep_recent` user turns fully intact.
-- For older turns, tool message content is replaced with a compact stub
-- preserving only name, ok status, and error (if any).
local get_messages_for_api = function(self, opts)
	opts = opts or {}
	local keep_recent = opts.keep_recent or 4
	local state = self.__state
	local msgs = state.messages

	-- Find user-message indices (turn boundaries)
	local user_indices = {}
	for i, msg in ipairs(msgs) do
		if msg.role == "user" then
			user_indices[#user_indices + 1] = i
		end
	end

	-- Determine the cutoff: messages before this index get truncated tool results
	local cutoff = 0
	if #user_indices > keep_recent then
		cutoff = user_indices[#user_indices - keep_recent + 1]
	end

	local messages = {}
	if state.system_prompt then
		messages[#messages + 1] = { role = "system", content = state.system_prompt }
	end

	for i, msg in ipairs(msgs) do
		if msg.role == "tool" and i < cutoff then
			-- Truncate old tool results
			local content = msg.content
			local decoded = type(content) == "string" and json.decode(content) or nil
			local stub
			if type(decoded) == "table" then
				local ok_val = decoded.ok
				if ok_val == nil then
					-- Infer ok from absence of error field
					ok_val = decoded.error == nil
				end
				stub = { name = decoded.name, ok = ok_val, truncated = true }
				if not ok_val and decoded.error then
					stub.error = decoded.error
				end
			else
				stub = { ok = true, truncated = true }
			end
			messages[#messages + 1] = {
				role = "tool",
				tool_call_id = msg.tool_call_id,
				content = json.encode(stub),
			}
		else
			messages[#messages + 1] = msg
		end
	end

	return messages
end

-- Get raw messages (without system prompt)
local get_raw_messages = function(self)
	return self.__state.messages
end

-- Get the last message
local last = function(self)
	local state = self.__state
	return state.messages[#state.messages]
end

-- Get message count (excluding system)
local count = function(self)
	return #self.__state.messages
end

-- Get real token count from API responses (input + output)
-- Returns 0 until first API response is received
local tokens = function(self)
	local cost = self.__state.cost
	return cost.input_tokens + cost.output_tokens
end

-- Trim the oldest user turn (user message + all messages up to the next user message).
-- Returns true if a turn was removed, false if nothing to trim.
local trim_oldest_turn = function(self)
	local state = self.__state
	local msgs = state.messages
	-- Find the first user message
	local first_user = nil
	for i, msg in ipairs(msgs) do
		if msg.role == "user" then
			first_user = i
			break
		end
	end
	if not first_user then
		return false
	end
	-- Find the next user message after the first
	local next_user = nil
	for i = first_user + 1, #msgs do
		if msgs[i].role == "user" then
			next_user = i
			break
		end
	end
	-- Remove from first_user up to (but not including) next_user
	local remove_count
	if next_user then
		remove_count = next_user - first_user
	else
		-- Only one turn left, remove all of it
		remove_count = #msgs - first_user + 1
	end
	for _ = 1, remove_count do
		table.remove(msgs, first_user)
	end
	state.metadata.updated_at = os.time()
	return true
end

-- Clear all messages (keeps system prompt)
-- Also resets cost tracking for new session
local clear = function(self)
	local state = self.__state
	state.messages = {}
	state.metadata.updated_at = os.time()
	state.cost = new_cost()
end

-- Set conversation name (for save/load)
local set_name = function(self, name)
	self.__state.metadata.name = name
end

-- Get conversation name
local get_name = function(self)
	return self.__state.metadata.name
end

-- Save conversation to file
local save = function(self, name)
	local state = self.__state
	name = name or state.metadata.name
	if not name then
		return nil, "conversation name required"
	end

	local home = os.getenv("HOME") or "/tmp"
	local save_dir = home .. "/.local/share/lilush/agent/conversations"
	std.fs.mkdirp(save_dir)

	local filename = name:gsub("[^%w_-]", "_") .. ".json"
	local filepath = save_dir .. "/" .. filename

	local data = {
		name = name,
		system_prompt = state.system_prompt,
		messages = state.messages,
		metadata = state.metadata,
	}

	local content = json.encode(data)
	if not content then
		return nil, "failed to encode conversation"
	end

	local ok, err = std.fs.write_file(filepath, content)
	if not ok then
		return nil, err
	end

	state.metadata.name = name
	return filepath
end

-- Load conversation from file
local load = function(self, name)
	local state = self.__state
	local home = os.getenv("HOME") or "/tmp"
	local save_dir = home .. "/.local/share/lilush/agent/conversations"

	local filename = name:gsub("[^%w_-]", "_") .. ".json"
	local filepath = save_dir .. "/" .. filename

	local content = std.fs.read_file(filepath)
	if not content then
		return nil, "conversation not found: " .. name
	end

	local data, err = json.decode(content)
	if not data then
		return nil, "failed to parse conversation: " .. tostring(err)
	end

	state.system_prompt = data.system_prompt
	state.messages = data.messages or {}
	state.metadata = data.metadata or { created_at = os.time(), updated_at = os.time() }
	state.metadata.name = name

	return true
end

-- Add usage to a cost table and calculate cost.
-- Standalone function that operates on any cost table (from new_cost()).
local add_cost_usage = function(
	cost,
	input_tokens,
	output_tokens,
	cached_tokens,
	ctx_tokens,
	context_window,
	prompt_price,
	completion_price,
	cached_price
)
	input_tokens = input_tokens or 0
	output_tokens = output_tokens or 0
	cached_tokens = cached_tokens or 0
	ctx_tokens = ctx_tokens or 0
	context_window = context_window or cost.context_window or 0
	prompt_price = tonumber(prompt_price)
	completion_price = tonumber(completion_price)
	cached_price = tonumber(cached_price)

	cost.input_tokens = cost.input_tokens + input_tokens
	cost.output_tokens = cost.output_tokens + output_tokens
	cost.cached_tokens = cost.cached_tokens + cached_tokens
	cost.request_count = cost.request_count + 1
	cost.last_ctx_tokens = ctx_tokens
	cost.context_window = context_window

	if context_window > 0 then
		cost.last_ctx_pct = math.floor((ctx_tokens / context_window) * 100)
	else
		cost.last_ctx_pct = 0
	end
	if cost.last_ctx_tokens > cost.peak_ctx_tokens then
		cost.peak_ctx_tokens = cost.last_ctx_tokens
	end
	if cost.last_ctx_pct > cost.peak_ctx_pct then
		cost.peak_ctx_pct = cost.last_ctx_pct
	end

	local request_cost = nil
	local has_price = prompt_price ~= nil or completion_price ~= nil or cached_price ~= nil
	if has_price then
		request_cost = 0
		request_cost = request_cost + (input_tokens * (prompt_price or 0))
		request_cost = request_cost + (output_tokens * (completion_price or 0))
		request_cost = request_cost + (cached_tokens * (cached_price or 0))
		cost.total_cost = cost.total_cost + request_cost
	end

	return request_cost
end

local add_usage = function(self, ...)
	return add_cost_usage(self.__state.cost, ...)
end

-- Get current cost tracking data
local get_cost = function(self)
	local cost = self.__state.cost
	return {
		input_tokens = cost.input_tokens,
		output_tokens = cost.output_tokens,
		cached_tokens = cost.cached_tokens,
		total_cost = cost.total_cost,
		request_count = cost.request_count,
		last_ctx_tokens = cost.last_ctx_tokens,
		last_ctx_pct = cost.last_ctx_pct,
		peak_ctx_tokens = cost.peak_ctx_tokens,
		peak_ctx_pct = cost.peak_ctx_pct,
		context_window = cost.context_window,
	}
end

-- Get context usage stats (last/peak usage and model context window)
local get_context_usage = function(self)
	local cost = self.__state.cost
	return {
		last_ctx_tokens = cost.last_ctx_tokens,
		last_ctx_pct = cost.last_ctx_pct,
		peak_ctx_tokens = cost.peak_ctx_tokens,
		peak_ctx_pct = cost.peak_ctx_pct,
		context_window = cost.context_window,
	}
end

-- Get just the total cost (convenience method)
local get_total_cost = function(self)
	return self.__state.cost.total_cost
end

-- List saved conversations
local list_saved = function()
	local home = os.getenv("HOME") or "/tmp"
	local save_dir = home .. "/.local/share/lilush/agent/conversations"

	local files = std.fs.list_files(save_dir, "json")
	if not files then
		return {}
	end

	local conversations = {}
	for filename, _ in pairs(files) do
		local name = filename:match("^(.+)%.json$")
		if name then
			local filepath = save_dir .. "/" .. filename
			local content = std.fs.read_file(filepath)
			if content then
				local data = json.decode(content)
				if data then
					table.insert(conversations, {
						name = data.name or name,
						created_at = data.metadata and data.metadata.created_at,
						updated_at = data.metadata and data.metadata.updated_at,
						message_count = data.messages and #data.messages or 0,
					})
				end
			end
		end
	end

	-- Sort by updated_at descending
	table.sort(conversations, function(a, b)
		return (a.updated_at or 0) > (b.updated_at or 0)
	end)

	return conversations
end

-- Delete a saved conversation
local delete_saved = function(name)
	local home = os.getenv("HOME") or "/tmp"
	local save_dir = home .. "/.local/share/lilush/agent/conversations"

	local filename = name:gsub("[^%w_-]", "_") .. ".json"
	local filepath = save_dir .. "/" .. filename

	return os.remove(filepath)
end

-- Create a new conversation object
local new = function(system_prompt)
	local instance = {
		cfg = {},
		__state = {
			messages = {},
			system_prompt = system_prompt,
			metadata = {
				created_at = os.time(),
				updated_at = os.time(),
				name = nil,
			},
			-- Cost tracking for the session (uses real token counts from API responses)
			cost = new_cost(),
		},
		-- Methods
		get_system_prompt = get_system_prompt,
		set_system_prompt = set_system_prompt,
		add_user = add_user,
		add_assistant = add_assistant,
		add_tool_result = add_tool_result,
		get_messages = get_messages,
		get_messages_for_api = get_messages_for_api,
		get_raw_messages = get_raw_messages,
		last = last,
		count = count,
		tokens = tokens,
		trim_oldest_turn = trim_oldest_turn,
		clear = clear,
		set_name = set_name,
		get_name = get_name,
		save = save,
		load = load,
		add_usage = add_usage,
		format_cost = format_cost,
		get_cost = get_cost,
		get_total_cost = get_total_cost,
		get_context_usage = get_context_usage,
	}

	return instance
end

return {
	new = new,
	new_cost = new_cost,
	add_cost_usage = add_cost_usage,
	list = list_saved,
	delete = delete_saved,
	format_cost = format_cost,
}
