-- SPDX-FileCopyrightText: © 2022—2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: OWL-1.0 or later
-- Licensed under the Open Weights License v1.0. See LICENSE for details.

local std = require("std")
local json = require("cjson.safe")

-- Tool registry
local registered = {}

local register = function(name, tool)
	registered[name] = tool
end

local get = function(name)
	return registered[name]
end

local list = function()
	local names = {}
	for name, _ in pairs(registered) do
		table.insert(names, name)
	end
	return names
end

-- Get tool description (as table)
local get_description = function(name)
	local tool = registered[name]
	return tool and tool.description
end

-- Get multiple tool descriptions as tables
local get_descriptions = function(names)
	local descs = {}
	for _, name in ipairs(names or {}) do
		local desc = get_description(name)
		if desc then
			table.insert(descs, desc)
		end
	end
	return descs
end

-- Execute a tool by name
local execute = function(name, arguments)
	local tool = registered[name]
	if not tool then
		return nil, "unknown tool: " .. tostring(name)
	end
	return pcall(tool.execute, arguments)
end

-- Helper: Append OAIC-style tool results to messages
local append_oaic_tool_results = function(messages, resp, on_tool_call, on_tool_result)
	local tool_calls = resp.tool_calls or {}
	local assistant_tool_calls = {}

	-- Build assistant message with tool_calls
	for i, call in ipairs(tool_calls) do
		local id = call.id
		if not id and std.nanoid then
			id = "call_" .. std.nanoid()
		end
		call.id = id
		local args = call.arguments
		if type(args) == "table" then
			args = json.encode(args) or "{}"
		end
		table.insert(assistant_tool_calls, {
			id = id,
			type = "function",
			["function"] = { name = call.name, arguments = args },
		})
	end
	table.insert(messages, { role = "assistant", content = resp.text or "", tool_calls = assistant_tool_calls })

	-- Execute tools and add tool messages
	for i, call in ipairs(tool_calls) do
		local decision = nil
		if on_tool_call then
			decision = on_tool_call(call, i, resp)
		end
		decision = decision or { action = "allow" }
		local action = decision.action or "allow"

		-- Abort action: stop loop entirely, return nil to signal abort
		if action == "abort" then
			return nil, decision
		end

		local tool_content
		local result_for_callback
		local is_error = false

		if action == "deny" then
			result_for_callback = { error = decision.error or "tool call denied" }
			tool_content = json.encode(result_for_callback) or ""
			is_error = true
		elseif action == "respond" and decision.response then
			result_for_callback = decision.response
			tool_content = json.encode(result_for_callback) or ""
		else
			local exec_call = call
			if action == "modify" and decision.call then
				exec_call = decision.call
			end
			-- Decode arguments if they're a JSON string
			local args = exec_call.arguments
			if type(args) == "string" then
				args = json.decode(args) or {}
			end
			local ok, result = execute(exec_call.name, args)
			if not ok then
				result_for_callback = { error = tostring(result) }
				tool_content = json.encode(result_for_callback) or ""
				is_error = true
			else
				result_for_callback = result
				tool_content = json.encode(result) or ""
			end
		end

		-- Notify callback of result
		if on_tool_result then
			on_tool_result(call, result_for_callback, is_error)
		end

		table.insert(messages, { role = "tool", tool_call_id = call.id, content = tool_content or "" })
	end

	return messages
end

-- Helper: Append Anthropic-style tool results to messages
local append_anthropic_tool_results = function(messages, resp, on_tool_call, on_tool_result)
	local tool_calls = resp.tool_calls or {}

	-- Build assistant message with tool_use content blocks
	local assistant_content = {}
	if resp.text and #resp.text > 0 then
		table.insert(assistant_content, { type = "text", text = resp.text })
	end
	for _, call in ipairs(tool_calls) do
		local input = call.arguments
		if type(input) == "string" then
			input = json.decode(input) or {}
		end
		table.insert(assistant_content, {
			type = "tool_use",
			id = call.id,
			name = call.name,
			input = input,
		})
	end
	table.insert(messages, { role = "assistant", content = assistant_content })

	-- Build user message with tool_result content blocks
	local tool_results = {}
	for i, call in ipairs(tool_calls) do
		local decision = nil
		if on_tool_call then
			decision = on_tool_call(call, i, resp)
		end
		decision = decision or { action = "allow" }
		local action = decision.action or "allow"

		-- Abort action: stop loop entirely
		if action == "abort" then
			return nil, decision
		end

		local result_content
		local result_for_callback
		local is_error = false

		if action == "deny" then
			result_for_callback = { error = decision.error or "tool call denied" }
			result_content = json.encode(result_for_callback)
			is_error = true
		elseif action == "respond" and decision.response then
			result_for_callback = decision.response
			result_content = json.encode(result_for_callback)
		else
			local exec_call = call
			if action == "modify" and decision.call then
				exec_call = decision.call
			end
			local args = exec_call.arguments
			if type(args) == "string" then
				args = json.decode(args) or {}
			end
			local ok, result = execute(exec_call.name, args)
			if not ok then
				result_for_callback = { error = tostring(result) }
				result_content = json.encode(result_for_callback)
				is_error = true
			else
				result_for_callback = result
				result_content = json.encode(result)
			end
		end

		-- Notify callback of result
		if on_tool_result then
			on_tool_result(call, result_for_callback, is_error)
		end

		local tool_result = {
			type = "tool_result",
			tool_use_id = call.id,
			content = result_content,
		}
		if is_error then
			tool_result.is_error = true
		end
		table.insert(tool_results, tool_result)
	end
	table.insert(messages, { role = "user", content = tool_results })

	return messages
