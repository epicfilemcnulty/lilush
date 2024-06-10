-- SPDX-FileCopyrightText: © 2023 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: GPL-3.0-or-later
local std = require("std")
local utils = require("shell.utils")

local update = function(self)
	self.env = std.environ()
end

local environment = function(self, arg)
	local candidates = {}
	local name = arg
	local braces = false

	if std.escape_magic_chars(arg):match("^%%%${") then -- because of the escaping we need to use this ugly pattern
		name = arg:sub(3)
		braces = true
	end

	self:update()
	for e, _ in pairs(self.env) do
		if e:match("^" .. std.escape_magic_chars(name)) then
			local tc = " "
			if braces then
				tc = "} "
			end
			table.insert(candidates, e:sub(#name + 1) .. tc)
		end
	end
	utils.sort_by_smaller_size(candidates)
	return candidates
end

local new = function()
	local source = { update = update, search = environment }
	source:update()
	return source
end

return { new = new }
