-- SPDX-FileCopyrightText: © 2022—2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: LicenseRef-OWL-1.0-or-later OR GPL-3.0-or-later
-- Dual-licensed under OWL v1.0+ and GPLv3+. See LICENSE and LICENSE-GPL3.

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

-- Normalize client responses to a stable contract expected by callers.
-- Canonical shape:
--   text(string), tool_calls(table|nil), tokens(number), ctx(number), rate(number),
--   backend(string|nil), model(string|nil), raw(any, optional)
local normalize_response = function(resp, client, model)
	resp = resp or {}

	if resp.text == nil then
		resp.text = ""
	elseif type(resp.text) ~= "string" then
		resp.text = tostring(resp.text)
	end

	resp.tokens = tonumber(resp.tokens) or 0
	resp.ctx = tonumber(resp.ctx) or 0
	resp.rate = tonumber(resp.rate) or 0
	local client_backend = client and (client.backend or (client.cfg and client.cfg.backend))
	resp.backend = resp.backend or client_backend or nil
	resp.model = resp.model or model

	return resp
end

local ensure_call_id = function(call)
	local id = call.id
	if not id and std.nanoid then
		id = "call_" .. std.nanoid()
		call.id = id
	end
	return id
end

local decode_call_arguments = function(arguments, keep_raw_on_decode_error)
	if type(arguments) == "string" then
		local decoded = json.decode(arguments)
		if decoded ~= nil then
			return decoded
		end
		if keep_raw_on_decode_error then
			return { raw = arguments }
		end
		return {}
	end
	if arguments == nil then
		return {}
	end
	return arguments
end

local get_call_decision = function(call, index, resp, on_tool_call)
	local decision = nil
	if on_tool_call then
		decision = on_tool_call(call, index, resp)
	end
	decision = decision or { action = "allow" }
	return decision.action or "allow", decision
end

local is_error_result = function(result)
	if type(result) ~= "table" then
		return false
	end
	if result.ok == false then
		return true
	end
	if result.error and result.ok ~= true then
		return true
	end
	return false
end

local execute_call = function(call, action, decision, keep_raw_on_decode_error)
	if action == "deny" then
		return { error = decision.error or "tool call denied" }, true, call, call.arguments
	end
	if action == "respond" and decision.response then
		local response = decision.response
		return response, is_error_result(response), call, call.arguments
	end

	local exec_call = call
	if action == "modify" and decision.call then
		exec_call = decision.call
	end

	local args = decode_call_arguments(exec_call.arguments, keep_raw_on_decode_error)
	local ok, result = execute(exec_call.name, args)
	if not ok then
		return { error = tostring(result) }, true, exec_call, args
	end

	return result, is_error_result(result), exec_call, args
end

-- Helper: Append OAIC-style tool results to messages
local append_oaic_tool_results = function(messages, resp, on_tool_call, on_tool_result)
	local tool_calls = resp.tool_calls or {}
	local assistant_tool_calls = {}

	for _, call in ipairs(tool_calls) do
		local id = ensure_call_id(call)
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
	local assistant_msg = { role = "assistant", content = resp.text or "", tool_calls = assistant_tool_calls }
	if resp.response_id then
		assistant_msg.response_id = resp.response_id
	end
	table.insert(messages, assistant_msg)

	for i, call in ipairs(tool_calls) do
		local action, decision = get_call_decision(call, i, resp, on_tool_call)
		if action == "abort" then
			return nil, decision
		end

		local result_for_callback, is_error = execute_call(call, action, decision, false)
		local tool_content = json.encode(result_for_callback) or ""

		if on_tool_result then
			on_tool_result(call, result_for_callback, is_error)
		end

		table.insert(messages, { role = "tool", tool_call_id = call.id, content = tool_content })
	end

	return messages
end

-- Helper: Append Anthropic-style tool results to messages
local append_anthropic_tool_results = function(messages, resp, on_tool_call, on_tool_result)
	local tool_calls = resp.tool_calls or {}
	local assistant_content = {}

	if resp.text and #resp.text > 0 then
		table.insert(assistant_content, { type = "text", text = resp.text })
	end
	for _, call in ipairs(tool_calls) do
		table.insert(assistant_content, {
			type = "tool_use",
			id = call.id,
			name = call.name,
			input = decode_call_arguments(call.arguments, false),
		})
	end
	table.insert(messages, { role = "assistant", content = assistant_content })

	local tool_results = {}
	for i, call in ipairs(tool_calls) do
		local action, decision = get_call_decision(call, i, resp, on_tool_call)
		if action == "abort" then
			return nil, decision
		end

		local result_for_callback, is_error = execute_call(call, action, decision, false)
		local result_content = json.encode(result_for_callback)

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
		local action, decision = get_call_decision(call, i, resp, on_tool_call)
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
				ok = false,
			}
			is_error = true
			table.insert(tool_responses, result_for_callback)
		else
			local raw_result, raw_is_error, exec_call, args = execute_call(call, action, decision, true)
			is_error = raw_is_error

			if is_error then
				if type(raw_result) ~= "table" then
					raw_result = { error = tostring(raw_result) }
				end
				raw_result.name = raw_result.name or (exec_call and exec_call.name or call.name)
				raw_result.arguments = raw_result.arguments or args
				raw_result.ok = false
				result_for_callback = raw_result
				table.insert(tool_responses, result_for_callback)
			else
				if type(raw_result) == "table" then
					raw_result.name = raw_result.name or (exec_call and exec_call.name or call.name)
					result_for_callback = raw_result
				else
					result_for_callback = {
						name = exec_call and exec_call.name or call.name,
						arguments = args,
						result = raw_result,
						ok = true,
					}
				end
				table.insert(tool_responses, result_for_callback)
			end
		end

		if on_tool_result then
			on_tool_result(call, result_for_callback, is_error)
		end
	end
	table.insert(messages, { role = "user", tool_responses = tool_responses })

	return messages
end

local APPEND_BY_STYLE = {
	oaic = append_oaic_tool_results,
	anthropic = append_anthropic_tool_results,
	xml = append_xml_tool_results,
}

-- Main tool loop
local loop = function(client, model, messages, sampler, opts)
	opts = opts or {}
	messages = messages or {}
	local max_steps = opts.max_steps or 8
	local execute_tools = opts.execute_tools or false
	local on_tool_call = opts.on_tool_call
	local on_tool_result = opts.on_tool_result
	local stream = opts.stream or false
	local client_backend = client and (client.backend or (client.cfg and client.cfg.backend))
	local style = opts.style
		or (client_backend == "anthropic" and "anthropic")
		or (client_backend == "oaic" and "oaic")
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
			return normalize_response(resp, client, model)
		end
		if not execute_tools then
			return normalize_response(resp, client, model)
		end

		-- Append tool execution results
		local append_fn = APPEND_BY_STYLE[style] or APPEND_BY_STYLE.xml
		local result, abort_decision = append_fn(cur_messages, resp, on_tool_call, on_tool_result)

		-- Handle abort - return response with abort info
		if not result then
			resp.aborted = true
			resp.abort_message = abort_decision and abort_decision.message
			return normalize_response(resp, client, model)
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
