-- SPDX-FileCopyrightText: © 2023 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: GPL-3.0-or-later
local std = require("std")
local socket = require("socket")
local json = require("cjson.safe")
local buffer = require("string.buffer")
local ssl = require("ssl")

local premature_error = function(client, status, msg)
	local resp = "HTTP/1.1 "
		.. tostring(status)
		.. " \n"
		.. "Connection: close\n"
		.. "Content-Length: "
		.. tostring(#msg)
		.. "\n\n"
		.. msg
	client:send(resp)
end

local read_chunked_body = function(client)
	local body = {}
	while true do
		-- Read chunk size
		local size_line = client:receive()
		if not size_line then
			return nil, "connection closed"
		end

		local chunk_size = tonumber(size_line:match("^%x+"), 16)
		if not chunk_size then
			return nil, "invalid chunk size"
		end

		-- End of chunked data
		if chunk_size == 0 then
			-- Read final CRLF
			client:receive()
			break
		end

		-- Read chunk data
		local chunk = client:receive(chunk_size)
		if not chunk then
			return nil, "connection closed"
		end
		table.insert(body, chunk)

		-- Read trailing CRLF
		client:receive()
	end

	return table.concat(body)
end

--[[ 
        This is a very naive implementation of HTTP request parsing.

        We rely on `receive("*l")` method, and read the request line by line.
        This means that we can't check the size of an incoming line until we've read one.
        This is, of course, an open door for a DOS attack.

        There is another approach -- we can read from the client socket in
        chunks of BLOCK_SIZE, then stitch all the chunks together, 
        split them into lines, etc. I've tried to implement said approach,
        but the performance left much to be desired, compared to the "naive" one.

        Till I find time for optimizations, the "naive" one is the one
        and only used in default builds.
        
        As a consequence, it's highly advised to have a reverse-proxy in front of the server,
        handling all the dirty work of request validation.
]]

local server_process_request = function(self, client, client_ip, count)
	local start_time = os.clock()
	local lines = {}
	local client_ip = client_ip or "n/a"
	local line = ""
	repeat
		line, err = client:receive()
		if not line then
			return nil, err
		end
		if line ~= "" then
			if #line > self.__config.request_line_limit then
				premature_error(client, 413, "Header/request line too long\n")
				return nil, "header line limit violation: " .. tostring(#line)
			end
			table.insert(lines, line)
		end
	until line == ""

	if table.concat(lines):match("[\128-\255]") then
		premature_error(client, 400, "Non ASCII characters in headers\n")
		return nil, "non USASCII characters in headers"
	end

	local request = table.remove(lines, 1)
	local method, query, args = request:match("([A-Z]+) ([^?]*)%?-(.-) HTTP/1%.[01]$")
	if not method then
		premature_error(client, 400, "Unsupported protocol\n")
		return nil, "Unsupported protocol"
	end
	local query = query or "/"
	local body = nil
	local content_length = 0
	local headers = {}

	for _, l in ipairs(lines) do
		local header, value = l:match("^([^: ]+):%s*(.*)$")
		if not header then
			premature_error(client, 400, "Malformed header\n")
			return nil, "Malformed header"
		end
		headers[string.lower(header)] = value
		if string.lower(header) == "content-length" then
			content_length = tonumber(value)
		end
	end
	if headers["transfer-encoding"] then
		body, err = read_chunked_body(client)
		if err then
			premature_error(client, 501, "handle transfer-encoding failed\n")
			return nil, "failed to read chunked body: " .. err
		end
	end
	if not headers.host then
		premature_error(client, 400, "No Host header\n")
		return nil, "no Host header"
	end
	local host = headers.host
	if content_length > 0 then
		if content_length > self.__config.max_body_size then
			premature_error(client, 413, "A body too fat\n")
			return nil, "max_body_size limit violation: " .. tostring(content_length)
		end
		body, err = client:receive(content_length)
		if err then
			return nil, "failed to get request body: " .. err
		end
	end

	local compress_output = false
	if
		headers["accept-encoding"]
		and headers["accept-encoding"]:match("deflate")
		and self.__config.compression.enabled
	then
		compress_output = true
	end
	headers["x-real-ip"] = client_ip

	local content, status, response_headers = self.handle(method, query, args, headers, body, {
		logger = self.logger,
		client = client,
		is_ssl = self.__config.ssl ~= nil,
	})
	if content == nil and status == nil and response_headers == nil then
		-- request was proxied, so we just return the connection state...
		return "keep-alive"
	end

	response_headers = response_headers or {}
	if not response_headers["content-type"] then
		response_headers["content-type"] = "text/html"
	end
	if content and #content > 0 then
		if
			compress_output
			and self.__config.compression.types[response_headers["content-type"]]
			and #content >= self.__config.compression.min_size
		then
			--[[ replace with gzip as soon as we integrate some lib for gzip support...
              ```old code  
			  content = libdeflate:CompressDeflate(content)
			  response_headers["content-encoding"] = "deflate"
             ```   
            ]]
			--
		end
		response_headers["content-length"] = tostring(#content)
	end
	response_headers["connection"] = "keep-alive"
	if (headers["connection"] and headers["connection"] == "close") or count == self.__config.requests_per_fork then
		response_headers["connection"] = "close"
	end

	local buf = buffer.new()
	buf:put("HTTP/1.1 ", tostring(status), " \n")
	for h, v in pairs(response_headers) do
		if h == "set-cookie" and type(v) == "table" then
			-- Handle multiple Set-Cookie headers
			for _, cookie in ipairs(v) do
				buf:put("Set-Cookie: ", cookie, "\n")
			end
		else
			buf:put(h, ": ", v, "\n")
		end
	end
	buf:put("\n", content or "")
	local _, err = client:send(buf:get())
	if err then
		return nil, "failed to send response: " .. err
	end

	if self.logger:level() <= 10 then
		local elapsed_time = os.clock() - start_time
		local log_msg = {
			vhost = host,
			method = method,
			query = query,
			status = status,
			size = #content,
			time = string.format("%.4f", elapsed_time),
		}
		for _, h in ipairs(self.__config.log_headers) do
			if headers[h] then
				log_msg[h] = headers[h]
			end
		end
		self.logger:log(log_msg, 10)
	end
	return response_headers["connection"]
end

local server_serve = function(self)
	local server_forks = {}
	local server_fork_count = 0

	local server = assert(socket.tcp())
	server:setoption("reuseaddr", true)
	server:setoption("reuseport", true)
	assert(server:bind(self.__config.ip, self.__config.port))
	server:listen(self.__config.backlog)
	server:settimeout(0)
	local ip, port = server:getsockname()
	self.logger:log({
		msg = "Started HTTP server",
		ip = ip,
		port = tonumber(port),
		backlog = self.__config.backlog,
		fork_limit = self.__config.fork_limit,
		requests_per_fork = self.__config.requests_per_fork,
		log_level = self.logger:level(),
		log_level_str = self.logger:level_str(),
	})

	while true do
		-- Do house keeping
		for i = 1, server_fork_count do
			local id = std.ps.waitpid(-1)
			if server_forks[id] then
				server_fork_count = server_fork_count - 1
				server_forks[id] = nil
			end
		end
		local _, _, timeout = socket.select({ server }, nil, 1)
		if not timeout then
			if server_fork_count < self.__config.fork_limit then
				local client, err = server:accept()
				local pid = 1
				pid = std.ps.fork()
				if pid < 0 then
					self.logger:log("failed to fork for request processing", "error")
				end

				if pid > 0 then
					server_forks[pid] = os.time()
					server_fork_count = server_fork_count + 1
				end

				if pid == 0 and client then
					local client_ip = client:getpeername()
					local count = 1
					local ssl_client, err
					if self.__config.ssl then
						local cfg = {
							mode = "server",
							keyfile = self.__config.ssl.default.key,
							certfile = self.__config.ssl.default.cert,
						}
						-- Create the default context and wrap socket
						local default_ctx = ssl.newcontext(cfg)
						ssl_client, err = ssl.wrap(client, cfg)

						if not ssl_client then
							self.logger:log("failed to wrap client with SSL: " .. err, "error")
							client:close()
							os.exit(1)
						end

						-- Add additional contexts for SNI
						if self.__config.ssl.hosts then
							for hostname, cert_config in pairs(self.__config.ssl.hosts) do
								local host_cfg = {
									mode = "server",
									keyfile = cert_config.key,
									certfile = cert_config.cert,
								}
								local host_ctx = ssl.newcontext(host_cfg)
								ssl_client:add_sni_context(hostname, host_ctx)
							end
						end
						local status, err = ssl_client:dohandshake()
						if not status then
							self.logger:log("SSL handshake failed: " .. err, "debug")
							ssl_client:close()
							os.exit(1)
						end
					end
					repeat
						local state, err = self:process_request(ssl_client or client, client_ip, count)
						if err then
							if err == "closed" then
								self.logger:log("client closed connection", "debug")
							else
								self.logger:log(err, "error")
							end
							state = "close"
						end
						count = count + 1
					until state == "close" or count > self.__config.requests_per_fork
					if ssl_client then
						ssl_client:close()
					end
					client:close()
					os.exit(0)
				end
			else
				self.logger:log("fork limit reached", "error")
			end
		end
	end
end

local sample_handle = function()
	return "Hi there!", 200, {}
end

--[[

    Format of the config.ssl section:
    {
       default = { cert = "path/to/cert", key = "path/to/key" },
       hosts = {
           ["domain1.com"] = { cert = "path/to/cert1", key = "path/to/key1" },
           ["domain2.com"] = { cert = "path/to/cert2", key = "path/to/key2" }
       }
    }

]]

local server_configure = function(self, config)
	local config = config or {}
	self.__config = std.tbl.merge(self.__config, config)
	self.logger:set_level(self.__config.log_level)
	if self.__config.ssl then
		if self.__config.ssl.default then
			if
				not std.fs.file_exists(self.__config.ssl.default.cert)
				or not std.fs.file_exists(self.__config.ssl.default.key)
			then
				return nil, "can't find default SSL cert/key"
			end
		end
		if self.__config.ssl.hosts then
			for domain, ssl in pairs(self.__config.ssl.hosts) do
				if not std.fs.file_exists(ssl.cert) or not std.fs.file_exists(ssl.key) then
					return nil, "Can't find SSL cert for the " .. domain .. " domain"
				end
			end
		end
	end
	return true
end

local server_new = function(config, handle)
	local config = config or {}
	local handle = handle or sample_handle

	local srv = {
		__config = {
			ip = "127.0.0.1",
			port = 8080,
			backlog = 256,
			fork_limit = 64,
			requests_per_fork = 512,
			max_body_size = 1024 * 1024 * 5, -- 5 megabytes is plenty.
			request_line_limit = 1024 * 8, -- 8Kb for the request line or a single header is HUGE! I'm too generous here.
			compression = {
				enabled = true,
				min_size = 4096, -- Do not compress files smaller than 4Kb
				types = { -- MIME types that are eligible for compression
					["text/html"] = true,
					["text/plain"] = true,
					["text/css"] = true,
					["text/javascript"] = true,
					["image/svg+xml"] = true,
					["application/json"] = true,
					["application/rss+xml"] = true,
				},
			},
			log_level = "access",
			log_headers = { "referer", "x-real-ip", "user-agent" }, -- request headers to include in the access log.
		},
		handle = handle,
		logger = std.logger.new("access"),
		process_request = server_process_request,
		configure = server_configure,
		serve = server_serve,
	}
	local ok, err = srv:configure(config)
	if not ok then
		return nil, err
	end
	return srv
end

return { new = server_new }
