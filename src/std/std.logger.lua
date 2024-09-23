-- SPDX-FileCopyrightText: © 2023 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: GPL-3.0-or-later

local json = require("cjson.safe")
local tbl = require("std.tbl")

local log_levels = { debug = 0, access = 10, info = 20, warn = 30, error = 40 }

local log = function(self, msg, level)
	local level = level or 20
	if type(level) == "string" then
		level = log_levels[level] or 20
	end
	if level >= self.__config.level then
		local log_msg_base = { level = level, ts = os.time() }
		if type(msg) ~= "table" then
			msg = { msg = msg }
		end
		msg = tbl.merge(log_msg_base, msg)
		local log_json = json.encode(msg)
		print(log_json)
		-- Not flushing immediately probably would've been
		-- better for high load, but in that case you'd better disable
		-- access log entirely.
		io.flush()
	end
end

local level = function(self)
	return self.__config.level
end

local level_str = function(self)
	local l_str = tostring(self.__config.level)
	for name, value in pairs(log_levels) do
		if value == self.__config.level then
			l_str = name
			break
		end
	end
	return l_str
end

local set_level = function(self, level)
	local lvl = level or 20
	if type(lvl) == "string" then
		lvl = log_levels[lvl] or 20
	end
	self.__config.level = lvl
end

local new = function(lvl)
	local lvl = lvl or 20
	if type(lvl) == "string" then
		lvl = log_levels[lvl] or 20
	end
	local logger = {
		__config = {
			level = lvl,
		},
		log = log,
		level = level,
		level_str = level_str,
		set_level = set_level,
	}
	return logger
end

return { new = new }
