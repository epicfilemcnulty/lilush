-- SPDX-FileCopyrightText: © 2022—2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: LicenseRef-OWL-1.0-or-later OR GPL-3.0-or-later
-- Dual-licensed under OWL v1.0+ and GPLv3+. See LICENSE and LICENSE-GPL3.

local json = require("cjson.safe")
local tbl = require("std.tbl")

local LOG_LEVELS = { debug = 0, access = 10, info = 20, warn = 30, error = 40 }

local log = function(self, msg, level)
	level = level or 20
	if type(level) == "string" then
		level = LOG_LEVELS[level] or 20
	end
	if level >= self.cfg.level then
		local log_msg_base = { level = level, ts = os.time() }
		if type(msg) ~= "table" then
			msg = { msg = msg }
		end
		msg = tbl.merge(log_msg_base, msg)
		local log_json = json.encode(msg)
		if level >= self.cfg.to_stderr then
			self.__state.stderr:write(log_json .. "\n")
		else
			self.__state.stdout:write(log_json .. "\n")
		end
		if self.cfg.flush then
			io.flush()
		end
	end
end

local level = function(self)
	return self.cfg.level
end

local level_str = function(self)
	local l_str = tostring(self.cfg.level)
	for name, value in pairs(LOG_LEVELS) do
		if value == self.cfg.level then
			l_str = name
			break
		end
	end
	return l_str
end

local set_level = function(self, level)
	local lvl = level or 20
	if type(lvl) == "string" then
		lvl = LOG_LEVELS[lvl] or 20
	end
	self.cfg.level = lvl
end

local new = function(lvl, to_stderr, stdout, stderr)
	-- Log messages with level higher than
	-- `to_stderr` to stderr
	stdout = stdout or io.stdout
	stderr = stderr or io.stderr
	to_stderr = to_stderr or 100
	lvl = lvl or 20
	if type(lvl) == "string" then
		lvl = LOG_LEVELS[lvl] or 20
	end
	local logger = {
		cfg = {
			to_stderr = to_stderr,
			level = lvl,
			flush = true,
		},
		__state = {
			stdout = stdout,
			stderr = stderr,
		},
		log = log,
		level = level,
		level_str = level_str,
		set_level = set_level,
	}
	return logger
end

return { new = new }
