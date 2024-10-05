-- SPDX-FileCopyrightText: © 2024 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: GPL-3.0-or-later

local std = require("std")
local json = require("cjson.safe")
local redis = require("redis")

local init_redis_store = function(redis_url)
	local red, err = redis.connect(redis_url)
	if err then
		return nil, "can't connect to redis: " .. tostring(err)
	end
	return red
end

local save_history_entry = function(self, mode, payload)
	local mode = mode or "general"
	local encoded, err = json.encode(payload)
	if err then
		return nil, "failed to serialize the entry: " .. err
	end
	local ok, err = self.redis:cmd("ZADD", self.prefix .. "history/" .. mode .. self.suffix, payload.ts, encoded)
	if err then
		return nil, "failed to save entry: " .. err
	end
	return true
end

local load_history = function(self, mode)
	local res, err = self.redis:cmd("ZRANGE", self.prefix .. "history/" .. mode .. self.suffix, 0, -1)
	if err then
		return nil, "failed to load history: " .. err
	end
	local entries = {}
	for _, entry in ipairs(res) do
		local decoded = json.decode(entry)
		if decoded then
			table.insert(entries, decoded)
		end
	end
	return entries
end

local load_theme = function(self)
	local widgets_file = std.fs.read_file(self.storage_dir .. "/theme/widgets.json")
	local widgets = json.decode(widgets_file) or {}
	local renderer_file = std.fs.read_file(self.storage_dir .. "/theme/renderer.json")
	local renderer = json.decode(renderer_file) or {}
	local prompts_file = std.fs.read_file(self.storage_dir .. "/theme/prompts.json")
	local prompts = json.decode(prompts_file) or {}
	local builtins_file = std.fs.read_file(self.storage_dir .. "/theme/builtins.json")
	local builtins = json.decode(builtins_file) or {}
	local modes_file = std.fs.read_file(self.storage_dir .. "/theme/modes.json")
	local modes = json.decode(modes_file) or {}
	local completion_file = std.fs.read_file(self.storage_dir .. "/theme/completion.json")
	local completion = json.decode(completion_file) or {}
	return widgets, renderer, builtins, prompts, modes, completion
end

local list_snippets = function(self)
	local files = std.fs.list_dir(self.storage_dir .. "/snippets")
	local snippets = {}
	if files then
		for _, file in ipairs(files) do
			if file ~= "." and file ~= ".." then
				table.insert(snippets, file)
			end
		end
	end
	return snippets
end

local get_snippet = function(self, snippet)
	local snippet = snippet or ""
	return std.fs.read_file(self.storage_dir .. "/snippets/" .. snippet)
end

local close = function(self, no_keepalive)
	self.redis:close(no_keepalive)
end

local new = function(options)
	local hostname = tostring(std.fs.read_file("/etc/hostname")):gsub("\n", ""):gsub("%s+", "")
	if hostname == "nil" then
		hostname = "amnesia"
	end
	local user = os.getenv("USER") or "nobody"
	local suffix = ":" .. hostname .. ":" .. user
	local home = os.getenv("HOME") or "/tmp"
	local storage_dir = home .. "/.local/share/lilush"

	local default_options = {
		redis_url = os.getenv("LILUSH_REDIS_URL"),
		key_prefix = os.getenv("LILUSH_REDIS_PREFIX") or "llsh:DATA:",
		key_suffix = suffix,
		storage_dir = storage_dir,
	}
	local options = options or {}
	std.tbl.merge(default_options, options)

	local red, err = init_redis_store(default_options.redis_url)
	if not red then
		return nil, "failed to init redis store: " .. err
	end
	local obj = {
		redis = red,
		suffix = default_options.key_suffix,
		prefix = default_options.key_prefix,
		storage_dir = storage_dir,
		save_history_entry = save_history_entry,
		load_history = load_history,
		load_theme = load_theme,
		list_snippets = list_snippets,
		get_snippet = get_snippet,
		close = close,
	}
	return obj
end

return { new = new }
