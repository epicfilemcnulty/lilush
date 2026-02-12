-- SPDX-FileCopyrightText: © 2022—2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: LicenseRef-OWL-1.0-or-later OR GPL-3.0-or-later
-- Dual-licensed under OWL v1.0+ and GPLv3+. See LICENSE and LICENSE-GPL3.

local std = require("std")
local json = require("cjson.safe")

-- Built-in tools are loaded from src/llm/llm/tools/*.lua and keyed by canonical tool name.
local registered = {}
local builtin_modules = { "read_file", "write_file", "edit_file", "bash", "web_search", "fetch_webpage" }
for _, module_name in ipairs(builtin_modules) do
	local ok, tool = pcall(require, "llm.tools." .. module_name)
	if ok and type(tool) == "table" and type(tool.name) == "string" and tool.name ~= "" then
		registered[tool.name] = tool
	end
end

local get = function(name)
	return registered[name]
end

local list = function()
	local names = {}
	for name, _ in pairs(registered) do
		table.insert(names, name)
	end
	table.sort(names)
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
	names = names or list()
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

local is_non_empty_string = function(value)
	return type(value) == "string" and value ~= ""
end

local is_ffi_marker_string = function(value)
	return type(value) == "string" and (value:match("^userdata:") or value:match("^cdata:"))
end

local stringify_tool_arguments = function(arguments)
	if type(arguments) == "string" then
		return arguments
	end
	if arguments == nil then
		return "{}"
	end
	if type(arguments) == "table" then
		return json.encode(arguments) or "{}"
	end
	local s = tostring(arguments)
	if is_ffi_marker_string(s) then
		return "{}"
	end
	return s
end

-- Normalize client responses to a stable contract expected by callers.
-- Canonical shape:
--   text(string), reasoning_text(string), tool_calls(table|nil), tokens(number), ctx(number), rate(number),
--   backend(string|nil), model(string|nil), raw(any, optional)
local normalize_response = function(resp, client, model)
	resp = resp or {}

	if resp.text == nil then
		resp.text = ""
	elseif type(resp.text) ~= "string" then
		resp.text = tostring(resp.text)
	end
	if resp.reasoning_text == nil then
		resp.reasoning_text = ""
	elseif type(resp.reasoning_text) ~= "string" then
		resp.reasoning_text = tostring(resp.reasoning_text)
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
	if type(call) ~= "table" then
		return nil
	end

	local id = call.id
	if type(id) ~= "string" or id == "" then
		local alt_id = call.call_id
		if type(alt_id) == "string" and alt_id ~= "" then
			id = alt_id
		elseif alt_id ~= nil then
			local alt_s = tostring(alt_id)
			if alt_s ~= "" and not is_ffi_marker_string(alt_s) then
				id = alt_s
			end
		elseif id ~= nil then
			local id_s = tostring(id)
			if id_s ~= "" and not is_ffi_marker_string(id_s) then
				id = id_s
			else
				id = nil
			end
		else
			id = nil
		end
	end

	if (type(id) ~= "string" or id == "") and std.nanoid then
		id = "call_" .. std.nanoid()
	end
	if type(id) == "string" and id ~= "" then
		call.id = id
		return id
	end
	return id
end

local normalize_tool_name = function(call)
	if type(call) ~= "table" then
		return "unknown"
	end
	if type(call.name) == "string" and call.name ~= "" then
		return call.name
	end
	local fn = call["function"]
	if type(fn) == "table" and type(fn.name) == "string" and fn.name ~= "" then
		return fn.name
	end
	return "unknown"
end

local normalize_tool_args = function(call)
	if type(call) ~= "table" then
		return ""
	end
	local args = call.arguments
	if args ~= nil then
		return stringify_tool_arguments(args)
	end
	local fn = call["function"]
	if type(fn) == "table" then
		return stringify_tool_arguments(fn.arguments)
	end
	return ""
end

local emit_tool_warning = function(on_tool_warning, message, call)
	if type(on_tool_warning) ~= "function" then
		return
	end
	pcall(on_tool_warning, message, call)
end

local extract_raw_tool_name = function(call)
	if type(call) ~= "table" then
		return nil
	end
	if is_non_empty_string(call.name) then
		return call.name
	end
	local fn = call["function"]
	if type(fn) == "table" and is_non_empty_string(fn.name) then
		return fn.name
	end
	local legacy = call.function_call
	if type(legacy) == "table" and is_non_empty_string(legacy.name) then
		return legacy.name
	end
	return nil
end

local extract_raw_tool_arguments = function(call)
	if type(call) ~= "table" then
		return nil
	end
	if call.arguments ~= nil then
		return call.arguments
	end
	local fn = call["function"]
	if type(fn) == "table" then
		return fn.arguments
	end
	local legacy = call.function_call
	if type(legacy) == "table" then
		return legacy.arguments
	end
	return nil
end

local normalize_oaic_tool_calls = function(calls, on_tool_warning)
	if type(calls) ~= "table" then
		return {}, 0
	end

	local out = {}
	local dropped = 0
	for index, raw_call in ipairs(calls) do
		if type(raw_call) ~= "table" then
			dropped = dropped + 1
			emit_tool_warning(
				on_tool_warning,
				"Skipping malformed tool call #" .. tostring(index) .. ": expected an object",
				raw_call
			)
		else
			local name = extract_raw_tool_name(raw_call)
			if not name then
				dropped = dropped + 1
				emit_tool_warning(
					on_tool_warning,
					"Skipping malformed tool call #" .. tostring(index) .. ": missing function name",
					raw_call
				)
			else
				local normalized_call = {
					id = ensure_call_id(raw_call),
					type = "function",
					name = name,
					arguments = stringify_tool_arguments(extract_raw_tool_arguments(raw_call)),
				}
				if not normalized_call.id or normalized_call.id == "" then
					dropped = dropped + 1
					emit_tool_warning(
						on_tool_warning,
						"Skipping malformed tool call #" .. tostring(index) .. ": missing tool_call id",
						raw_call
					)
				else
					out[#out + 1] = normalized_call
				end
			end
		end
	end

	return out, dropped
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
		return { name = call.name, ok = false, error = decision.error or "tool call denied" },
			true,
			call,
			call.arguments
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
		return { name = exec_call.name or call.name, ok = false, error = tostring(result) }, true, exec_call, args
	end

	return result, is_error_result(result), exec_call, args
end

-- Helper: Append OAIC-style tool results to messages
local append_oaic_tool_results = function(messages, resp, on_tool_call, on_tool_result)
	local tool_calls = resp.tool_calls or {}
	local assistant_tool_calls = {}

	for _, call in ipairs(tool_calls) do
		table.insert(assistant_tool_calls, {
			id = call.id,
			type = "function",
			["function"] = { name = call.name, arguments = call.arguments },
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
	local on_tool_warning = opts.on_tool_warning
	local stream = opts.stream or false
	local client_backend = client and (client.backend or (client.cfg and client.cfg.backend))
	local style = opts.style or (client_backend == "oaic" and "oaic") or "xml"

	local cur_messages = std.tbl.copy(messages)
	local cumulative_usage = { input_tokens = 0, output_tokens = 0, cached_tokens = 0, request_count = 0 }
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

		-- Accumulate token usage across tool loop iterations
		cumulative_usage.request_count = cumulative_usage.request_count + 1
		local call_output = tonumber(resp.tokens) or 0
		local call_input = (tonumber(resp.ctx) or 0) - call_output
		if call_input < 0 then
			call_input = 0
		end
		cumulative_usage.input_tokens = cumulative_usage.input_tokens + call_input
		cumulative_usage.output_tokens = cumulative_usage.output_tokens + call_output

		if resp.cancelled then
			resp.cumulative_usage = cumulative_usage
			return normalize_response(resp, client, model)
		end

		local tool_calls = resp.tool_calls
		local dropped_tool_calls = 0
		if style == "oaic" then
			tool_calls, dropped_tool_calls = normalize_oaic_tool_calls(tool_calls, on_tool_warning)
			resp.tool_calls = tool_calls
		end
		if not tool_calls or #tool_calls == 0 then
			if dropped_tool_calls > 0 and (not resp.text or resp.text == "") then
				resp.text = "Model emitted malformed tool calls; skipped."
			end
			resp.cumulative_usage = cumulative_usage
			return normalize_response(resp, client, model)
		end
		if not execute_tools then
			resp.cumulative_usage = cumulative_usage
			return normalize_response(resp, client, model)
		end

		-- Append tool execution results
		local append_fn = APPEND_BY_STYLE[style] or APPEND_BY_STYLE.xml
		local result, abort_decision = append_fn(cur_messages, resp, on_tool_call, on_tool_result)

		-- Handle abort - return response with abort info
		if not result then
			resp.aborted = true
			resp.abort_message = abort_decision and abort_decision.message
			resp.cumulative_usage = cumulative_usage
			return normalize_response(resp, client, model)
		end
		cur_messages = result
	end

	return nil, "tool loop exceeded max_steps"
end

return {
	get = get,
	list = list,
	get_description = get_description,
	get_descriptions = get_descriptions,
	execute = execute,
	loop = loop,
	ensure_call_id = ensure_call_id,
	normalize_tool_name = normalize_tool_name,
	normalize_tool_args = normalize_tool_args,
}
