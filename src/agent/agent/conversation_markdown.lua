-- SPDX-FileCopyrightText: © 2022—2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: LicenseRef-OWL-1.0-or-later OR GPL-3.0-or-later
-- Dual-licensed under OWL v1.0+ and GPLv3+. See LICENSE and LICENSE-GPL3.

--[[
Conversation -> markdown formatter for agent pager views.
]]

local json = require("cjson.safe")
local llm_tools = require("llm.tools")

local normalize_text = function(value)
	if value == nil then
		return ""
	end
	if type(value) == "string" then
		return value
	end
	if type(value) == "table" then
		local encoded = json.encode(value)
		if encoded then
			return encoded
		end
	end
	return tostring(value)
end

local compact_text = function(value, max_len)
	max_len = max_len or 240
	local text = normalize_text(value):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
	if #text <= max_len then
		return text
	end
	return text:sub(1, max_len) .. "..."
end

local indent_text = function(text, indent)
	indent = indent or 2
	local prefix = string.rep(" ", indent)
	local out = {}
	for line in (text .. "\n"):gmatch("([^\n]*)\n") do
		out[#out + 1] = prefix .. line
	end
	return table.concat(out, "\n")
end

local detect_div_fence_len = function(text)
	local max_len = 3
	for line in (text .. "\n"):gmatch("([^\n]*)\n") do
		local colons = line:match("^(:+)%s*$")
		if colons and #colons >= max_len then
			max_len = #colons + 1
		end
	end
	return max_len
end

local wrap_div = function(class_name, content)
	class_name = class_name or "default"
	content = normalize_text(content)
	local fence_len = detect_div_fence_len(content)
	local fence = string.rep(":", fence_len)
	return fence .. " " .. class_name .. "\n" .. indent_text(content, 2) .. "\n" .. fence
end

local normalize_tool_name = llm_tools.normalize_tool_name
local normalize_tool_args = llm_tools.normalize_tool_args

local parse_tool_result = function(content)
	if type(content) == "table" then
		return content
	end
	if type(content) ~= "string" or content == "" then
		return nil
	end
	local decoded = json.decode(content)
	if type(decoded) == "table" then
		return decoded
	end
	return nil
end

local summarize_value = function(value, max_len)
	if value == nil then
		return ""
	end
	if type(value) == "string" then
		return compact_text(value, max_len)
	end
	if type(value) == "number" or type(value) == "boolean" then
		return tostring(value)
	end
	if type(value) == "table" then
		local encoded = json.encode(value)
		if encoded then
			return compact_text(encoded, max_len)
		end
	end
	return compact_text(tostring(value), max_len)
end

local add_info = function(lines, key, value, max_len)
	local formatted = summarize_value(value, max_len)
	if formatted == "" then
		return
	end
	lines[#lines + 1] = key .. ": " .. formatted
end

local table_cell_text = function(value)
	local text = normalize_text(value)
	text = text:gsub("[\r\n]+", " ")
	text = text:gsub("|", "\\|")
	text = text:gsub("%s+", " ")
	text = text:gsub("^%s+", ""):gsub("%s+$", "")
	if text == "" then
		return "-"
	end
	return text
end

local copy_selected = function(result, keys)
	local out = {}
	for _, key in ipairs(keys) do
		local value = result[key]
		if value ~= nil then
			out[key] = value
		end
	end
	return out
end

local compact_web_search_result = function(result)
	local out = copy_selected(result, { "name", "ok", "status", "error" })
	local payload = result.results
	if type(payload) == "table" then
		local sources = payload.sources
		if type(sources) == "table" then
			out.sources = #sources
		end
		local answer = payload.answer or payload.sourcedAnswer or payload.response
		if type(answer) == "string" and answer ~= "" then
			out.has_answer = true
		end
	end
	return out
end

local compact_unknown_result = function(result)
	local hidden = {
		content = true,
		stdout = true,
		stderr = true,
		page = true,
		body = true,
		results = true,
	}
	local out = {}
	for key, value in pairs(result) do
		if not hidden[key] then
			local kind = type(value)
			if kind == "string" or kind == "number" or kind == "boolean" then
				out[key] = value
			elseif kind == "table" and key == "lines" then
				out[key] = value
			end
		end
	end
	return out
end

local compact_result_builders = {
	read = function(result)
		return copy_selected(result, {
			"name",
			"ok",
			"filepath",
			"lines",
			"total_lines",
			"truncated",
			"offset",
			"limit",
			"hint",
			"error",
		})
	end,
	write = function(result)
		return copy_selected(result, { "name", "ok", "filepath", "bytes_written", "created", "error" })
	end,
	edit = function(result)
		return copy_selected(result, { "name", "ok", "filepath", "line", "success", "error" })
	end,
	bash = function(result)
		return copy_selected(result, {
			"name",
			"ok",
			"command",
			"exit_code",
			"stdout_truncated",
			"stdout_total_bytes",
			"stderr_truncated",
			"stderr_total_bytes",
			"hint",
			"error",
		})
	end,
	fetch_webpage = function(result)
		return copy_selected(result, { "name", "ok", "url", "status", "error" })
	end,
	web_search = compact_web_search_result,
}

local tool_response_summary = function(entry, summary_max)
	local result = entry.result
	if type(result) == "table" then
		local name = entry.name
		if (not name or name == "unknown") and type(result.name) == "string" and result.name ~= "" then
			name = result.name
		end
		local builder = compact_result_builders[name] or compact_unknown_result
		local compact_result = builder(result)
		local encoded = json.encode(compact_result)
		if encoded and encoded ~= "" then
			return compact_text(encoded, summary_max)
		end
	end
	if entry.result_raw and entry.result_raw ~= "" then
		return compact_text(entry.result_raw, summary_max)
	end
	return "null"
end

local render_tools_table = function(tool_entries, summary_max)
	if not tool_entries or #tool_entries == 0 then
		return nil
	end

	local counts = {}
	for _, entry in ipairs(tool_entries) do
		local name = compact_text(entry.name or "unknown", summary_max)
		if name == "" then
			name = "unknown"
		end
		counts[name] = (counts[name] or 0) + 1
	end

	local names = {}
	for name, _ in pairs(counts) do
		names[#names + 1] = name
	end
	table.sort(names, function(a, b)
		local count_a = counts[a] or 0
		local count_b = counts[b] or 0
		if count_a == count_b then
			return a < b
		end
		return count_a > count_b
	end)

	local rows = {
		"| tool name | count |",
		"| --- | ---: |",
	}

	for _, name in ipairs(names) do
		rows[#rows + 1] = "| " .. table_cell_text(name) .. " | " .. tostring(counts[name] or 0) .. " |"
	end

	return table.concat(rows, "\n")
end

local add_assistant_content = function(turn, message)
	turn.has_assistant = true
	local content = normalize_text(message and message.content or "")
	if content:match("%S") then
		turn.assistant_content[#turn.assistant_content + 1] = content
	end
	for _, call in ipairs(message and message.tool_calls or {}) do
		local entry = {
			name = normalize_tool_name(call),
			args = normalize_tool_args(call),
			result = nil,
		}
		turn.tool_entries[#turn.tool_entries + 1] = entry
		local call_id = call and (call.id or call.tool_call_id) or nil
		if type(call_id) == "string" and call_id ~= "" then
			turn.tool_by_id[call_id] = entry
		end
	end
end

local add_tool_result = function(turn, message)
	local call_id = message and message.tool_call_id or nil
	local entry = nil
	if type(call_id) == "string" and call_id ~= "" then
		entry = turn.tool_by_id[call_id]
	end
	if not entry then
		entry = { name = "unknown", args = "", result = nil }
		turn.tool_entries[#turn.tool_entries + 1] = entry
		if type(call_id) == "string" and call_id ~= "" then
			turn.tool_by_id[call_id] = entry
		end
	end

	entry.result_raw = normalize_text(message and message.content or "")
	entry.result = parse_tool_result(message and message.content or nil)
	if entry.name == "unknown" and type(entry.result) == "table" and type(entry.result.name) == "string" then
		entry.name = entry.result.name
	end
end

local new_turn = function(user_content)
	return {
		user_content = user_content,
		has_assistant = false,
		assistant_content = {},
		tool_entries = {},
		tool_by_id = {},
	}
end

local render_turn = function(turn, summary_max)
	local chunks = {}
	if turn.user_content ~= nil then
		chunks[#chunks + 1] = wrap_div("user", turn.user_content)
	end

	if turn.has_assistant or #turn.tool_entries > 0 or #turn.assistant_content > 0 then
		local assistant_chunks = { "### assistant" }
		local tools_table = render_tools_table(turn.tool_entries, summary_max)
		if tools_table then
			assistant_chunks[#assistant_chunks + 1] = tools_table
		end
		if #turn.assistant_content > 0 then
			assistant_chunks[#assistant_chunks + 1] = table.concat(turn.assistant_content, "\n\n")
		elseif #turn.tool_entries == 0 then
			assistant_chunks[#assistant_chunks + 1] = "_(empty)_"
		end
		chunks[#chunks + 1] = table.concat(assistant_chunks, "\n\n")
	end

	return chunks
end

local build = function(messages, opts)
	opts = opts or {}
	local summary_max = opts.tool_summary_max or 240
	local turns = {}
	local turn = nil

	for _, message in ipairs(messages or {}) do
		local role = message and message.role
		if role == "user" then
			turn = new_turn(normalize_text(message.content or ""))
			turns[#turns + 1] = turn
		elseif role == "assistant" then
			if not turn then
				turn = new_turn(nil)
				turns[#turns + 1] = turn
			end
			add_assistant_content(turn, message)
		elseif role == "tool" then
			if not turn then
				turn = new_turn(nil)
				turns[#turns + 1] = turn
			end
			add_tool_result(turn, message)
		end
	end

	local chunks = {}
	for _, display_turn in ipairs(turns) do
		local rendered = render_turn(display_turn, summary_max)
		for _, chunk in ipairs(rendered) do
			chunks[#chunks + 1] = chunk
		end
	end

	if #chunks == 0 then
		return "No messages in current conversation."
	end

	return table.concat(chunks, "\n\n")
end

return {
	build = build,
}
