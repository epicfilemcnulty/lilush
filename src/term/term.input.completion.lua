-- SPDX-FileCopyrightText: © 2023 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: GPL-3.0-or-later
local std = require("std")

local flush = function(self)
	self.__candidates = {}
	self.__chosen = 0
	self.__meta.replace_args = false
	self.__meta.exec_on_promotion = false
end

local available = function(self)
	if #self.__candidates > 0 then
		if self.__chosen == 0 then
			self.__chosen = 1
		end
		return true
	end
	return false
end

local get = function(self)
	if #self.__candidates > 0 then
		if self.__chosen <= #self.__candidates then
			return self.__candidates[self.__chosen]
		end
	end
	return ""
end

local update = function(self)
	for name, source in pairs(self.__sources) do
		if source.update then
			source:update()
		end
	end
end

local provide = function(self, candidates)
	self.candidates = candidates or {}
end

-- Creates a new instance of a completion object
local new = function(config)
	local default_config = {
		kind = "shell",
		sources = "bin",
	}
	default_config = std.merge_tables(default_config, config)
	if not std.module_available("completion." .. default_config.kind) then
		return nil, "no such completion"
	end
	local compl_kind = require("completion." .. default_config.kind)
	local completion = {
		-- DATA
		__candidates = {},
		__sources = {},
		__chosen = 0,
		__meta = {
			replace_args = false,
			exec_on_promotion = false,
		},
		-- METHODS
		search = compl_kind.search,
		available = available,
		get = get,
		flush = flush,
		update = update,
		provide = provide,
	}
	for source in default_config.sources:gmatch("([%w_]+),?") do
		if not std.module_available("completion.source." .. default_config.kind .. "." .. source) then
			return nil, "no such completion source"
		end
		local s = require("completion.source." .. default_config.kind .. "." .. source)
		completion.__sources[source] = s.new()
	end
	completion:update()
	return completion
end

return { new = new }