end

-- Helper: Append XML-style tool results to messages
local append_xml_tool_results = function(messages, resp, on_tool_call, on_tool_result)
	local tool_calls = resp.tool_calls or {}
	table.insert(messages, { role = "assistant", content = resp.text })

	local tool_responses = {}
	for i, call in ipairs(tool_calls) do
		local decision = nil
		if on_tool_call then
			decision = on_tool_call(call, i, resp)
		end
		decision = decision or { action = "allow" }
		local action = decision.action or "allow"

		-- Abort action: stop loop entirely
		if action == "abort" then
			return nil, decision
		end

		local result_for_callback
		local is_error = false

		if action == "deny" then
			result_for_callback = {
				name = call.name,
				arguments = call.arguments,
				error = decision.error or "tool call denied",
			}
			is_error = true
			table.insert(tool_responses, result_for_callback)
		elseif action == "respond" and decision.response then
			result_for_callback = decision.response
			table.insert(tool_responses, result_for_callback)
		else
			local exec_call = call
			if action == "modify" and decision.call then
				exec_call = decision.call
			end
			local args = exec_call.arguments
			if type(args) == "string" then
				args = json.decode(args) or { raw = exec_call.arguments }
			end
			local ok, result = execute(exec_call.name, args)
			if not ok then
				result_for_callback = { name = exec_call.name, arguments = args, error = tostring(result) }
				is_error = true
				table.insert(tool_responses, result_for_callback)
			else
				if type(result) == "table" then
					result.name = result.name or exec_call.name
					result_for_callback = result
					table.insert(tool_responses, result)
				else
					result_for_callback = { name = exec_call.name, arguments = args, result = result }
					table.insert(tool_responses, result_for_callback)
				end
			end
		end

		-- Notify callback of result
		if on_tool_result then
			on_tool_result(call, result_for_callback, is_error)
		end
	end
	table.insert(messages, { role = "user", tool_responses = tool_responses })

	return messages
end

-- Main tool loop
local loop = function(client, model, messages, sampler, opts)
	opts = opts or {}
	messages = messages or {}
	local max_steps = opts.max_steps or 8
	local execute_tools = opts.execute_tools or false
	local on_tool_call = opts.on_tool_call
	local on_tool_result = opts.on_tool_result
	local stream = opts.stream or false
	local style = opts.style
		or (client.backend == "anthropic" and "anthropic")
		or (client.backend == "oaic" and "oaic")
		or "xml"

	local cur_messages = std.tbl.copy(messages)
	for step = 1, max_steps do
		local resp, err
		if stream then
			resp, err = client:chat_stream(model, cur_messages, sampler, opts)
		else
			resp, err = client:chat_complete(model, cur_messages, sampler, opts)
		end
		if not resp then
			return nil, err
		end

		local tool_calls = resp.tool_calls
		if not tool_calls or #tool_calls == 0 then
			return resp
		end
		if not execute_tools then
			return resp
		end

		-- Append tool execution results
		local result, abort_decision
		if style == "oaic" then
			result, abort_decision = append_oaic_tool_results(cur_messages, resp, on_tool_call, on_tool_result)
		elseif style == "anthropic" then
			result, abort_decision = append_anthropic_tool_results(cur_messages, resp, on_tool_call, on_tool_result)
		else
			result, abort_decision = append_xml_tool_results(cur_messages, resp, on_tool_call, on_tool_result)
		end

		-- Handle abort - return response with abort info
		if not result then
			resp.aborted = true
			resp.abort_message = abort_decision and abort_decision.message
			return resp
		end
		cur_messages = result
	end

	return nil, "tool loop exceeded max_steps"
end

-- Auto-register built-in tools
local builtins = { "read_file", "write_file", "edit_file", "bash", "web_search", "fetch_webpage" }
for _, name in ipairs(builtins) do
	local ok, tool = pcall(require, "llm.tools." .. name)
	if ok and tool then
		register(tool.name, tool)
	end
end

return {
	register = register,
	get = get,
	list = list,
	get_description = get_description,
	get_descriptions = get_descriptions,
	execute = execute,
	loop = loop,
}
