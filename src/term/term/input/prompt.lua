-- SPDX-FileCopyrightText: © 2022—2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: LicenseRef-OWL-1.0-or-later OR GPL-3.0-or-later
-- Dual-licensed under OWL v1.0+ and GPLv3+. See LICENSE and LICENSE-GPL3.

local std = require("std")

local sync_from_legacy = function(self)
	if self.prompt ~= self.__state.prompt then
		self.__state.prompt = self.prompt or ""
	end
	if self.blocks ~= self.__state.blocks then
		self.__state.blocks = self.blocks or {}
	end
end

local sync_to_legacy = function(self)
	self.prompt = self.__state.prompt
	self.blocks = self.__state.blocks
end

local get = function(self)
	sync_from_legacy(self)
	return self.__state.prompt
end

local set = function(self, options)
	sync_from_legacy(self)
	for k, v in pairs(options) do
		self.__state[k] = v
	end
	sync_to_legacy(self)
end

local get_blocks = function(self)
	sync_from_legacy(self)
	return self.__state.blocks
end

local set_blocks = function(self, new_blocks)
	sync_from_legacy(self)
	self.__state.blocks = new_blocks or {}
	sync_to_legacy(self)
end

local new = function(prompt_module_name)
	if type(prompt_module_name) == "string" then
		if prompt_module_name == "default" then
			local prompt = {
				cfg = { module_name = "default" },
				__state = { prompt = "$ ", blocks = {} },
				prompt = "$ ",
				blocks = {},
				get = get,
				set = set,
				get_blocks = get_blocks,
				set_blocks = set_blocks,
			}
			return prompt
		end
		if std.module_available(prompt_module_name) then
			local prompt = require(prompt_module_name)
			return prompt.new()
		end
	end
	return nil
end

return { new = new }
