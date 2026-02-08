-- SPDX-FileCopyrightText: © 2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: OWL-1.0 or later
-- Licensed under the Open Weights License v1.0. See LICENSE for details.

local testimony = require("testimony")
local helpers = require("tests.redis._helpers")

local testify = testimony.new("== redis client contract ==")

local make_tcp = function(state, name)
	local tcp = {
		name = name or "tcp",
		line_queue = {},
		bulk_queue = {},
		sent = {},
		close_count = 0,
		connect_ok = true,
		connect_err = nil,
	}

	local queue_line = function(self, value)
		table.insert(self.line_queue, value)
	end

	local queue_bulk = function(self, value)
		table.insert(self.bulk_queue, value)
	end

	local settimeout = function(self, timeout)
		self.timeout = timeout
	end

	local setoption = function(self, key, value)
		self.option_key = key
		self.option_value = value
	end

	local connect = function(self, host, port)
		self.connect_host = host
		self.connect_port = port
		if self.connect_ok then
			return true
		end
		return nil, self.connect_err or "connect failed"
	end

	local send = function(self, payload)
		table.insert(self.sent, payload)
		return true
	end

	local receive = function(self, size)
		if size then
			if #self.bulk_queue == 0 then
				return nil, "no queued bulk response"
			end
			return table.remove(self.bulk_queue, 1)
		end
		if #self.line_queue == 0 then
			return nil, "no queued line response"
		end
		return table.remove(self.line_queue, 1)
	end

	local close = function(self)
		self.close_count = self.close_count + 1
		return true
	end

	tcp.queue_line = queue_line
	tcp.queue_bulk = queue_bulk
	tcp.settimeout = settimeout
	tcp.setoption = setoption
	tcp.connect = connect
	tcp.send = send
	tcp.receive = receive
	tcp.close = close

	table.insert(state.tcp_created, tcp)
	return tcp
end

local load_redis_module = function(state)
	helpers.clear_modules({ "std", "socket", "ssl", "redis" })

	helpers.stub_module("std", {})
	helpers.stub_module("socket", {
		tcp = function()
			state.tcp_count = state.tcp_count + 1
			local tcp = make_tcp(state, "tcp#" .. tostring(state.tcp_count))
			if state.on_new_tcp then
				state.on_new_tcp(tcp, state.tcp_count)
			end
			return tcp
		end,
	})
	helpers.stub_module("ssl", {
		wrap = function(tcp)
			state.ssl_wrap_count = state.ssl_wrap_count + 1
			local conn = {
				tcp = tcp,
				handshake_count = 0,
				close_count = 0,
			}
			conn.dohandshake = function(self)
				self.handshake_count = self.handshake_count + 1
				state.ssl_handshake_count = state.ssl_handshake_count + 1
				if state.ssl_handshake_ok == false then
					return nil, "handshake failed"
				end
				return true
			end
			conn.send = function(self, payload)
				return tcp:send(payload)
			end
			conn.receive = function(self, size)
				return tcp:receive(size)
			end
			conn.close = function(self)
				self.close_count = self.close_count + 1
				state.ssl_close_count = state.ssl_close_count + 1
				return true
			end
			state.last_ssl_conn = conn
			return conn
		end,
	})

	return helpers.load_module_from_src("redis", "src/redis/redis.lua")
end

local new_state = function()
	return {
		tcp_count = 0,
		tcp_created = {},
		ssl_wrap_count = 0,
		ssl_handshake_count = 0,
		ssl_close_count = 0,
		ssl_handshake_ok = true,
		last_ssl_conn = nil,
		on_new_tcp = nil,
	}
end

testify:that("encodes commands and parses simple RESP types", function()
	local state = new_state()
	state.on_new_tcp = function(tcp)
		tcp:queue_line(":7")
		tcp:queue_line("+OK")
		tcp:queue_line("$5")
		tcp:queue_bulk("hello")
		tcp:queue_line("")
		tcp:queue_line("*2")
		tcp:queue_line("$3")
		tcp:queue_bulk("foo")
		tcp:queue_line("")
		tcp:queue_line(":9")
		tcp:queue_line("$-1")
	end
	local redis = load_redis_module(state)

	local client, err = redis.connect("127.0.0.1:6379")
	testimony.assert_not_nil(client, err)
	testimony.assert_equal(nil, err)

	local incr = client:cmd("INCR", "k")
	testimony.assert_equal(7, incr)
	local ok = client:cmd("SET", "x", "y")
	testimony.assert_equal("OK", ok)
	local val = client:cmd("GET", "x")
	testimony.assert_equal("hello", val)
	local rows = client:cmd("ZRANGE", "items", 0, -1)
	testimony.assert_equal("foo", rows[1])
	testimony.assert_equal(9, rows[2])
	local not_found, not_found_err = client:cmd("GET", "missing")
	testimony.assert_nil(not_found)
	testimony.assert_equal("not found", not_found_err)

	local sent = state.tcp_created[1].sent
	testimony.assert_equal("*2\r\n$4\r\nINCR\r\n$1\r\nk\r\n", sent[1])
	testimony.assert_equal("*3\r\n$3\r\nSET\r\n$1\r\nx\r\n$1\r\ny\r\n", sent[2])

	client:close(true)
	testimony.assert_equal(2, state.tcp_created[1].close_count)
end)

testify:that("parses nested arrays via read()", function()
	local state = new_state()
	state.on_new_tcp = function(tcp)
		tcp:queue_line("*2")
		tcp:queue_line(":1")
		tcp:queue_line("*2")
		tcp:queue_line("+A")
		tcp:queue_line("+B")
	end
	local redis = load_redis_module(state)
	local client = redis.connect({ host = "127.0.0.1", port = 6379 })
	local resp, err = client:read()
	testimony.assert_nil(err)
	testimony.assert_equal("arr", resp.type)
	testimony.assert_equal(1, resp.value[1])
	testimony.assert_equal("A", resp.value[2][1])
	testimony.assert_equal("B", resp.value[2][2])
	client:close(true)
end)

