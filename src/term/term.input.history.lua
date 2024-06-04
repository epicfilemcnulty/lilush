-- SPDX-FileCopyrightText: © 2023 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: GPL-3.0-or-later
local std = require("std")
local json = require("cjson.safe")

local history_add = function(self, entry)
	if #entry > 0 and not entry:match("^ ") then
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

local search = function(self, input)
	local p = input:find("%s")
	local cmd = input:sub(1, p)
	local args_str = input:sub(p)
	local pattern = ".-"
	for arg in args_str:gmatch("%S+") do
		pattern = pattern .. std.escape_magic_chars(arg) .. ".-"
	end

	local scores = {}
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

local dir_search = function(self, input)
	local p = input:find("%s")
	local cmd = input:sub(1, p)
	local args_str = input:sub(p)
	local pattern = ".-"
	for arg in args_str:gmatch("%S+") do
		pattern = pattern .. std.escape_magic_chars(arg) .. ".-"
	end

	local scores = {}
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
		add = history_add,
		get = history_get,
		up = history_up,
		down = history_down,
		stash = history_stash,
		load = load_history,
		search = search,
		dir_search = dir_search,
	}
	history:load()
	return history
end

return { new = new }
