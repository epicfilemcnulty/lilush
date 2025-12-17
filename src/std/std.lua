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

--[[

    Some of the module's functions make use of `math.random`,
    but it's user's responsibility to properly initialize random
    generator with something like `math.randomseed(os.time())`...

]]

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
			return { login = "unknown", gid = -1 }
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
	str = str or ""
	-- escape all possible magic characters that are used in Lua string patterns
	return str:gsub("[+*%%%.%$[%]%?%(%)-]", "%%%1")
end

local function salt(length)
	length = length or 16
	local salt = buffer.new()
	for i = 1, length do
		-- we intentionally exclude 0 here
		salt:put(string.char(math.random(255)))
	end
	return salt:get()
end

local function uuid()
	local template = "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"
	return string.gsub(template, "[xy]", function(c)
		local v = (c == "x") and math.random(0, 0xf) or math.random(8, 0xb)
		return string.format("%x", v)
	end)
end

-- port of https://github.com/ai/nanoid, seems a nice thing to have,
-- UUIDs are ugly fucks to look at, I'll give ya that...

local function nanoid(length)
	local charset = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ-_"
	length = length or 21
	local id = ""
	for i = 1, length do
		local rand = math.random(64)
		local char = charset:sub(rand, rand)
		id = id .. char
	end
	return id
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
		if name then
			env[name] = value
		end
	end
	return env
end

local hostname = function()
	local name = fs.read_file("/etc/hostname") or ""
	name = name:gsub("\n", "")
	return name
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
	create_shm = core.create_shm,
	sleep = sleep,
	sleep_ms = sleep_ms,
	module_available = module_available,
	envsubst = envsubst,
	escape_magic_chars = escape_magic_chars,
	uuid = uuid,
	nanoid = nanoid,
	salt = salt,
	system_users = system_users,
	hostname = hostname,
	progress_icon = progress_icon,
	pack3d = core.pack3d,
	unpack3d = core.unpack3d,
}
return std
