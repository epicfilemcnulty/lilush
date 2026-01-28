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
local append_oaic_tool_results = function(messages, resp, on_tool_call)
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

		local tool_content
		if action == "deny" then
			tool_content = json.encode({ error = decision.error or "tool call denied" }) or ""
		elseif action == "respond" and decision.response then
			tool_content = json.encode(decision.response) or ""
		else
			local exec_call = call
			if action == "modify" and decision.call then
				exec_call = decision.call
			end
			local ok, result = execute(exec_call.name, exec_call.arguments)
			if not ok then
				tool_content = json.encode({ error = tostring(result) }) or ""
			else
				tool_content = json.encode(result) or ""
			end
		end
		table.insert(messages, { role = "tool", tool_call_id = call.id, content = tool_content or "" })
	end

	return messages
end

-- Helper: Append XML-style tool results to messages
local append_xml_tool_results = function(messages, resp, on_tool_call)
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

		if action == "deny" then
			table.insert(tool_responses, {
				name = call.name,
				arguments = call.arguments,
				error = decision.error or "tool call denied",
			})
		elseif action == "respond" and decision.response then
			table.insert(tool_responses, decision.response)
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
				table.insert(tool_responses, { name = exec_call.name, arguments = args, error = tostring(result) })
			else
				if type(result) == "table" then
					result.name = result.name or exec_call.name
					table.insert(tool_responses, result)
				else
					table.insert(tool_responses, { name = exec_call.name, arguments = args, result = result })
				end
			end
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
	local stream = opts.stream or false
	local style = opts.style or (client.backend == "oaic" and "oaic" or "xml")

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
		if style == "oaic" then
			cur_messages = append_oaic_tool_results(cur_messages, resp, on_tool_call)
		else
			cur_messages = append_xml_tool_results(cur_messages, resp, on_tool_call)
		end
	end

	return nil, "tool loop exceeded max_steps"
end

-- Auto-register built-in tools
local builtins = { "read_file", "web_search", "fetch_webpage" }
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
