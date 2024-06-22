-- SPDX-FileCopyrightText: © 2024 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: GPL-3.0-or-later

local std = require("std")
local json = require("cjson.safe")
local redis = require("redis")
local crypto = require("crypto")

local init_redis_store = function(redis_url)
	local red, err = redis.connect(redis_url)
	if err then
		return nil, "can't connect to redis: " .. tostring(err)
	end
	return red
end

local init_file_store = function(storage_dir)
	if not storage_dir then
		return nil, "storage dir is not provided"
	end
	if not std.fs.dir_exists(storage_dir) then
		local ok, err = std.fs.mkdir(storage_dir, nil, true)
		if not ok then
			return nil, "can't init storage dir: " .. tostring(err)
		end
	end
	return storage_dir
end

local get_key = function(self, key, decode_json)
	local content, err
	if self.redis then
		local key_path = self.redis_common .. key .. self.redis_unique
		content, err = self.redis:cmd("GET", key_path)
		if err and self.policy == "break" then
			return nil, "can't get the key from redis: " .. tostring(err)
		end
		if content == "NULL" then
			err = "key does not exist"
			content = nil
		end
		if decode_json then
			content, err = json.decode(content)
		end
		if content then
			return content
		end
		if self.policy == "break" then
			return nil, tostring(err)
		end
	end
	if self.storage_dir then
		content, err = std.fs.read_file(self.storage_dir .. "/" .. key)
		if err then
			return nil, "can't read file: " .. tostring(err)
		end
		if decode_json then
			return json.decode(content)
		end
		return content
	end
	return false
end

local set_key = function(self, key, value, encode_json)
	local v, err
	if encode_json then
		v, err = json.encode(v)
		if err then
			return nil, "can't json encode value: " .. tostring(err)
		end
	else
		v = value
	end
	if self.redis then
		local key_path = self.redis_common .. key .. self.redis_unique
		local ok, err = self.redis:cmd("SET", key_path, v)
		if err then
			return nil, "can't set the key: " .. tostring(err)
		end
		return true
	end
	if self.storage_dir then
		if key:match("/") then
			local dirs = std.fs.split_path_by_dir(key)
			table.remove(dirs)
			std.fs.mkdir(self.storage_dir .. "/" .. table.concat(dirs, "/"), nil, true)
		end
		ok, err = std.fs.write_file(self.storage_dir .. "/" .. key, v)
		if err then
			return nil, "can't write file: " .. tostring(err)
		end
		return true
	end
	return nil, "all backends are disabled"
end

local get_hash_key = function(self, hash, key, decode_json)
	local content, err
	if self.redis then
		local key_path = self.redis_common .. hash .. self.redis_unique
		content, err = self.redis:cmd("HGET", key_path, key)
		if err and self.policy == "break" then
			return nil, "can't get the key from redis: " .. tostring(err)
		end
		if content == "NULL" then
			content = nil
			err = "key does not exist"
		end
		if decode_json then
			content, err = json.decode(content)
		end
		if content then
			return content
		end
		if self.policy == "break" then
			return nil, tostring(err)
		end
	end
	if self.storage_dir then
		local hash_dir = self.storage_dir .. "/" .. hash
		content, err = std.fs.read_file(hash_dir .. "/" .. key)
		if err then
			return nil, "can't read file: " .. tostring(err)
		end
	end
	if decode_json then
		return json.decode(content)
	end
	return content
end

local set_hash_key = function(self, hash, key, value, encode_json)
	local v, err
	if encode_json then
		v, err = json.encode(value)
		if err then
			return nil, "can't convert value to json: " .. tostring(err)
		end
	else
		v = value
	end
	if self.redis then
		local key_path = self.redis_common .. hash .. self.redis_unique
		local ok, err = self.redis:cmd("HSET", key_path, key, v)
		if err then
			return nil, "can't set the key: " .. tostring(err)
		end
		return true
	end
	if self.storage_dir then
		local hash_dir = self.storage_dir .. "/" .. hash
		if not std.fs.dir_exists(hash_dir) then
			std.fs.mkdir(hash_dir, nil, true)
		end
		local ok, err = std.fs.write_file(hash_dir .. "/" .. key, v)
		if err then
			return nil, "can't write file: " .. tostring(err)
		end
		return true
	end
	return nil, "all backends are disabled"
