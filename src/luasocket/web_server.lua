-- SPDX-FileCopyrightText: © 2023 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: GPL-3.0-or-later
local std = require("std")
local socket = require("socket")
local json = require("cjson.safe")
local buffer = require("string.buffer")

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

local server_process_request = function(self, client, count)
	local start_time = os.clock()
	local lines = {}
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
		premature_error(client, 501, "Sorry, can't handle transfer-encoding yet\n")
		return nil, "transfer-encoding"
	end
	if not headers.host then
		premature_error(client, 400, "No Host header\n")
		return nil, "no Host header"
	end
	local host = headers.host or "localhost"
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

	local content, status, response_headers = self.handle(
		method,
		query,
		args,
		headers,
		body,
		{ logger = self.logger, metrics_host = self.__config.metrics_host }
	)
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
			--[[ replace with gzip as soon as uzlib integration is ready...
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
		buf:put(h, ": ", v, "\n")
	end
	buf:put("\n", content or "")
	local _, err = client:send(buf:get())
	if err then
		return nil, "failed to send response: " .. err
	end

	if self.logger:level() <= 10 and not host:match("^" .. self.__config.metrics_host) then
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
					local count = 1
					repeat
						local state, err = self:process_request(client, count)
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

local server_new = function(ip, port, handle)
	local ip = ip or "127.0.0.1"
	local port = port or 8080
	local handle = handle or sample_handle

	return {
		__config = {
			ip = ip,
			port = port,
			backlog = 256,
			fork_limit = 64,
			requests_per_fork = 512,
			max_body_size = 1024 * 1024 * 5, -- 5 megabytes is plenty.
			request_line_limit = 1024 * 8, -- 8Kb for the request line or a single header is HUGE! I'm too generous here.
			metrics_host = "reliw.stats",
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
			log_headers = { "referer", "x-real-ip", "user-agent" }, -- request headers to include in the access log.
		},
		handle = handle,
		logger = std.logger.new("access"),
		process_request = server_process_request,
		serve = server_serve,
	}
end

return { new = server_new }
