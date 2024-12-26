-- SPDX-FileCopyrightText: © 2024 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: GPL-3.0-or-later

local std = require("std")
local json = require("cjson.safe")
local redis = require("redis")

local init_redis_store = function(redis_url)
	local red, err = redis.connect(redis_url)
	if err then
		return nil, "can't connect to redis: " .. err
	end
	return red
end

local get_file = function(self, filename)
	local filename = filename or ""
	return std.fs.read_file(self.storage_dir .. "/" .. filename)
end

local get_json_file = function(self, filename)
	local filename = filename or ""
	local content_json = std.fs.read_file(self.storage_dir .. "/" .. filename)
	return json.decode(content_json)
end

local save_history_entry = function(self, mode, payload)
	local mode = mode or "general"
	local encoded, err = json.encode(payload)
	if err then
		return nil, "failed to serialize the entry: " .. err
	end
	local _, err = self.redis:cmd("ZADD", self.prefix .. "history/" .. mode .. self.suffix, payload.ts, encoded)
	if err then
		return nil, "failed to save entry: " .. err
	end
	return true
end

local load_history = function(self, mode, lines)
	local mode = mode or "general"
	local lines = tonumber(lines) or 0
	local res, err
	if lines ~= 0 then
		res, err = self.redis:cmd("ZRANGE", self.prefix .. "history/" .. mode .. self.suffix, -lines, -1)
	else
		res, err = self.redis:cmd("ZRANGE", self.prefix .. "history/" .. mode .. self.suffix, 0, -1)
	end
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

local save_llm_chat = function(self, name, payload)
	local encoded, err = json.encode(payload)
	if err then
		return nil, err
	end
	return self.redis:cmd("HSET", self.prefix .. "llm/chats" .. self.suffix, name, encoded)
end

local load_llm_chat = function(self, name)
	local chat_json = self.redis:cmd("HGET", self.prefix .. "llm/chats" .. self.suffix, name)
	return json.decode(chat_json)
end

local list_llm_chats = function(self)
	return self.redis:cmd("HKEYS", self.prefix .. "llm/chats" .. self.suffix)
end

local save_vault_token = function(self, token, ttl)
	return self.redis:cmd("SET", self.prefix .. "vault_token" .. self.suffix, token, "EX", ttl)
end

local get_vault_token = function(self)
	return self.redis:cmd("GET", self.prefix .. "vault_token" .. self.suffix)
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
	if err then
		red = {
			cmd = function(self)
				return nil, err
			end,
			close = function(self)
				return true
			end,
		}
	end
	local obj = {
		redis = red,
		suffix = default_options.key_suffix,
		prefix = default_options.key_prefix,
		storage_dir = storage_dir,
		save_history_entry = save_history_entry,
		load_history = load_history,
		list_snippets = list_snippets,
		get_snippet = get_snippet,
		get_json_file = get_json_file,
		get_file = get_file,
		get_vault_token = get_vault_token,
		save_vault_token = save_vault_token,
		save_llm_chat = save_llm_chat,
		load_llm_chat = load_llm_chat,
		list_llm_chats = list_llm_chats,
		close = close,
	}
	return obj
end

return { new = new }
