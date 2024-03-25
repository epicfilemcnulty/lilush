-- SPDX-FileCopyrightText: © 2023 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: GPL-3.0-or-later
local std = require("std")
local utils = require("shell.utils")

local fs_source = require("shell.completions.sources.fs")
local builtins_source = require("shell.completions.sources.builtins")
local bin_source = require("shell.completions.sources.bin")
local env_source = require("shell.completions.sources.env")
local cmd_source = require("shell.completions.sources.cmds")

local complete = function(self, input)
	self:flush()

	local cmd, args = utils.parse_cmdline(input)
	if cmd and #args == 0 and not cmd:match("^%.") then
		self.variants.candidates = self.sources.builtins:complete(cmd)
		local bins = self.sources.bin:complete(cmd)
		for _, v in ipairs(bins) do
			table.insert(self.variants.candidates, v)
		end
		return self:available()
	end

	if std.escape_magic_chars(cmd):match("^%%%./") and #args == 0 then
		self.variants.candidates = self.sources.fs:complete(cmd, nil, "[75]")
		table.sort(self.variants.candidates, function(a, b)
			if a:match("/$") and not b:match("/$") then
				return false
			elseif b:match("/$") and not a:match("/$") then
				return true
			end
			return a < b
		end)
		return self:available()
	end

	if #args > 0 then
		local arg = args[#args]
		if cmd == "z" then
			self.variants.candidates = self.provided
			self.variants.replace_args = "cd"
			self.variants.exec_on_promotion = true
			self.provided = {}
			return self:available()
		end
		if cmd == "x" then
			self.variants.candidates = self.provided
			self.variants.replace_args = ""
			self.variants.exec_on_promotion = true
			self.provided = {}
			return self:available()
		end
		if cmd == "zx" then
			self.variants.candidates = utils.zx_complete(args)
			self.variants.exec_on_promotion = true
			self.variants.replace_args = "zx"
			return self:available()
		end
		if cmd == "cd" then
			self.variants.candidates = self.sources.fs:complete(arg, "[dl]")
			return self:available()
		end
		if cmd == "setenv" or cmd == "unsetenv" then
			self.variants.candidates = self.sources.env:complete(arg)
			return self:available()
		end

		if self.sources.cmds.list[cmd] then
			self.variants.candidates = self.sources.cmds:complete(cmd, args)
			return self:available()
		end

		if std.escape_magic_chars(arg):match("^%%%${") then -- because of the escaping we need to use this ugly pattern
			self.variants.candidates = self.sources.env:complete(arg)
			return self:available()
		end
		self.variants.candidates = self.sources.fs:complete(arg)
	end
	return self:available()
end

local flush = function(self)
	self.variants.candidates = {}
	self.variants.chosen = 0
	self.variants.replace_args = nil
	self.variants.exec_on_promotion = false
end

local available = function(self)
	if #self.variants.candidates > 0 then
		if self.variants.chosen == 0 then
			self.variants.chosen = 1
		end
		return true
	end
	return false
end

local update = function(self)
	self.sources.env:update()
	self.sources.bin:update()
end

local provide = function(self, candidates)
	self.provided = candidates or {}
end

local new = function()
	local source = {
		sources = {
			fs = fs_source.new(),
			builtins = builtins_source.new(),
			env = env_source.new(),
			bin = bin_source.new(),
			cmds = cmd_source.new(),
		},
		variants = {},
		provided = {},
		complete = complete,
		available = available,
		flush = flush,
		update = update,
		provide = provide,
	}
	source:flush()
	source:update()
	return source
end

return { new = new }
