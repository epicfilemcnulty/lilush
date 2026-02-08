-- SPDX-FileCopyrightText: © 2022—2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: LicenseRef-OWL-1.0-or-later OR GPL-3.0-or-later
-- Dual-licensed under OWL v1.0+ and GPLv3+. See LICENSE and LICENSE-GPL3.

-- See https://redis.io/docs/reference/protocol-spec for
-- the RESP3 protocol details.

local socket = require("socket")
local ssl = require("ssl")

local parse_config_url = function(url)
	local url = url or "127.0.0.1:6379"
	if type(url) ~= "string" then
		return nil, "invalid redis config URL type"
	end
	local host, port, db = url:match("^([^:]+):(%d+)/(%d+)$")
	if not host then
		host, port = url:match("^([^:]+):(%d+)$")
	end
	if not host or not port then
		return nil, "invalid redis config URL format"
	end
	return {
		host = host,
		port = tonumber(port),
		db = tonumber(db),
	}
end

-- To re-use redis connections we just put a connected socket into this table
-- with `redis:close()` method. `redis.connect` first tries to use a socket from
-- the table, and only creates a new one if that fails.
local socket_pool = {}
local socket_pool_size = tonumber(os.getenv("REDIS_CLIENT_SOCKET_POOL_SIZE")) or 20

local encode_bulk_strings = function(...)
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

local read_array_response

read_array_response = function(client, size)
	local value = {}
	for i = 1, size do
		local resp, err = read_simple_type(client)
		if err then
			return nil, err
		end
		if resp.type == "arr" and resp.size > 0 then
			table.insert(value, read_array_response(client, resp.size))
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
	if resp.value == "NULL" then
		return nil, "not found"
	end
	if resp.type == "arr" and resp.size > 0 then
		resp.value, err = read_array_response(client, resp.size)
	end
	return resp, err
end

local redis_command = function(self, ...)
	local arg = { ... }
	if not arg then
		return nil, "no command provided"
	end
	local cmd = "*" .. tostring(#arg) .. "\r\n" .. encode_bulk_strings(...)
	self.__state.socket:send(cmd)
	local resp, err = read_response(self.__state.socket)
	if resp then
		if resp.type == "error" then
			return nil, resp.value
		end
		return resp.value
	end
	return nil, err
end

local read = function(self)
	return read_response(self.__state.socket)
end

local close = function(self, no_keepalive)
	local pool_key = self.__state.pool_key
	if no_keepalive or #socket_pool[pool_key] > socket_pool_size then
		self.__state.socket:close()
		if self.__state.tcp then
			self.__state.tcp:close()
		end
		return true
	end
	table.insert(socket_pool[pool_key], self.__state.socket)
	return true
end

local new_client = function(cfg, client_socket, tcp_socket, pool_key)
	return {
		cfg = cfg,
		__state = {
			socket = client_socket,
			tcp = tcp_socket,
			pool_key = pool_key,
		},
		cmd = redis_command,
		close = close,
		read = read,
	}
end

local parse_positive_integer = function(value)
	local num = tonumber(value)
	if not num then
		return nil
	end
	if num % 1 ~= 0 then
		return nil
	end
	return num
end

local normalize_config = function(config)
	if config == nil or type(config) == "string" then
		return parse_config_url(config)
	end

	if type(config) ~= "table" then
		return nil, "redis config must be a table or URL string"
	end

	local host = config.host
	if type(host) ~= "string" or host == "" then
		return nil, "redis config host must be a non-empty string"
	end

	local port = parse_positive_integer(config.port or 6379)
	if not port or port < 1 or port > 65535 then
		return nil, "redis config port must be an integer in range 1..65535"
	end

	local db = nil
	if config.db ~= nil then
		db = parse_positive_integer(config.db)
		if not db or db < 0 then
			return nil, "redis config db must be a non-negative integer"
		end
	end

	local timeout = nil
	if config.timeout ~= nil then
		timeout = tonumber(config.timeout)
		if not timeout or timeout <= 0 then
			return nil, "redis config timeout must be a positive number"
		end
	end

	if config.auth ~= nil then
		if type(config.auth) ~= "table" then
			return nil, "redis config auth must be a table"
		end
		if type(config.auth.user) ~= "string" or config.auth.user == "" then
			return nil, "redis config auth.user must be a non-empty string"
		end
		if type(config.auth.pass) ~= "string" or config.auth.pass == "" then
			return nil, "redis config auth.pass must be a non-empty string"
		end
	end

	return {
		host = host,
		port = port,
		db = db,
		timeout = timeout,
		ssl = config.ssl,
		auth = config.auth,
	}
end

local connect = function(config)
	local conf, conf_err = normalize_config(config)
	if not conf then
		return nil, conf_err
	end
	local db = conf.db or "0"
	local pool_key = conf.host .. ":" .. conf.port .. "/" .. db

	if socket_pool[pool_key] then
		if #socket_pool[pool_key] > 0 then
			local client = table.remove(socket_pool[pool_key], 1)
			if client:send("PING\r\n") then
				local r = client:receive()
				if r and r == "+PONG" then
					return new_client(conf, client, nil, pool_key)
				end
			end
			client:close()
		end
	else
		socket_pool[pool_key] = {}
	end

	local tcp = socket.tcp()
	if conf.timeout then
		tcp:settimeout(conf.timeout)
	end
	local ok, err = tcp:connect(conf.host, conf.port)
	if not ok then
		return nil, err
	end
	local client = tcp
	client:setoption("tcp-nodelay", true)
	if conf.ssl then
		local conn, err = ssl.wrap(tcp)
		if err then
			tcp:close()
			return nil, err
		end
		local ok, err = conn:dohandshake()
		if err then
			return nil, err
		end
		client = conn
	end
	local obj = new_client(conf, client, tcp, pool_key)
	if conf.auth then
		obj:cmd("AUTH", conf.auth.user, conf.auth.pass)
	end
	if conf.db then
		obj:cmd("select", conf.db)
	end
	return obj
end

local _M = { connect = connect }
return _M
