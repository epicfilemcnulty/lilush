-- SPDX-FileCopyrightText: © 2023 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: GPL-3.0-or-later

local std = require("std")
local anthropic = require("llm.anthropic")
local general = require("llm.general")
local ggml = require("llm.ggml")

local new = function(backend, api_url)
	if backend == "OpenAI" or backend == "MistralAI" or backend == "Claude" then
		return anthropic.new(backend)
	end
	if backend == "llamacpp" then
		local api_url = api_url or "http://127.0.0.1:8080"
		return ggml.new(api_url)
	end
	local api_url = api_url or "http://127.0.0.1:8013"
	return general.new(api_url)
end

local convert_to_bltzr_fmt = function(messages, completion)
	if completion then
		return { { kind = "spt", token = "<TXT>", content = messages[#messages].content } }
	end
	local msgs = { { kind = "spt", token = "<CHAT>" } }
	for i, msg in ipairs(messages) do
		if msg.role == "system" then
			table.insert(msgs, { kind = "spt", token = "<SYS>", content = msg.content })
			table.insert(msgs, { kind = "spt", token = "</SYS>" })
		elseif msg.role == "user" then
			table.insert(msgs, { kind = "spt", token = "<QUERY>", content = msg.content })
			table.insert(msgs, { kind = "spt", token = "</QUERY>" })
		elseif msg.role == "assistant" then
			table.insert(msgs, { kind = "spt", token = "<REPLY>", content = msg.content })
			table.insert(msgs, { kind = "spt", token = "</REPLY>" })
		end
	end
	table.insert(msgs, { kind = "spt", token = "<REPLY>" })
	return msgs
end

local render_prompt_tmpl = function(tmpl, messages, add_last_suffix)
	if tmpl and type(tmpl) == "string" then
		if tmpl == "mamba" then
			return convert_to_bltzr_fmt(messages, true)
		end
	end
	local tmpl = tmpl or {}
	local default_tmpl = {
		system = {
			prefix = "",
			suffix = "",
		},
		prefix = "",
		infix = "",
		suffix = "",
	}
	default_tmpl = std.tbl.merge(default_tmpl, tmpl)
	local messages = messages or {}
	local out = ""
	for i, msg in ipairs(messages) do
		if msg.role == "system" then
			out = out .. default_tmpl.system.prefix .. msg.content .. default_tmpl.system.suffix
		end
		if msg.role == "user" then
			out = out .. default_tmpl.prefix .. msg.content .. default_tmpl.infix
		end
		if msg.role == "assistant" then
			out = out .. default_tmpl.suffix .. msg.content .. "\n"
		end
	end
	if add_last_suffix then
		out = out .. default_tmpl.suffix
	end
	return out
end
return { new = new, render_prompt_tmpl = render_prompt_tmpl }
