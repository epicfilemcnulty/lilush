-- SPDX-FileCopyrightText: © 2023 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: GPL-3.0-or-later
local std = require("std")

local filesystem = function(self, arg, filter, perms)
	local filter = filter or "[fdl]" -- by default we match dirs, regular files and links
	local perms = perms or "." -- any permissions will do by default

	local dirs = {}
	local links = {}
	local files = {}
	local candidates = {}

	local esc_arg = std.escape_magic_chars(arg)
	local dir, file = esc_arg:match("^(.*/)([^/]-)$")
	if not dir then
		dir = "."
		file = esc_arg
	else
		dir = dir:gsub("%%", "") -- unescape possible dots in the dir name
	end

	local dir_files = std.fs.list_files(dir, ".*", filter, true)
	if dir_files then
		for f, stat in pairs(dir_files) do
			if f:match("^" .. file) and stat.perms:match(perms) then
				local unesc_file = file:gsub("%%", "")
				if stat.mode == "d" then
					table.insert(dirs, std.utf.sub(f, std.utf.len(unesc_file) + 1) .. "/")
				elseif stat.mode == "l" then
					local trailing = " "
					if stat.target then
						local target = stat.target
						if not target:match("^/") then
							target = dir .. "/" .. target
						end
						local st = std.fs.stat(target)
						if st and st.mode == "d" then
							trailing = "/"
						end
					end
					table.insert(links, std.utf.sub(f, std.utf.len(unesc_file) + 1) .. trailing)
				else
					table.insert(files, std.utf.sub(f, std.utf.len(unesc_file) + 1) .. " ")
				end
			end
		end
	end
	candidates = std.tbl.sort_by_str_len(dirs)
	links = std.tbl.sort_by_str_len(links)
	files = std.tbl.sort_by_str_len(files)
	for _, v in ipairs(files) do
		table.insert(candidates, v)
	end
	for _, v in ipairs(links) do
		table.insert(candidates, v)
	end
	return candidates
end

local update = function(self)
	return nil
end

local new = function()
	return { search = filesystem, update = update }
end

return { new = new }
