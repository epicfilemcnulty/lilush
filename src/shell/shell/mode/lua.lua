-- SPDX-FileCopyrightText: © 2023-2024 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: GPL-3.0-or-later
local term = require("term")
local std = require("std")
local theme = require("shell.theme")
local style = require("term.tss")
local tss = style.new(theme)

local combos = {}

local preload = [[
    local std = require("std")
    local djot = require("djot")
    local web = require("web")
    local redis = require("redis")
    local crypto = require("crypto")
    local json = require("cjson.safe")
    local term = require("term")
    local dig = require("dns.dig")
    local wg = require("wireguard")
]]

local run = function(self)
	local code = self.input:render()
	local chunk, err = load(preload .. code)
	local status = 0
	if chunk then
		term.write(tss:apply("modes.lua.sep") .. "\n")
		local cwd = std.fs.cwd()
		std.ps.setenv("LILUSH_EXEC_CWD", cwd)
		std.ps.setenv("LILUSH_EXEC_START", os.time())
		local status, err = pcall(chunk)
		term.write(tss:apply("modes.lua.sep") .. "\n")
		std.ps.setenv("LILUSH_EXEC_END", os.time())
		if not status then
			std.ps.setenv("LILUSH_EXEC_STATUS", 255)
			return 255, err:match("^[^:]+:%d+:(.*)") or err
		end
		std.ps.setenv("LILUSH_EXEC_STATUS", 0)
	else
		std.ps.setenv("LILUSH_EXEC_STATUS", 255)
		return 255, err:match("^[^:]+:%d+:(.*)") or err
	end
	return 0
end

local new = function(input)
	local mode = {
		input = input,
		combos = {},
		run = run,
	}
	return mode
end

return { new = new }
