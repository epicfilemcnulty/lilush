-- SPDX-FileCopyrightText: © 2023 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: GPL-3.0-or-later

-- See https://redis.io/docs/reference/protocol-spec for
-- the RESP3 protocol details.

local std = require("std")
local socket = require("socket")

local redis_url = os.getenv("REDIS_URL") or "127.0.0.1:6379/0"
local config = {
	host = redis_url:match("^[^:]+"),
	port = tonumber(redis_url:match("^[^:]+:(%d+)")) or 6379,
	db = tonumber(redis_url:match("^[^:]+:%d+/(%d%d?)")) or 0,
	tcp_nodelay = true,
}

-- To re-use redis connections we just put a connected socket into this table
-- with `redis:close()` method. `redis.connect` first tries to use a socket from
-- the table, and only creates a new one if that fails.
local socket_pool = {}
local socket_pool_size = tonumber(os.getenv("REDIS_CLIENT_SOCKET_POOL_SIZE")) or 20

local bulk_strings_array = function(...)
	local arg = { ... }
	local array = ""
	for _, v in ipairs(arg) do
		local str = tostring(v)
		array = array .. "$" .. tostring(#str) .. "\r\n" .. str .. "\r\n"
	end
	return array
end

local read_simple_type = function(client)
	local line, err = client:receive()
	if line then
		if line:match("^%-") then
			local err_msg = line:match("^%-(.*)")
			return { value = err_msg, type = "error" }
		end
		if line:match("^:") then
			local num = line:match("^:([%d]+)")
			return { type = "int", value = tonumber(num) }
		end
		if line:match("^%+") then
			local str = line:match("^%+(.*)")
			return { type = "str", value = str }
		end
		if line:match("^%$") then
			local size = tonumber(line:match("^%$(.*)"))
			local bulk_str = ""
			if size > 0 then
				bulk_str = client:receive(size)
			end
			if size >= 0 then
				client:receive() -- eat the remaining `\r\n` in the response after the bulk string content
			else
				bulk_str = "NULL"
			end
			return { type = "bstr", value = bulk_str }
		end
		if line:match("^%*") then
			local size = tonumber(line:match("^%*(.*)"))
			local value = {}
			if size < 0 then
				value = "NULL"
			end
			return { type = "arr", size = size, value = value }
		end
	end
	return nil, err
end

local read_array

read_array = function(client, size)
	local value = {}
	for i = 1, size do
		local resp, err = read_simple_type(client)
		if err then
			return nil, err
		end
		if resp.type == "arr" and resp.size > 0 then
			table.insert(value, read_array(client, resp.size))
		else
			table.insert(value, resp.value)
		end
	end
	return value
end

local read_response = function(client)
	local resp, err = read_simple_type(client)
	if err then
		return nil, err
	end
	if resp.type == "arr" and resp.size > 0 then
		resp.value, err = read_array(client, resp.size)
	end
	return resp, err
end

local redis_command = function(self, ...)
	local arg = { ... }
	if not arg then
		return nil, "no command provided"
	end
	local cmd = "*" .. tostring(#arg) .. "\r\n" .. bulk_strings_array(...)
	self.s:send(cmd)
	local resp, err = read_response(self.s)
	if resp then
		if resp.type == "error" then
			return nil, resp.value
		end
		return resp.value
	end
	return nil, err
end

local read = function(self)
	return read_response(self.s)
end

local close = function(self, no_keepalive)
	if no_keepalive or #socket_pool[self.cfg] > socket_pool_size then
		self.s:close()
		return true
	end
	table.insert(socket_pool[self.cfg], self.s)
	return true
end

local connect = function(cfg)
	local conf = std.tbl.copy(config)
	if type(cfg) == "string" then
		conf = {
			host = cfg:match("^[^:]+"),
			port = tonumber(cfg:match("^[^:]+:(%d+)")) or 6379,
			db = tonumber(cfg:match("^[^:]+:%d+/(%d%d?)")) or 0,
			tcp_nodelay = true,
		}
	elseif type(cfg) == "table" then
		conf = std.tbl.merge(conf, cfg)
	end
	if socket_pool[conf] then
		if #socket_pool[conf] > 0 then
			local client = table.remove(socket_pool[conf], 1)
			if client:send("PING\r\n") then
				local r = client:receive()
				if r and r == "+PONG" then
					return { s = client, cmd = redis_command, close = close, read = read, cfg = conf }
				end
			end
			client:close()
		end
	else
		socket_pool[conf] = {}
	end

	local client = socket.tcp()
	if conf.timeout then
		client:settimeout(conf.timeout)
	end
	local ok, err = client:connect(conf.host, conf.port)
	if ok then
		client:setoption("tcp-nodelay", conf.tcp_nodelay)
		local obj = { s = client, cmd = redis_command, close = close, read = read, cfg = conf }
		obj:cmd("select", conf.db)
		return obj
	end
	return nil, err
end

local _M = { connect = connect }
return _M
