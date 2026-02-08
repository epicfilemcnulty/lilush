-- SPDX-FileCopyrightText: © 2022—2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: LicenseRef-OWL-1.0-or-later OR GPL-3.0-or-later
-- Dual-licensed under OWL v1.0+ and GPLv3+. See LICENSE and LICENSE-GPL3.

local std = require("std")
local buffer = require("string.buffer")
local json = require("cjson.safe")

local tool_header = [[
# Tools

You may call one or more functions to assist with the user query.

You are provided with function signatures within <tools></tools> XML tags:
]]

local tool_footer = [[

For each function call, return a json object with function name and arguments within <tool_call></tool_call> XML tags:
<tool_call>
{"name": <function-name>, "arguments": <args-json-object>}
</tool_call>
 ]]

local stringify_content = function(value)
	if value == nil then
		return ""
	end
	if type(value) == "string" then
		return value
	end
	if type(value) == "table" then
		return json.encode(value) or tostring(value)
	end
	return tostring(value)
end

-- Applies chat template to messages, optionally including tool descriptions
-- tpl: template with prefixes/suffixes for system/user/llm roles
-- messages: array of {role, content} tables
-- tools: array of tool description tables (will be JSON-encoded)
-- dont_start: if true, don't add the final llm.prefix
local apply = function(tpl, messages, tools, dont_start)
	tpl = tpl or {}
	messages = messages or {}
	tools = tools or {}

	local template = {
		system = {
			prefix = "",
			suffix = "",
		},
		user = {
			prefix = "",
			suffix = "",
		},
		llm = {
			prefix = "",
			suffix = "",
		},
	}
	template = std.tbl.merge(template, tpl)
	local out = buffer.new()

	for _, msg in ipairs(messages) do
		if msg.role == "system" then
			out:put(template.system.prefix, stringify_content(msg.content))
			if #tools > 0 then
				local th = tpl.tool_header or tool_header
				local tf = tpl.tool_footer or tool_footer
				out:put(th, "<tools>")
				for _, tool in ipairs(tools) do
					local tool_json = type(tool) == "string" and tool or json.encode(tool)
					if tool_json then
						out:put(tool_json)
					end
				end
				out:put("</tools>", tf)
			end
			out:put(template.system.suffix)
		elseif msg.role == "user" then
			out:put(template.user.prefix)
			if type(msg.tool_responses) == "table" then
				for _, response in ipairs(msg.tool_responses) do
					local resp_json = json.encode(response)
					if resp_json then
						out:put("<tool_response>", resp_json, "</tool_response>")
					end
				end
			else
				out:put(stringify_content(msg.content))
			end
			out:put(template.user.suffix)
		elseif msg.role == "assistant" then
			out:put(template.llm.prefix, stringify_content(msg.content), template.llm.suffix)
		end
	end

	if not dont_start then
		out:put(template.llm.prefix)
	end
	return out:get()
end

return {
	apply = apply,
	tool_header = tool_header,
	tool_footer = tool_footer,
}
