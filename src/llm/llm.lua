-- SPDX-FileCopyrightText: © 2023 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: GPL-3.0-or-later

local std = require("std")
local openai = require("llm.openai")
local anthropic = require("llm.anthropic")
local general = require("llm.general")
local ggml = require("llm.ggml")

local new = function(backend, api_url, api_key)
	if backend == "OpenAI" then
		return openai.new(backend, api_key, api_url)
	end
	if backend == "MistralAI" then
		local api_url = api_url or "https://api.mistral.ai/v1"
		local api_key = api_key or os.getenv("MISTRAL_API_KEY")
		return openai.new(backend, api_key, api_url)
	end
	if backend == "Claude" then
		return anthropic.new(api_key, api_url)
	end
	if backend:match("^%u") then
		local api_url = api_url or "http://127.0.0.1:8080/v1"
		return openai.new(backend, api_key, api_url)
	end
	if backend == "llamacpp" then
		return ggml.new(api_url)
	end
	return general.new(api_url)
end

local render_prompt_tmpl = function(tmpl, messages, add_last_suffix)
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
	default_tmpl = std.merge_tables(default_tmpl, tmpl)
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
