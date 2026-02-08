-- SPDX-FileCopyrightText: © 2022—2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: LicenseRef-OWL-1.0-or-later OR GPL-3.0-or-later
-- Dual-licensed under OWL v1.0+ and GPLv3+. See LICENSE and LICENSE-GPL3.

local std = require("std")

local update = function(self, aliases)
	self.__state.aliases = aliases or {}
end

local search = function(self, cmd)
	local candidates = {}
	for name in pairs(self.cfg.builtins) do
		if name:match("^" .. std.escape_magic_chars(cmd)) then
			table.insert(candidates, name:sub(#cmd + 1) .. " ")
		end
	end
	for name in pairs(self.__state.aliases) do
		if name:match("^" .. std.escape_magic_chars(cmd)) then
			table.insert(candidates, name:sub(#cmd + 1) .. " ")
		end
	end
	std.tbl.sort_by_str_len(candidates)
	return candidates
end

local new = function(config)
	local source = {
		cfg = {
			builtins = {
				alias = true,
				unalias = true,
				pyvenv = true,
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
				wgcli = true,
				rm = true,
				rmrf = true,
				envlist = true,
				exec = true,
				["ssh.profile"] = true,
				["aws.region"] = true,
				["aws.profile"] = true,
				["ktl.profile"] = true,
				ktl = true,
				dig = true,
				digg = true,
				rehash = true,
				run_script = true,
				job = true,
				zxscr = true,
			},
		},
		__state = {
			aliases = {},
		},
		update = update,
		search = search,
	}
	if config then
		std.tbl.merge(source.cfg, config)
	end
	return source
end

return { new = new }
