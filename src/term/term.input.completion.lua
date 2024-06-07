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
	if not config or not config.path then
		return nil, "no config provided"
	end
	if not std.module_available(config.path) then
		return nil, "no such completion module: " .. config.path
	end
	local search_function = require(config.path)
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
		search = search_function,
		available = available,
		get = get,
		flush = flush,
		update = update,
		provide = provide,
	}
	if config.sources then
		for name, path in pairs(config.sources) do
			if not std.module_available(path) then
				return nil, "no such completion source: " .. path
			end
			local s = require(path)
			completion.__sources[name] = s.new()
		end
	end
	completion:update()
	return completion
end

return { new = new }
