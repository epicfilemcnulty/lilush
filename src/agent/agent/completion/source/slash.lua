-- SPDX-FileCopyrightText: © 2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: OWL-1.0 or later
-- Licensed under the Open Weights License v1.0. See LICENSE for details.

local std = require("std")

local sort_candidates = function(values)
	table.sort(values, function(a, b)
		if #a == #b then
			return a < b
		end
		return #a < #b
	end)
	return values
end

local normalize_list = function(values)
	if type(values) ~= "table" then
		return {}
	end

	local out = {}
	local seen = {}

	for _, value in ipairs(values) do
		if type(value) == "string" and value ~= "" and not seen[value] then
			seen[value] = true
			out[#out + 1] = value
		end
	end

	for key, value in pairs(values) do
		local candidate = nil
		if type(key) == "string" then
			candidate = key
		elseif type(value) == "string" then
			candidate = value
		end
		if candidate and candidate ~= "" and not seen[candidate] then
			seen[candidate] = true
			out[#out + 1] = candidate
		end
	end

	return sort_candidates(out)
end

local filter_prefix = function(values, prefix)
	local out = {}
	local escaped_prefix = std.escape_magic_chars(prefix or "")
	for _, value in ipairs(values) do
		if value:match("^" .. escaped_prefix) then
			out[#out + 1] = value
		end
	end
	return sort_candidates(out)
end

local provider_result = function(self, provider_name, ...)
	local ctx = self.__state.ctx or {}
	local provider = ctx[provider_name]
	if type(provider) == "function" then
		local ok, result = pcall(provider, ...)
		if ok then
			return normalize_list(result)
		end
		return {}
	end
	if type(provider) == "table" then
		return normalize_list(provider)
	end
	return {}
end

local update = function(self, ctx)
	self.__state.ctx = ctx or {}
end

local commands = function(self, prefix)
	local values = provider_result(self, "list_commands")
	if #values == 0 then
		values = normalize_list(self.cfg.default_commands)
	end
	return filter_prefix(values, prefix)
end

local providers = function(self, prefix)
	return filter_prefix(provider_result(self, "list_providers"), prefix)
end

local current_provider = function(self)
	local ctx = self.__state.ctx or {}
	local provider = ctx.get_provider
	if type(provider) == "function" then
		local ok, value = pcall(provider)
		if ok and type(value) == "string" and value ~= "" then
			return value
		end
	elseif type(provider) == "string" and provider ~= "" then
		return provider
	end
	return nil
end

local models = function(self, provider_name, prefix)
	local values = provider_result(self, "list_models", provider_name)
	return filter_prefix(values, prefix)
end

local prompt_subcommands = function(self, prefix)
	return filter_prefix(normalize_list(self.cfg.prompt_subcommands), prefix)
end

local prompts = function(self, prefix)
	return filter_prefix(provider_result(self, "list_prompts"), prefix)
end

local saved_conversations = function(self, prefix)
	return filter_prefix(provider_result(self, "list_saved_conversations"), prefix)
end

local new = function(config)
	local cfg = {
		default_commands = {},
		prompt_subcommands = { "clear", "list", "set", "show" },
	}
	if config then
		std.tbl.merge(cfg, config)
	end

	return {
		cfg = cfg,
		__state = {
			ctx = {},
		},
		update = update,
		commands = commands,
		providers = providers,
		current_provider = current_provider,
		models = models,
		prompt_subcommands = prompt_subcommands,
		prompts = prompts,
		saved_conversations = saved_conversations,
	}
end

return {
	new = new,
}
