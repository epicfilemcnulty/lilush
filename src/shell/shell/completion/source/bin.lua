-- SPDX-FileCopyrightText: © 2022—2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: LicenseRef-OWL-1.0-or-later OR GPL-3.0-or-later
-- Dual-licensed under OWL v1.0+ and GPLv3+. See LICENSE and LICENSE-GPL3.

local std = require("std")

local update = function(self)
	local binaries = self.__state.binaries or self.binaries or {}
	for name, _ in pairs(binaries) do
		binaries[name] = nil
	end

	local path = os.getenv("PATH")
	if path then
		for dir in path:gmatch("([^:]+):?") do
			local files, err = std.fs.list_files(dir, nil, "[fl]")
			if files then
				for f, stat in pairs(files) do
					if stat.perms:match("[75]") then
						binaries[f] = true
					end
				end
			end
		end
	end
	self.__state.binaries = binaries
	self.binaries = binaries
end

local search = function(self, cmd)
	local candidates = {}
	for name in pairs(self.__state.binaries or self.binaries or {}) do
		if name:match("^" .. std.escape_magic_chars(cmd)) then
			table.insert(candidates, name:sub(#cmd + 1) .. " ")
		end
	end
	std.tbl.sort_by_str_len(candidates)
	return candidates
end

local new = function(config)
	local source = {
		cfg = config or {},
		__state = {
			binaries = {},
		},
		binaries = {},
		update = update,
		search = search,
	}
	source.binaries = source.__state.binaries
	source:update()
	return source
end

return { new = new }