testify:that("runs AUTH and select during connect when configured", function()
	local state = new_state()
	state.on_new_tcp = function(tcp)
		tcp:queue_line("+OK")
		tcp:queue_line("+OK")
	end
	local redis = load_redis_module(state)
	local client, err = redis.connect({
		host = "127.0.0.1",
		port = 6379,
		db = 13,
		auth = { user = "alice", pass = "secret" },
	})

	testimony.assert_not_nil(client, err)
	local sent = state.tcp_created[1].sent
	testimony.assert_equal("*3\r\n$4\r\nAUTH\r\n$5\r\nalice\r\n$6\r\nsecret\r\n", sent[1])
	testimony.assert_equal("*2\r\n$6\r\nselect\r\n$2\r\n13\r\n", sent[2])
	client:close(true)
end)

testify:that("supports timeout and ssl connection flow", function()
	local state = new_state()
	state.on_new_tcp = function(tcp)
		tcp:queue_line("+PONG")
	end
	local redis = load_redis_module(state)
	local client, err = redis.connect({
		host = "127.0.0.1",
		port = 6379,
		ssl = true,
		timeout = 2,
	})

	testimony.assert_not_nil(client, err)
	testimony.assert_equal(2, state.tcp_created[1].timeout)
	testimony.assert_equal(1, state.ssl_wrap_count)
	testimony.assert_equal(1, state.ssl_handshake_count)
	local pong = client:cmd("PING")
	testimony.assert_equal("PONG", pong)
	client:close(true)
	testimony.assert_equal(1, state.ssl_close_count)
	testimony.assert_equal(1, state.tcp_created[1].close_count)
end)

testify:that("returns handshake error in ssl mode", function()
	local state = new_state()
	state.ssl_handshake_ok = false
	local redis = load_redis_module(state)
	local client, err = redis.connect({
		host = "127.0.0.1",
		port = 6379,
		ssl = true,
	})

	testimony.assert_nil(client)
	testimony.assert_equal("handshake failed", err)
end)

testify:that("reuses pooled socket for same host/port/db", function()
	local state = new_state()
	local redis = load_redis_module(state)
	local conf = {
		host = "127.0.0.1",
		port = 6379,
		db = 1,
	}

	local client1, err = redis.connect(conf)
	testimony.assert_not_nil(client1, err)
	client1:close()
	state.tcp_created[1]:queue_line("+PONG")
	state.tcp_created[1]:queue_line("+OK")

	local client2, err2 = redis.connect(conf)
	testimony.assert_not_nil(client2, err2)
	testimony.assert_equal(1, state.tcp_count)
	local ok = client2:cmd("SET", "a", "b")
	testimony.assert_equal("OK", ok)

	local sent = state.tcp_created[1].sent
	testimony.assert_equal("*2\r\n$6\r\nselect\r\n$1\r\n1\r\n", sent[1])
	testimony.assert_equal("PING\r\n", sent[2])
	testimony.assert_equal("*3\r\n$3\r\nSET\r\n$1\r\na\r\n$1\r\nb\r\n", sent[3])
	client2:close(true)
end)

testify:that("returns connect errors from tcp.connect", function()
	local state = new_state()
	state.on_new_tcp = function(tcp)
		tcp.connect_ok = false
		tcp.connect_err = "connection refused"
	end
	local redis = load_redis_module(state)
	local client, err = redis.connect("127.0.0.1:6379")
	testimony.assert_nil(client)
	testimony.assert_equal("connection refused", err)
end)

testify:that("validates URL format and config types", function()
	local state = new_state()
	local redis = load_redis_module(state)

	local client, err = redis.connect("localhost")
	testimony.assert_nil(client)
	testimony.assert_equal("invalid redis config URL format", err)

	client, err = redis.connect(42)
	testimony.assert_nil(client)
	testimony.assert_equal("redis config must be a table or URL string", err)
	testimony.assert_equal(0, state.tcp_count)
end)

testify:that("validates table config fields with clear errors", function()
	local state = new_state()
	local redis = load_redis_module(state)
	local client, err

	client, err = redis.connect({ host = "", port = 6379 })
	testimony.assert_nil(client)
	testimony.assert_equal("redis config host must be a non-empty string", err)

	client, err = redis.connect({ host = "127.0.0.1", port = 70000 })
	testimony.assert_nil(client)
	testimony.assert_equal("redis config port must be an integer in range 1..65535", err)

	client, err = redis.connect({ host = "127.0.0.1", db = -1 })
	testimony.assert_nil(client)
	testimony.assert_equal("redis config db must be a non-negative integer", err)

	client, err = redis.connect({ host = "127.0.0.1", timeout = 0 })
	testimony.assert_nil(client)
	testimony.assert_equal("redis config timeout must be a positive number", err)

	client, err = redis.connect({ host = "127.0.0.1", auth = "x" })
	testimony.assert_nil(client)
	testimony.assert_equal("redis config auth must be a table", err)

	client, err = redis.connect({ host = "127.0.0.1", auth = { pass = "secret" } })
	testimony.assert_nil(client)
	testimony.assert_equal("redis config auth.user must be a non-empty string", err)

	client, err = redis.connect({ host = "127.0.0.1", auth = { user = "alice" } })
	testimony.assert_nil(client)
	testimony.assert_equal("redis config auth.pass must be a non-empty string", err)

	testimony.assert_equal(0, state.tcp_count)
end)

testify:conclude()
