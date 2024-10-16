-- SPDX-FileCopyrightText: © 2023 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: GPL-3.0-or-later
local core = require("std.core")
local buffer = require("string.buffer")

local utf = require("std.utf")
local ps = require("std.ps")
local fs = require("std.fs")
local tbl = require("std.tbl")
local txt = require("std.txt")
local conv = require("std.conv")
local mime = require("std.mime")
local logger = require("std.logger")

local function sleep(seconds)
	core.sleep(seconds)
end

local function sleep_ms(milliseconds)
	core.sleep_ms(milliseconds)
end

local system_users = function()
	local passwd_raw, err = fs.read_file("/etc/passwd")
	local users = {}
	if passwd_raw then
		for line in passwd_raw:gmatch("(.-)\n") do
			local user, uid, gid = line:match("^([^:]+):x:([^:]+):([^:]+)")
			if user and uid and gid then
				users[tonumber(uid)] = { login = user, gid = tonumber(gid) }
			end
		end
	end
	setmetatable(users, {
		__index = function(tbl, key)
			return { login = "unknown", gid = "unknown" }
		end,
	})
	return users
end

local function envsubst(filename)
	local content, err = fs.read_file(filename)
	if content then
		-- txt.template uses std.environ() as the substitute table
		-- and `${[^}]+}` as the pattern by default
		return txt.template(content)
	end
	return nil, err
end

local escape_magic_chars = function(str)
	-- escape all possible magic characters that are used in Lua string patterns
	return str:gsub("[+*%%%.%$[%]%?%(%)-]", "%%%1")
end

local function salt(length)
	math.randomseed(os.time())
	local length = length or 16
	local salt = buffer.new()
	for i = 1, length do
		salt:put(string.char(math.random(255)))
	end
	return salt:get()
end

local function uuid()
	math.randomseed(os.time())
	local template = "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"
	return string.gsub(template, "[xy]", function(c)
		local v = (c == "x") and math.random(0, 0xf) or math.random(8, 0xb)
		return string.format("%x", v)
	end)
end

local function module_available(name)
	if package.loaded[name] then
		return true
	else
		for _, searcher in ipairs(package.searchers or package.loaders) do
			local loader = searcher(name)
			if type(loader) == "function" then
				package.preload[name] = loader
				return true
			end
		end
		return false
	end
end

local function environ()
	local env = {}
	local strings = core.environ()
	for i, s in ipairs(strings) do
		local name = s:match("^([^=]+)")
		local value = s:match("^[^=]+=(.*)")
		env[name] = value
	end
	return env
end

local progress_icons = { "⣿", "⣗", "⡯", "⣦", "⣢", "⣲", "⣶", "⣮", "⣦", "⢿", "⡟", "⣤" }
local progress_icon = function()
	local pid = ps.launch({
		name = "progress_bar",
		func = function(cmd, args)
			while true do
				for _, icon in ipairs(progress_icons) do
					io.write(icon)
					io.flush()
					sleep_ms(200)
					io.write("\b \b")
					io.flush()
				end
			end
		end,
	}, nil, nil, nil)
	return {
		stop = function()
			ps.kill(pid, 9)
			ps.wait(pid)
			io.write("\b \b")
			io.flush()
		end,
	}
end

local std = {
	utf = utf,
	tbl = tbl,
	fs = fs,
	ps = ps,
	conv = conv,
	mime = mime,
	logger = logger,
	txt = txt,
	environ = environ,
	clockticks = core.clockticks,
	sleep = sleep,
	sleep_ms = sleep_ms,
	module_available = module_available,
	envsubst = envsubst,
	escape_magic_chars = escape_magic_chars,
	uuid = uuid,
	salt = salt,
	system_users = system_users,
	progress_icon = progress_icon,
}
return std
