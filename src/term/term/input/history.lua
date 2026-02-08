-- SPDX-FileCopyrightText: © 2022—2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: LicenseRef-OWL-1.0-or-later OR GPL-3.0-or-later
-- Dual-licensed under OWL v1.0+ and GPLv3+. See LICENSE and LICENSE-GPL3.

local std = require("std")

local sync_from_legacy = function(self)
	if self.entries ~= self.__state.entries then
		self.__state.entries = self.entries or {}
	end
	if self.position ~= self.__state.position then
		self.__state.position = self.position or 0
	end
	if self.stashed ~= self.__state.stashed then
		self.__state.stashed = self.stashed or ""
	end
end

local sync_to_legacy = function(self)
	self.entries = self.__state.entries
	self.position = self.__state.position
	self.stashed = self.__state.stashed
end

local history_add = function(self, entry)
	sync_from_legacy(self)
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
		table.insert(self.__state.entries, payload)
		if self.store then
			self.store:save_history_entry(self.mode, payload)
		end
		self.__state.position = 0
		sync_to_legacy(self)
		return true
	end
	return false
end

local history_stash = function(self, entry)
	sync_from_legacy(self)
	self.__state.stashed = entry
	sync_to_legacy(self)
end

local history_get = function(self)
	sync_from_legacy(self)
	if self.__state.position == 0 then
		local stashed = self.__state.stashed
		self.__state.stashed = ""
		sync_to_legacy(self)
		return stashed
	else
		return self.__state.entries[self.__state.position].cmd
	end
end

local history_up = function(self)
	sync_from_legacy(self)
	if #self.__state.entries > 0 then
		if self.__state.position == 0 then
			self.__state.position = #self.__state.entries
			sync_to_legacy(self)
			return true
		end
		local cmd = self.__state.entries[self.__state.position].cmd
		while self.__state.position > 1 do
			self.__state.position = self.__state.position - 1
			if self.__state.entries[self.__state.position].cmd ~= cmd then
				break
			end
			cmd = self.__state.entries[self.__state.position].cmd
		end
		sync_to_legacy(self)
		return true
	end
	return false
end

local history_down = function(self)
	sync_from_legacy(self)
	if self.__state.position > 0 then
		if self.__state.position == #self.__state.entries then
			self.__state.position = 0
		else
			local cmd = self.__state.entries[self.__state.position].cmd
			while self.__state.position < #self.__state.entries do
				self.__state.position = self.__state.position + 1
				if self.__state.entries[self.__state.position].cmd ~= cmd then
					break
				end
				cmd = self.__state.entries[self.__state.position].cmd
			end
		end
		sync_to_legacy(self)
		return true
	end
	return false
end

local load_history = function(self)
	sync_from_legacy(self)
	if self.store then
		local entries, err = self.store:load_history(self.mode)
		if err then
			return nil, "can't get history: " .. tostring(err)
		end
		self.__state.entries = entries
		self.store:close()
		sync_to_legacy(self)
	end
end

local search = function(self, input)
	sync_from_legacy(self)
	local pattern = ".-"
	for _, arg in ipairs(input) do
		pattern = pattern .. std.escape_magic_chars(arg) .. ".-"
	end

	local scores = {}
	local cwd = std.fs.cwd()
	local home = os.getenv("HOME") or ""
	cwd = cwd:gsub("^" .. home, "~")

	for _, v in ipairs(self.__state.entries) do
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
	sync_from_legacy(self)
	local pattern = ".-"
	for _, arg in ipairs(input) do
		pattern = pattern .. std.escape_magic_chars(arg) .. ".-"
	end

	local scores = {}
	for _, v in ipairs(self.__state.entries) do
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

local get_last_command_last_arg = function(self)
	sync_from_legacy(self)
	if std.tbl.empty(self.__state.entries) then
		return ""
	end
	-- Always get the most recent command, regardless of current position
	local last_cmdline = self.__state.entries[#self.__state.entries].cmd
	-- Extract the last space-separated argument
	local last_arg = last_cmdline:match("(%S+)%s*$") or ""
	return last_arg
end

local entries_count = function(self)
	sync_from_legacy(self)
	return #self.__state.entries
end

local current_position = function(self)
	sync_from_legacy(self)
	return self.__state.position
end

local new = function(mode, store)
	local history = {
		cfg = { mode = mode },
		__state = {
			entries = {},
			position = 0,
			stashed = "",
		},
		store = store,
		mode = mode,
		entries = nil,
		position = 0,
		stashed = "",
		add = history_add,
		get = history_get,
		last_arg = get_last_command_last_arg,
		entries_count = entries_count,
		position_get = current_position,
		up = history_up,
		down = history_down,
		stash = history_stash,
		load = load_history,
		search = search,
		dir_search = dir_search,
	}
	sync_to_legacy(history)
	history:load()
	return history
end

return { new = new }
