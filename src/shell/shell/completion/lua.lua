-- SPDX-FileCopyrightText: © 2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: OWL-1.0 or later
-- Licensed under the Open Weights License v1.0. See LICENSE for details.

local style = require("term.tss")
local theme = require("shell.theme")

local tss = style.new(theme.completion)

local search = function(self, input)
	self:flush()

	local token = (input or ""):match("([%a_][%w_%.]*)$")
	if not token then
		return false
	end

	local symbols = self.__sources.lua_symbols
	local keywords = self.__sources.lua_keywords

	local candidates = {}
	local metadata = {}
	local dedupe = {}

	local push = function(full_name, source_name)
		if type(full_name) ~= "string" or full_name == "" then
			return
		end
		if full_name:sub(1, #token) ~= token then
			return
		end
		local suffix = full_name:sub(#token + 1)
		if suffix == "" or dedupe[suffix] then
			return
		end
		dedupe[suffix] = true
		table.insert(candidates, suffix)
		table.insert(metadata, { source = source_name })
	end

	local base, member_prefix = token:match("^(.-)%.([%w_]*)$")
	if base and base ~= "" and symbols and symbols.members then
		local members = symbols:members(base, member_prefix)
		for _, candidate in ipairs(members) do
			push(candidate, "lua_symbol")
		end
	else
		if keywords then
			for _, candidate in ipairs(keywords:search(token)) do
				push(candidate, "lua_keyword")
			end
		end
		if symbols then
			for _, candidate in ipairs(symbols:search(token)) do
				push(candidate, "lua_symbol")
			end
		end
	end

	self.__candidates = candidates
	self.__meta = metadata
	return self:available()
end

local get = function(self, promoted)
	if #self.__candidates > 0 then
		if self.__chosen <= #self.__candidates then
			local variant = self.__candidates[self.__chosen]
			if promoted then
				return variant
			end
			local metadata = self.__meta[self.__chosen] or { source = "default" }
			return tss:apply(metadata.source, variant).text
		end
	end
	return ""
end

return {
	search = search,
	get = get,
}