end

local incr_hash_key = function(self, hash, key, value)
	local value = tonumber(value) or 0
	if self.redis then
		local cmd = "HINCRBY"
		if value % 1 ~= 0 then -- not integer
			cmd = "HINCRBYFLOAT"
		end
		local key_path = self.redis_common .. hash .. self.redis_unique
		local ok, err = self.redis:cmd(cmd, key_path, key, value)
		if err then
			return nil, "can't increase the key: " .. tostring(err)
		end
		return true
	end
	if self.storage_dir then
		local hash_dir = self.storage_dir .. "/" .. hash
		if not std.fs.dir_exists(hash_dir) then
			std.fs.mkdir(hash_dir, nil, true)
		end
		local cur_val = std.fs.read_file(hash_dir .. "/" .. key)
		cur_val = tonumber(cur_val) or 0
		local ok, err = std.fs.write_file(hash_dir .. "/" .. key, cur_val + value)
		if err then
			return nil, "can't write file: " .. tostring(err)
		end
		return true
	end
	return nil, "all backends are disabled"
end

local list_hash_keys = function(self, hash)
	if self.redis then
		local hash_path = self.redis_common .. hash .. self.redis_unique
		local keys, err = self.redis:cmd("HKEYS", hash_path)
		if keys and #keys > 0 then
			return keys
		end
		if self.policy == "break" then
			return nil, "can't get hash keys: " .. tostring(err)
		end
	end
	if self.storage_dir then
		local keys = {}
		local hash_dir = self.storage_dir .. "/" .. hash
		local files, err = std.fs.list_files(hash_dir)
		if files then
			for name, v in pairs(files) do
				table.insert(keys, name)
			end
		end
		return keys
	end
end

local add_set_member = function(self, set_name, member, score, encode_json)
	local m, err
	if encode_json then
		m, err = json.encode(member)
		if err then
			return nil, "can't convert member to json: " .. tostring(err)
		end
	else
		m = member
	end
	if self.redis then
		local key_path = self.redis_common .. set_name .. self.redis_unique
		local ok, err = self.redis:cmd("ZADD", key_path, score, m)
		if err then
			return nil, "can't set the key: " .. tostring(err)
		end
		return true
	end
	if self.storage_dir then
		local set_dir = self.storage_dir .. "/" .. set_name
		if not std.fs.dir_exists(set_dir) then
			std.fs.mkdir(set_dir, nil, true)
		end
		local m_hash = crypto.bin_to_hex(crypto.sha256(m))
		local members = std.fs.read_file(set_dir .. "/members.json") or "{}"
		members = json.decode(members) or {}
		local index = std.fs.read_file(set_dir .. "/index.json") or "{}"
		index = json.decode(index) or {}
		local scores = std.fs.read_file(set_dir .. "/scores.json") or "{}"
		scores = json.decode(scores) or {}
		members[m_hash] = m
		scores[m_hash] = score
		table.insert(index, m_hash)
		std.fs.write_file(set_dir .. "/members.json", json.encode(members))
		std.fs.write_file(set_dir .. "/index.json", json.encode(index))
		std.fs.write_file(set_dir .. "/scores.json", json.encode(scores))
		return true
	end
	return nil, "all backends are disabled"
end

local get_set_range = function(self, set_name, start, stop)
	if self.redis then
		local key_path = self.redis_common .. set_name .. self.redis_unique
		local res, err = self.redis:cmd("ZRANGE", key_path, start, stop)
		if err then
			return nil, "can't get set range: " .. tostring(err)
		end
		return res
	end
	if self.storage_dir then
		local set_dir = self.storage_dir .. "/" .. set_name
		if not std.fs.dir_exists(set_dir) then
			return nil, "set does not exist"
		end
		local members = json.decode(std.fs.read_file(set_dir .. "/members.json")) or {}
		local index = json.decode(std.fs.read_file(set_dir .. "/index.json")) or {}
		local scores = json.decode(std.fs.read_file(set_dir .. "/scores.json")) or {}
		local range = {}
		local start = start + 1
		if stop < 0 then
			stop = #index + stop + 1
		end
		for i = start, stop, 1 do
			table.insert(range, members[index[i]])
		end
		return range
	end
	return nil, "all backends are disabled"
