-- SPDX-FileCopyrightText: © 2023 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: GPL-3.0-or-later

local std = require("std")

local get = function(self)
	return self.prompt
end

local set = function(self, options)
	for k, v in pairs(options) do
		self[k] = v
	end
end

local new = function(prompt_module_name)
	if type(prompt_module_name) == "string" then
		if prompt_module_name == "default" then
			return { prompt = "$ ", get = get, set = set }
		end
		if std.module_available(prompt_module_name) then
			local prompt = require(prompt_module_name)
			return prompt
		end
	end
	return nil
end

return { new = new }
