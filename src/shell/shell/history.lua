-- SPDX-FileCopyrightText: © 2023 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: GPL-3.0-or-later
local std = require("std")
local utils = require("shell.utils")
local json = require("cjson.safe")

local history_add = function(self, entry)
	if #entry > 0 and not entry:match("^ ") then
		local cmd, args = utils.parse_cmdline(entry)
		if #self.args < 5 then
			table.insert(self.args, args)
		else
			table.remove(self.args, 1)
			table.insert(self.args, args)
		end
		self.arg_position = #self.args

		-- Gotta find a better way to handle this, the list is getting bigger O_o
		if cmd == "z" or (cmd:match("^l[stl]$") and #args == 0) or cmd:match("^%.%.+") or cmd:match("^bm.") then
			return false
		end
		local last = ""
		if #self.entries > 0 then
			last = self.entries[#self.entries]
		end

		local env = std.environ()
		local start_ts = tonumber(env["LILUSH_EXEC_START"]) or os.time()
		local end_ts = tonumber(env["LILUSH_EXEC_END"]) or os.time()
		local status = tonumber(env["LILUSH_EXEC_STATUS"]) or 111
		local duration = end_ts - start_ts
		local cwd = std.cwd()
		local home = env["HOME"]
		cwd = cwd:gsub("^" .. home, "~")
		local payload = { cmd = entry, ts = start_ts, d = duration, cwd = cwd, exit = status }
		table.insert(self.entries, payload)
		if self.store then
			self.store:add_set_member("history/" .. self.mode, payload, payload.ts, true)
		end
		self.position = 0
		return true
	end
	return false
end

local history_get_last_arg = function(self)
	if self.arg_position > 0 then
		local count = #self.args[self.arg_position]
		local arg = self.args[self.arg_position][count]
		self.arg_position = self.arg_position - 1
		if self.arg_position == 0 then
			self.arg_position = #self.args
		end
		return arg
	end
	return ""
end

local history_stash = function(self, entry)
	self.stashed = entry
end

local history_get = function(self)
	if self.position == 0 then
		local stashed = self.stashed
		self.stashed = ""
		return stashed
	else
		return self.entries[self.position].cmd
	end
end

local history_up = function(self)
	if #self.entries > 0 then
		if self.position == 0 then
			self.position = #self.entries
			return true
		end
		local cmd = self.entries[self.position].cmd
		while self.position > 1 do
			self.position = self.position - 1
			if self.entries[self.position].cmd ~= cmd then
				break
			end
			cmd = self.entries[self.position].cmd
		end
		return true
	end
	return false
end

local history_down = function(self)
	if self.position > 0 then
		if self.position == #self.entries then
			self.position = 0
		else
			local cmd = self.entries[self.position].cmd
			while self.position < #self.entries do
				self.position = self.position + 1
				if self.entries[self.position].cmd ~= cmd then
					break
				end
				cmd = self.entries[self.position].cmd
			end
		end
		return true
	end
	return false
end

local load_history = function(self)
	if self.store then
		local res, err = self.store:get_set_range("history/" .. self.mode, 0, -1)
		if err then
			return nil, "can't get history: " .. tostring(err)
		end
		local history = {}
		for i, v in ipairs(res) do
			local entry = json.decode(v)
			if entry then
				history[i] = entry
			end
		end
		self.entries = history
	end
end

local completions = function(self, input)
	local cmd, args = utils.parse_cmdline(input)
	local scores = {}
	local pattern = ".-"
	for _, arg in ipairs(args) do
		pattern = pattern .. std.escape_magic_chars(arg) .. ".-"
	end

	local cwd = std.cwd()
	local home = os.getenv("HOME") or ""
	cwd = cwd:gsub("^" .. home, "~")

	for i, v in ipairs(self.entries) do
		if v.cmd:match(pattern) then
			local score = scores[v.cmd] or 0
			score = score + 1
			if v.cwd == cwd then
				score = score + 2
			end
			if v.exit ~= 0 then
				score = score - 1
			end
			scores[v.cmd] = score
		end
	end
	local candidates = {}
	for k, v in pairs(scores) do
		table.insert(candidates, k)
	end
	table.sort(candidates, function(a, b)
		if scores[a] == scores[b] then
			return a > b
		else
			return scores[a] > scores[b]
		end
	end)
	for i, c in ipairs(candidates) do
		candidates[i] = " " .. c
	end
	return candidates
end

local dir_completions = function(self, input)
	local cmd, args = utils.parse_cmdline(input)
	local scores = {}
	local pattern = ".-"
	for _, arg in ipairs(args) do
		pattern = pattern .. std.escape_magic_chars(arg) .. ".-"
	end

	for i, v in ipairs(self.entries) do
		if v.cwd:match(pattern) then
			local score = scores[v.cwd] or 0
			score = score + 1
			scores[v.cwd] = score
		end
	end

	local candidates = {}
	for k, v in pairs(scores) do
		table.insert(candidates, k)
	end
	table.sort(candidates, function(a, b)
		if scores[a] == scores[b] then
			return a > b
		else
			return scores[a] > scores[b]
		end
	end)
	for i, c in ipairs(candidates) do
		candidates[i] = " " .. c
	end
	return candidates
end

local new = function(mode, store)
	local history = {
		store = store,
		entries = {},
		position = 0,
		stashed = "",
		mode = mode,
		args = {},
		arg_position = 0,
		add = history_add,
		get = history_get,
		get_last_arg = history_get_last_arg,
		up = history_up,
		down = history_down,
		stash = history_stash,
		load = load_history,
		completions = completions,
		dir_completions = dir_completions,
	}
	history:load()
	return history
end

return { new = new }
