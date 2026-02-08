-- SPDX-FileCopyrightText: © 2022—2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: LicenseRef-OWL-1.0-or-later OR GPL-3.0-or-later
-- Dual-licensed under OWL v1.0+ and GPLv3+. See LICENSE and LICENSE-GPL3.

local std = require("std")
local style = require("term.tss")
local utils = require("shell.utils")
local theme = require("shell.theme")

local tss = style.new(theme.completion)

local search = function(self, input, history)
	self:flush()
	local cmd, args = utils.parse_cmdline(input)
	if #args == 0 then
		if cmd and not cmd:match("^%.") then
			self.__candidates = self.__sources["builtins"]:search(cmd)
			local builtins_count = #self.__candidates
			local candidates = self.__sources["bin"]:search(cmd)
			for _, c in ipairs(candidates) do
				table.insert(self.__candidates, c)
			end
			setmetatable(self.__meta, {
				__index = function(table, key)
					local metadata = { source = "bin" }
					if key <= builtins_count then
						metadata.source = "builtin"
					end
					return metadata
				end,
			})
		end
		if std.escape_magic_chars(cmd):match("^%%%./") then
			self.__candidates = self.__sources["fs"]:search(cmd, nil, "[75]")
			table.sort(self.__candidates, function(a, b)
				if a:match("/$") and not b:match("/$") then
					return false
				elseif b:match("/$") and not a:match("/$") then
					return true
				end
				return a < b
			end)
			local mt = {
				__index = function(t, k)
					return { source = "fs_exe" }
				end,
			}
			setmetatable(self.__meta, mt)
			return self:available()
		end
	end
	if #args > 0 then
		local last_arg = args[#args]
		if cmd:match("^[zx]$") then
			local mt = {
				__index = function(t, k)
					return { source = "dir_history", replace_prompt = "cd", exec_on_prom = true, reduce_spaces = true }
				end,
			}
			if cmd == "z" then
				self.__candidates = history.dir_search(history, args)
			else
				self.__candidates = history.search(history, args)
				mt = {
					__index = function(t, k)
						return { source = "history", replace_prompt = "", exec_on_prom = true, trim_promotion = true }
					end,
				}
			end
			setmetatable(self.__meta, mt)
			return self:available()
		end
		if cmd == "zx" then
			self.__candidates = utils.zx_complete(args)
			setmetatable(self.__meta, {
				__index = function(table, key)
					return { source = "snippet", replace_prompt = cmd, exec_on_prom = true }
				end,
			})
			return self:available()
		end
		if cmd == "cd" then
			self.__candidates = self.__sources["fs"]:search(args[1], "[dl]")
			local mt = {
				__index = function(t, k)
					return { source = "fs" }
				end,
			}
			setmetatable(self.__meta, mt)
			return self:available()
		end
		if cmd == "setenv" or cmd == "unsetenv" then
			self.__candidates = self.__sources["env"]:search(last_arg)
			local mt = {
				__index = function(t, k)
					return { source = "env" }
				end,
			}
			setmetatable(self.__meta, mt)
			return self:available()
		end
		local cmds_source = self.__sources["cmds"]
		local cmds_list = cmds_source.list
		if cmds_source.cfg and cmds_source.cfg.list then
			cmds_list = cmds_source.cfg.list
		end
		if cmds_list and cmds_list[cmd] then
			self.__candidates = cmds_source:search(cmd, args)
			local mt = {
				__index = function(t, k)
					return { source = "cmds" }
				end,
			}
			setmetatable(self.__meta, mt)
			return self:available()
		end
		if std.escape_magic_chars(last_arg):match("^%%%${") then -- because of the escaping we need to use this ugly pattern
			self.__candidates = self.__sources["env"]:search(last_arg)
			local mt = {
				__index = function(t, k)
					return { source = "env" }
				end,
			}
			setmetatable(self.__meta, mt)
			return self:available()
		end
		self.__candidates = self.__sources["fs"]:search(last_arg)
		local mt = {
			__index = function(t, k)
				return { source = "fs" }
			end,
		}
		setmetatable(self.__meta, mt)
	end
	return self:available()
end

local get = function(self, promoted)
	if #self.__candidates > 0 then
		if self.__chosen <= #self.__candidates then
			local variant = self.__candidates[self.__chosen]
			if promoted then
				return variant
			end
			local metadata = self.__meta[self.__chosen]
			return tss:apply(metadata.source, variant).text
		end
	end
	return ""
end

return { search = search, get = get }
