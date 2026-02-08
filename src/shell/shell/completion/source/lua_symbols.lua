-- SPDX-FileCopyrightText: © 2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: OWL-1.0 or later
-- Licensed under the Open Weights License v1.0. See LICENSE for details.

local std = require("std")

local normalize_candidates = function(candidates)
	table.sort(candidates, function(a, b)
		if #a == #b then
			return a < b
		end
		return #a < #b
	end)
	return candidates
end

local collect_table_keys = function(tbl, out, seen)
	if type(tbl) ~= "table" then
		return
	end
	for key, _ in pairs(tbl) do
		if type(key) == "string" and key:match("^[%a_][%w_]*$") and not seen[key] then
			seen[key] = true
			table.insert(out, key)
		end
	end
	local mt = getmetatable(tbl)
	local idx = mt and mt.__index
	if type(idx) == "table" then
		for key, _ in pairs(idx) do
			if type(key) == "string" and key:match("^[%a_][%w_]*$") and not seen[key] then
				seen[key] = true
				table.insert(out, key)
			end
		end
	end
end

local resolve_path = function(self, path)
	local ctx = self.__state.repl_env
	for part in tostring(path):gmatch("([%a_][%w_]*)") do
		if type(ctx) ~= "table" then
			return nil
		end
		local next_value = rawget(ctx, part)
		if next_value == nil then
			local mt = getmetatable(ctx)
			local idx = mt and mt.__index
			if type(idx) == "table" then
				next_value = idx[part]
			end
		end
		ctx = next_value
	end
	return ctx
end

local update = function(self, repl_env)
	if type(repl_env) == "table" then
		self.__state.repl_env = repl_env
	end

	local symbols = {}
	local seen = {}
	collect_table_keys(self.__state.repl_env, symbols, seen)
	self.__state.symbols = normalize_candidates(symbols)
end

local search = function(self, prefix)
	local candidates = {}
	local escaped = std.escape_magic_chars(prefix or "")
	for _, name in ipairs(self.__state.symbols or {}) do
		if name:match("^" .. escaped) then
			table.insert(candidates, name)
		end
	end
	return candidates
end

local members = function(self, path, prefix)
	local target = resolve_path(self, path)
	if type(target) ~= "table" then
		return {}
	end

	local keys = {}
	local seen = {}
	collect_table_keys(target, keys, seen)
	keys = normalize_candidates(keys)

	local full = {}
	local escaped = std.escape_magic_chars(prefix or "")
	for _, key in ipairs(keys) do
		if key:match("^" .. escaped) then
			table.insert(full, path .. "." .. key)
		end
	end
	return full
end

local new = function(config)
	local source = {
		cfg = config or {},
		__state = {
			repl_env = _G,
			symbols = {},
		},
		update = update,
		search = search,
		members = members,
	}
	source:update(_G)
	return source
end

return {
	new = new,
}
