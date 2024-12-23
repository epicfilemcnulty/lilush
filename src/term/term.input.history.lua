-- SPDX-FileCopyrightText: © 2023 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: GPL-3.0-or-later
local std = require("std")

local history_add = function(self, entry)
	if #entry > 0 and not entry:match("^ ") and not entry:match("^%.%.+") then
		local env = std.environ()
		local start_ts = tonumber(env["LILUSH_EXEC_START"]) or os.time()
		local end_ts = tonumber(env["LILUSH_EXEC_END"]) or os.time()
		local status = tonumber(env["LILUSH_EXEC_STATUS"]) or 111
		local duration = end_ts - start_ts
		local cwd = std.fs.cwd()
		local home = env["HOME"]
		cwd = cwd:gsub("^" .. home, "~")
		local payload = { cmd = entry, ts = start_ts, d = duration, cwd = cwd, exit = status }
		table.insert(self.entries, payload)
		if self.store then
			self.store:save_history_entry(self.mode, payload)
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
		local entries, err = self.store:load_history(self.mode)
		if err then
			return nil, "can't get history: " .. tostring(err)
		end
		self.entries = entries
		self.store:close()
	end
end

local search = function(self, input)
	local pattern = ".-"
	for _, arg in ipairs(input) do
		pattern = pattern .. std.escape_magic_chars(arg) .. ".-"
	end

	local scores = {}
	local cwd = std.fs.cwd()
	local home = os.getenv("HOME") or ""
	cwd = cwd:gsub("^" .. home, "~")

	for _, v in ipairs(self.entries) do
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
	for k, _ in pairs(scores) do
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
	local pattern = ".-"
	for _, arg in ipairs(input) do
		pattern = pattern .. std.escape_magic_chars(arg) .. ".-"
	end

	local scores = {}
	for _, v in ipairs(self.entries) do
		if v.cwd:match(pattern) then
			local score = scores[v.cwd] or 0
			score = score + 1
			local pattern_len = std.utf.len(pattern)
			local cwd_len = std.utf.len(v.cwd)
			score = score + pattern_len / (cwd_len / 100) -- trying to favor smaller matches this way
			scores[v.cwd] = score
		end
	end

	local candidates = {}
	for k, _ in pairs(scores) do
		table.insert(candidates, k)
	end
	table.sort(candidates, function(a, b)
		if scores[a] == scores[b] then
			return std.utf.len(a) < std.utf.len(b)
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
