-- SPDX-FileCopyrightText: © 2022—2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: LicenseRef-OWL-1.0-or-later OR GPL-3.0-or-later
-- Dual-licensed under OWL v1.0+ and GPLv3+. See LICENSE and LICENSE-GPL3.

local std = require("std")

local update = function(self)
	self.__state.env = std.environ()
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
	for e, _ in pairs(self.__state.env) do
		if e:match("^" .. std.escape_magic_chars(name)) then
			local tc = " "
			if braces then
				tc = "} "
			end
			table.insert(candidates, e:sub(#name + 1) .. tc)
		end
	end
	std.tbl.sort_by_str_len(candidates)
	return candidates
end

local new = function(config)
	local source = {
		cfg = config or {},
		__state = {
			env = {},
		},
		update = update,
		search = environment,
	}
	source:update()
	return source
end

return { new = new }