end

local add_simple_set_member = function(self, set_name, member)
	if self.redis then
		local key_path = self.redis_common .. set_name .. self.redis_unique
		local ok, err = self.redis:cmd("SADD", key_path, member)
		if err then
			return nil, "can't set the key: " .. tostring(err)
		end
		return true
	end
	if self.storage_dir then
		local set_dir = self.storage_dir .. "/" .. set_name
		if not std.fs.dir_exists(set_dir) then
			std.fs.mkdir(set_dir, nil, true)
		end
		local members = std.fs.read_file(set_dir .. "/members.json") or "{}"
		members = json.decode(members) or {}
		members[member] = true
		std.fs.write_file(set_dir .. "/members.json", json.encode(members))
		return true
	end
	return nil, "all backends are disabled"
end

local remove_simple_set_member = function(self, set_name, member)
	if self.redis then
		local key_path = self.redis_common .. set_name .. self.redis_unique
		local ok, err = self.redis:cmd("SREM", key_path, member)
		if err then
			return nil, "can't remove the key: " .. tostring(err)
		end
		return true
	elseif self.storage_dir then
		local set_dir = self.storage_dir .. "/" .. set_name
		if not std.fs.dir_exists(set_dir) then
			std.fs.mkdir(set_dir, nil, true)
		end
		local members = std.fs.read_file(set_dir .. "/members.json") or "{}"
		members = json.decode(members) or {}
		members[member] = nil
		std.fs.write_file(set_dir .. "/members.json", json.encode(members))
		return true
	end
	return nil, "all backends are disabled"
end

local get_simple_set_members = function(self, set_name)
	if self.redis then
		local key_path = self.redis_common .. set_name .. self.redis_unique
		local members, err = self.redis:cmd("SMEMBERS", key_path, member)
		if members and #members > 0 then
			return members
		end
		if self.policy == "break" then
			return nil, "can't get hash keys: " .. tostring(err)
		end
	end
	if self.storage_dir then
		local set_dir = self.storage_dir .. "/" .. set_name
		if not std.fs.dir_exists(set_dir) then
			std.fs.mkdir(set_dir, nil, true)
		end
		local members = std.fs.read_file(set_dir .. "/members.json") or "{}"
		members = json.decode(members) or {}
		return members
	end
	return nil, "all backends are disabled"
end

local close = function(self, no_keepalive)
	if self.redis then
		self.redis:close(no_keepalive)
	end
end

local new = function(options)
	local hostname = tostring(std.fs.read_file("/etc/hostname")):gsub("\n", ""):gsub("%s+", "")
	if hostname == "nil" then
		hostname = "amnesia"
	end
	local user = os.getenv("USER") or "nobody"
	local unique = ":" .. hostname .. ":" .. user
	local default_options = {
		policy = "pass",
		storage_dir = os.getenv("HOME") .. "/.local/share/lilush",
		redis_url = os.getenv("LILUSH_REDIS_URL"),
		redis_common = os.getenv("LILUSH_REDIS_PREFIX") or "llsh:DATA:",
		redis_unique = unique,
	}
	local options = options or {}
	std.tbl.merge(default_options, options)

	local red = init_redis_store(default_options.redis_url)
	local storage_dir = init_file_store(default_options.storage_dir)

	local obj = {
		policy = default_options.policy,
		redis = red,
		redis_common = default_options.redis_common,
		redis_unique = default_options.redis_unique,
		storage_dir = storage_dir,
		get_key = get_key,
		set_key = set_key,
		get_hash_key = get_hash_key,
		set_hash_key = set_hash_key,
		incr_hash_key = incr_hash_key,
		list_hash_keys = list_hash_keys,
		add_set_member = add_set_member,
		get_set_range = get_set_range,
		add_simple_set_member = add_simple_set_member,
		remove_simple_set_member = remove_simple_set_member,
		get_simple_set_members = get_simple_set_members,
		close = close,
	}
	return obj
end

return { new = new }
