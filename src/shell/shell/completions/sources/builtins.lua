-- SPDX-FileCopyrightText: © 2023 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: GPL-3.0-or-later
local std = require("std")
local utils = require("shell.utils")

local update = function(self, aliases)
	local aliases = aliases or {}
	self.aliases = aliases
end

local complete = function(self, cmd)
	local candidates = {}
	for name in pairs(self.builtins) do
		if name:match("^" .. std.escape_magic_chars(cmd)) then
			table.insert(candidates, name:sub(#cmd + 1) .. " ")
		end
	end
	for name in pairs(self.aliases) do
		if name:match("^" .. std.escape_magic_chars(cmd)) then
			table.insert(candidates, name:sub(#cmd + 1) .. " ")
		end
	end
	utils.sort_by_smaller_size(candidates)
	return candidates
end

local new = function()
	local source = {
		update = update,
		complete = complete,
		builtins = {
			alias = true,
			unalias = true,
			activate = true,
			deactivate = true,
			cd = true,
			mkdir = true,
			files_matching = true,
			kat = true,
			notify = true,
			history = true,
			netstat = true,
			export = true,
			setenv = true,
			unsetenv = true,
			zx = true,
			ls = true,
			rm = true,
			rmrf = true,
			envlist = true,
			exec = true,
			["ssh.profile"] = true,
			["aws.region"] = true,
			["aws.profile"] = true,
			ktl = true,
			dig = true,
			digg = true,
			rehash = true,
			run_script = true,
		},
		aliases = {},
	}
	return source
end

return { new = new }
