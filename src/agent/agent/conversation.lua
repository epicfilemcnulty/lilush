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
	}
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

-- Add a raw message (for flexibility)
local add_message = function(self, msg)
	local state = self.__state
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

-- Add usage from an LLM response and calculate cost
-- model: model name for pricing lookup
-- input_tokens: number of input tokens
-- output_tokens: number of output tokens
-- cached_tokens: number of cached tokens (optional)
local add_usage = function(self, model, input_tokens, output_tokens, cached_tokens)
	local pricing = require("llm.pricing")
	local cost = self.__state.cost

	input_tokens = input_tokens or 0
	output_tokens = output_tokens or 0
	cached_tokens = cached_tokens or 0

	cost.input_tokens = cost.input_tokens + input_tokens
	cost.output_tokens = cost.output_tokens + output_tokens
	cost.cached_tokens = cost.cached_tokens + cached_tokens
	cost.request_count = cost.request_count + 1

	local request_cost = pricing.calculate_cost(model, input_tokens, output_tokens, cached_tokens)
	if request_cost then
		cost.total_cost = cost.total_cost + request_cost
	end

	return request_cost
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
		add_message = add_message,
		get_messages = get_messages,
		get_raw_messages = get_raw_messages,
		last = last,
		count = count,
		tokens = tokens,
		clear = clear,
		set_name = set_name,
		get_name = get_name,
		save = save,
		load = load,
		add_usage = add_usage,
		get_cost = get_cost,
		get_total_cost = get_total_cost,
	}

	return instance
end

return {
	new = new,
	list = list_saved,
	delete = delete_saved,
}
