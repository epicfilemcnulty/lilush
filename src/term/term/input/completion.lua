-- SPDX-FileCopyrightText: © 2022—2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: LicenseRef-OWL-1.0-or-later OR GPL-3.0-or-later
-- Dual-licensed under OWL v1.0+ and GPLv3+. See LICENSE and LICENSE-GPL3.

local std = require("std")
local style = require("term.tss")

local rss = {
	default = { fg = 247 },
}
local tss = style.new(rss)

local sync_from_legacy = function(self)
	if self.__candidates ~= self.__state.candidates then
		self.__state.candidates = self.__candidates or {}
	end
	if self.__sources ~= self.__state.sources then
		self.__state.sources = self.__sources or {}
	end
	if self.__meta ~= self.__state.meta then
		self.__state.meta = self.__meta or {}
	end
	if self.__chosen ~= self.__state.chosen then
		self.__state.chosen = self.__chosen or 0
	end
end

local sync_to_legacy = function(self)
	self.__candidates = self.__state.candidates
	self.__sources = self.__state.sources
	self.__meta = self.__state.meta
	self.__chosen = self.__state.chosen
end

local flush = function(self)
	sync_from_legacy(self)
	self.__state.candidates = {}
	self.__state.chosen = 0
	self.__state.meta = {
		replace_args = false,
		exec_on_prom = false,
	}
	sync_to_legacy(self)
end

local available = function(self)
	sync_from_legacy(self)
	if #self.__state.candidates > 0 then
		if self.__state.chosen == 0 then
			self.__state.chosen = 1
			sync_to_legacy(self)
		end
		return true
	end
	return false
end

local count = function(self)
	sync_from_legacy(self)
	return #self.__state.candidates
end

local chosen_index = function(self)
	sync_from_legacy(self)
	return self.__state.chosen
end

local set_chosen_index = function(self, idx)
	sync_from_legacy(self)
	if type(idx) ~= "number" then
		return
	end
	local total = #self.__state.candidates
	if total == 0 then
		self.__state.chosen = 0
	else
		idx = math.floor(idx)
		if idx < 1 then
			idx = 1
		elseif idx > total then
			idx = total
		end
		self.__state.chosen = idx
	end
	sync_to_legacy(self)
end

local meta_at = function(self, idx)
	sync_from_legacy(self)
	return self.__state.meta[idx]
end

local source = function(self, name)
	sync_from_legacy(self)
	return self.__state.sources[name]
end

local get = function(self, promoted)
	sync_from_legacy(self)
	if #self.__state.candidates > 0 then
		local idx = self.__state.chosen
		if idx <= #self.__state.candidates and idx > 0 then
			local variant = self.__state.candidates[idx]
			if promoted then
				return variant
			end
			return tss:apply("default", variant).text
		end
	end
	return ""
end

local update = function(self)
	sync_from_legacy(self)
	for _, src in pairs(self.__state.sources) do
		if src.update then
			src:update()
		end
	end
end

local provide = function(self, candidates)
	sync_from_legacy(self)
	self.__state.candidates = candidates or {}
	local total = #self.__state.candidates
	if total == 0 then
		self.__state.chosen = 0
	elseif self.__state.chosen > total then
		self.__state.chosen = total
	end
	sync_to_legacy(self)
end

local set_meta = function(self, metadata)
	sync_from_legacy(self)
	self.__state.meta = metadata or {}
	sync_to_legacy(self)
end

-- Creates a new instance of a completion object
local new = function(config)
	if not config or not config.path then
		return nil, "no config provided"
	end
	if not std.module_available(config.path) then
		return nil, "no such completion module: " .. config.path
	end
	local mod = require(config.path)

	local completion = {
		cfg = config,
		__state = {
			candidates = {},
			sources = {},
			chosen = 0,
			meta = {},
		},
		-- Legacy aliases kept for compatibility with completion provider modules.
		__candidates = nil,
		__sources = nil,
		__chosen = 0,
		-- meta provides metadata for a candidate at the same index.
		-- It must provide the name of the source for each candidate,
		-- and may provide additional information
		__meta = nil,
		-- METHODS
		search = mod.search,
		available = available,
		count = count,
		chosen_index = chosen_index,
		set_chosen_index = set_chosen_index,
		meta_at = meta_at,
		source = source,
		get = mod.get or get,
		flush = flush,
		update = update,
		provide = provide,
		set_meta = set_meta,
	}
	sync_to_legacy(completion)

	if config.sources then
		for _, path in ipairs(config.sources) do
			if not std.module_available(path) then
				return nil, "no such completion source: " .. path
			end
			local s = require(path)
			local name = path:match("[^.]+$")
			completion.__state.sources[name] = s.new()
		end
	end
	completion:update()
	return completion
end

return { new = new }
