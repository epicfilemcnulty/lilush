-- SPDX-FileCopyrightText: © 2023 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: GPL-3.0-or-later
local std = require("std")
local utils = require("shell.utils")

local update = function(self)
	self.binaries = {}

	local path = os.getenv("PATH")
	if path then
		for dir in path:gmatch("([^:]+):?") do
			local files, err = std.fs.list_files(dir, nil, "[fl]")
			if files then
				for f, stat in pairs(files) do
					if stat.perms:match("[75]") then
						self.binaries[f] = true
					end
				end
			end
		end
	end
end

local search = function(self, cmd)
	local candidates = {}
	for name in pairs(self.binaries) do
		if name:match("^" .. std.escape_magic_chars(cmd)) then
			table.insert(candidates, name:sub(#cmd + 1) .. " ")
		end
	end
	utils.sort_by_smaller_size(candidates)
	return candidates
end

local new = function()
	local source = { update = update, search = search }
	source:update()
	return source
end

return { new = new }
