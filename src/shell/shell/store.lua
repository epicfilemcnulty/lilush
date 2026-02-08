-- SPDX-FileCopyrightText: © 2022—2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: LicenseRef-OWL-1.0-or-later OR GPL-3.0-or-later
-- Dual-licensed under OWL v1.0+ and GPLv3+. See LICENSE and LICENSE-GPL3.

local std = require("std")
local json = require("cjson.safe")
local redis = require("redis")

local validate_redis_client = function(client)
	if type(client) ~= "table" then
		return nil, "client must be a table"
	end
	if type(client.cmd) ~= "function" then
		return nil, "missing cmd method"
	end
	if type(client.close) ~= "function" then
		return nil, "missing close method"
	end
	return true
end

local init_redis_store = function(redis_url)
	local red, err = redis.connect(redis_url)
	if err then
		return nil, "can't connect to redis: " .. err
	end
	local ok, client_err = validate_redis_client(red)
	if not ok then
		return nil, "invalid redis client: " .. client_err
	end
	return red
end

local write_to_channel = function(self, payload)
	return self.__state.redis:cmd("PUBLISH", self.cfg.key_prefix .. "debug" .. self.cfg.key_suffix, payload)
end

local get_file = function(self, filename)
	local name = filename or ""
	return std.fs.read_file(self.cfg.storage_dir .. "/" .. name)
end

local get_json_file = function(self, filename)
	local name = filename or ""
	local content_json = std.fs.read_file(self.cfg.storage_dir .. "/" .. name)
	return json.decode(content_json)
end

local save_history_entry = function(self, mode, payload)
	local history_mode = mode or "general"
	local encoded, err = json.encode(payload)
	if err then
		return nil, "failed to serialize the entry: " .. err
	end
	local _, cmd_err = self.__state.redis:cmd(
		"ZADD",
		self.cfg.key_prefix .. "history/" .. history_mode .. self.cfg.key_suffix,
		payload.ts,
		encoded
	)
	if cmd_err then
		return nil, "failed to save entry: " .. cmd_err
	end
	return true
end

local load_history = function(self, mode, lines)
	local history_mode = mode or "general"
	local max_lines = tonumber(lines) or 0
	local res, err
	if max_lines ~= 0 then
		res, err = self.__state.redis:cmd(
			"ZRANGE",
			self.cfg.key_prefix .. "history/" .. history_mode .. self.cfg.key_suffix,
			-max_lines,
			-1
		)
	else
		res, err = self.__state.redis:cmd(
			"ZRANGE",
			self.cfg.key_prefix .. "history/" .. history_mode .. self.cfg.key_suffix,
			0,
			-1
		)
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
	local files = std.fs.list_dir(self.cfg.storage_dir .. "/snippets")
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
	local snippet_name = snippet or ""
	return std.fs.read_file(self.cfg.storage_dir .. "/snippets/" .. snippet_name)
end

local save_llm_chat = function(self, name, payload)
	local encoded, err = json.encode(payload)
	if err then
		return nil, err
	end
	return self.__state.redis:cmd("HSET", self.cfg.key_prefix .. "llm/chats" .. self.cfg.key_suffix, name, encoded)
end

local load_llm_chat = function(self, name)
	local chat_json = self.__state.redis:cmd("HGET", self.cfg.key_prefix .. "llm/chats" .. self.cfg.key_suffix, name)
	return json.decode(chat_json)
end

local list_llm_chats = function(self)
	return self.__state.redis:cmd("HKEYS", self.cfg.key_prefix .. "llm/chats" .. self.cfg.key_suffix)
end

local save_vault_token = function(self, token, ttl)
	return self.__state.redis:cmd("SET", self.cfg.key_prefix .. "vault_token" .. self.cfg.key_suffix, token, "EX", ttl)
end

local get_vault_token = function(self)
	return self.__state.redis:cmd("GET", self.cfg.key_prefix .. "vault_token" .. self.cfg.key_suffix)
end

local close = function(self, no_keepalive)
	return self.__state.redis:close(no_keepalive)
end

local new = function(options)
	local hostname = std.hostname()
	if hostname == "" then
		hostname = "amnesia"
	end
	local user = os.getenv("USER") or "nobody"
	local suffix = ":" .. hostname .. ":" .. user
	local home = os.getenv("HOME") or "/tmp"
	local storage_dir = home .. "/.local/share/lilush"

	local cfg = {
		redis_url = os.getenv("LILUSH_REDIS_URL"),
		key_prefix = os.getenv("LILUSH_REDIS_PREFIX") or "llsh:DATA:",
		key_suffix = suffix,
		storage_dir = storage_dir,
	}
	std.tbl.merge(cfg, options or {})

	local red, err = init_redis_store(cfg.redis_url)
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
		cfg = cfg,
		__state = {
			redis = red,
		},
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
		write = write_to_channel,
		close = close,
	}
	return obj
end

return { new = new }
