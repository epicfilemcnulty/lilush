-- SPDX-FileCopyrightText: © 2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: OWL-1.0 or later
-- Licensed under the Open Weights License v1.0. See LICENSE for details.

local std = require("std")

local split_tokens = function(input)
	local tokens = {}
	local value = tostring(input or "")
	for token in value:gmatch("%S+") do
		tokens[#tokens + 1] = token
	end
	if value:match("%s+$") then
		tokens[#tokens + 1] = ""
	end
	return tokens
end

local build_suffix_candidates = function(full_candidates, prefix, append_space)
	local out = {}
	local seen = {}
	local escaped_prefix = std.escape_magic_chars(prefix or "")

	for _, full in ipairs(full_candidates or {}) do
		if type(full) == "string" and full:match("^" .. escaped_prefix) then
			local suffix = full:sub(#prefix + 1)
			if append_space then
				suffix = suffix .. " "
			end
			if (suffix ~= "" or append_space) and not seen[suffix] then
				seen[suffix] = true
				out[#out + 1] = suffix
			end
		end
	end

	return out
end

local fill_default_meta = function(self)
	local metadata = {}
	for i = 1, #self.__candidates do
		metadata[i] = { source = "default" }
	end
	self.__meta = metadata
end

local select_candidates = function(source, tokens)
	local command = tokens[1]
	local args = {}
	for i = 2, #tokens do
		args[#args + 1] = tokens[i]
	end
	local args_count = #args

	if args_count == 0 then
		return source:commands(command), command
	end

	if command == "/provider" and args_count == 1 then
		local values = source:providers(args[1])
		if ("refresh"):match("^" .. std.escape_magic_chars(args[1])) then
			values[#values + 1] = "refresh"
		end
		return values, args[1]
	end

	if command == "/provider" and args_count == 2 and args[1] == "refresh" then
		return source:providers(args[2]), args[2]
	end

	if command == "/model" then
		if args_count == 1 then
			return source:models(source:current_provider(), args[1]), args[1]
		end
		if args_count == 2 then
			return source:providers(args[2]), args[2]
		end
	end

	if command == "/prompt" then
		if args_count == 1 then
			return source:prompt_subcommands(args[1]), args[1]
		end
		if args_count == 2 and args[1] == "set" then
			return source:prompts(args[2]), args[2]
		end
	end

	if command == "/sysprompt" then
		if args_count == 1 then
			return source:sysprompt_subcommands(args[1]), args[1]
		end
		if args_count == 2 and args[1] == "set" then
			return source:system_prompts(args[2]), args[2]
		end
	end

	if command == "/load" and args_count == 1 then
		return source:saved_conversations(args[1]), args[1]
	end

	if command == "/save" and args_count == 1 then
		return source:saved_conversations(args[1]), args[1]
	end

	return {}, nil
end

local search = function(self, input, history)
	self:flush()

	if type(input) ~= "string" or input == "" or input:sub(1, 1) ~= "/" then
		return false
	end

	local source = self.__sources and self.__sources["slash"]
	if not source then
		return false
	end

	local tokens = split_tokens(input)
	if #tokens == 0 or tokens[1]:sub(1, 1) ~= "/" then
		return false
	end

	local full_candidates, prefix = select_candidates(source, tokens)
	if not prefix then
		return false
	end

	self.__candidates = build_suffix_candidates(full_candidates, prefix, true)
	fill_default_meta(self)
	return self:available()
end

return {
	search = search,
}
