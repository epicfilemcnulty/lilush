-- SPDX-FileCopyrightText: © 2023 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: GPL-3.0-or-later

local std = require("std")
local url = require("socket.url")
local http = require("socket.http")
local ltn12 = require("ltn12")
local socket = require("socket")
-- Soon to be replaced with miniz...
--local libdeflate = require("libdeflate")
local json = require("cjson")

local _M = {}
local mime_types = {
	-- Should probably add `charset=utf-8` clause to the Content-Type response header
	-- when MIME type belongs to the text family
	["text/html"] = { html = true, htm = true, shtml = true },
	["text/css"] = { css = true },
	["text/plain"] = { txt = true },
	["text/calendar"] = { ics = true },
	["text/xml"] = { xml = true },
	["text/csv"] = { csv = true },
	["text/markdown"] = { md = true, markdown = true },
	["text/djot"] = { dj = true, djot = true },
	["text/javascript"] = { js = true },

	["font/woff"] = { woff = true },
	["font/woff2"] = { woff2 = true },
	["font/otf"] = { otf = true },
	["font/ttf"] = { ttf = true },

	["image/gif"] = { gif = true },
	["image/png"] = { png = true },
	["image/jpeg"] = { jpg = true, jpeg = true },
	["image/tiff"] = { tif = true, tiff = true },
	["image/x-icon"] = { ico = true },
	["image/svg+xml"] = { svg = true, svgz = true },
	["image/webp"] = { webp = true },

	["audio/mpeg"] = { mp3 = true },
	["audio/ogg"] = { ogg = true },
	["audio/wav"] = { wav = true },

	["video/x-msvideo"] = { avi = true },
	["video/mpeg"] = { mpeg = true },
	["video/mp4"] = { mp4 = true },
	["video/webm"] = { webm = true },

	["application/atom+xml"] = { atom = true },
	["application/rss+xml"] = { rss = true },
	["application/json"] = { json = true },
	["application/lua"] = { lua = true },
	["application/pdf"] = { pdf = true },
	["application/zip"] = { zip = true },
	["application/x-tar"] = { tar = true },
	["application/x-bzip"] = { bz = true },
	["application/x-bzip2"] = { bz2 = true },
	["application/gzip"] = { gz = true, gzip = true },
	["application/epub+zip"] = { epub = true },

	["application/octet-stream"] = { bin = true, exe = true, dll = true, iso = true, img = true, dmg = true },
}

local mime_type = function(file)
	local file = file or ""
	local extension = file:match("%.(%w+)$")
	if extension then
		for t, exts in pairs(mime_types) do
			if exts[extension] then
				return t
			end
		end
	end
	return "application/octet-stream"
end

_M.mime_type = mime_type

_M.url_escape = function(str)
	if str then
		str = string.gsub(str, "\n", "\r\n")
		str = string.gsub(str, "([^%w %-%_%.%~%%])", function(c)
			return string.format("%%%02X", string.byte(c))
		end)
		str = string.gsub(str, " ", "+")
	end
	return str
end

local html_unescape = function(str)
	str = string.gsub(str, "&amp;", "&")
	local entities = {
		["&lt;"] = "<",
		["&gt;"] = ">",
		["&quot;"] = '"',
		["&apos;"] = "’",
	}
	str = string.gsub(str, "&%a+;", entities)
	str = string.gsub(str, "&#(%d+);", function(n)
		local num = tonumber(n)
		if num <= 255 then
			return string.char(num)
		end
		return std.utf.char(num)
	end)
	str = string.gsub(str, "&#x(%x+);", function(n)
		local num = tonumber(n, 16)
		if num <= 255 then
			return string.char(num)
		end
		return std.utf.char(num)
	end)
	return str
end

local html_escape = function(str)
	local str = str:gsub("<", "&lt;")
	str = str:gsub(">", "&gt;")
	return str
end

_M.html_unescape = html_unescape
_M.html_escape = html_escape

local html_to_djot = function(html)
	local djot = html:gsub("<div[^>]->(.-)</div>", "\n%1\n\n")
	djot = djot:gsub("<table>(.-)</table>", "\n[]\n")
	djot = djot:gsub("<p>(.-)</p>", "%1\n\n")
	djot = djot:gsub("<strong>(.-)</strong>", "*%1*")
	djot = djot:gsub("</?ul>", "\n")
	djot = djot:gsub("</?ol>", "\n")
	djot = djot:gsub("<hr/>", "\n  -------------- \n\n")
	djot = djot:gsub("<br/>", "\\")
	djot = djot:gsub("<h%d>(.-)</h%d>", "\n### %1\n\n")
	djot = djot:gsub("<li>(.-)</li>", "*  %1\n")
	djot = djot:gsub("<pre><code>(.-)</code></pre>", "\n```\n%1\n```\n\n")
	djot = djot:gsub('<a href="([^"]+)">(.-)</a>', "[%2](%1)")
	djot = djot:gsub("<code>(.-)</code>", "`%1`")
	return djot
end

_M.html_to_djot = html_to_djot

local make_form_data = function(items)
	local boundary = std.uuid()
	local boundary_line = "--" .. boundary
	local content_type_header = "multipart/form-data; boundary=" .. boundary
	local t = {}

	for i, item in ipairs(items) do
		local content = item.content or ""
		local name = item.name
		local filename, mime
		if item.path and std.file_exists(item.path) then
			content = std.read_file(item.path)
			filename = item.path:match("[^/]+$")
			mime = mime_type(filename)
		end
		if item.mime then
			mime = item.mime
		end
		local c = boundary_line .. "\r\n" .. 'Content-Disposition: form-data; name="' .. name .. '"'
		if filename then
			c = c .. '; filename="' .. filename .. '"'
			c = c .. "\r\nContent-Type: " .. mime .. "\r\n\r\n" .. content
		else
			c = c .. "\r\n\r\n" .. content
		end
		table.insert(t, c)
	end

	return content_type_header, table.concat(t, "\r\n") .. "\r\n" .. boundary_line .. "--"
end

_M.make_form_data = make_form_data

local request = function(uri, options, timeout)
	local options = options or {}
	local timeout = timeout or 1 -- default timeout is 1 second

	local defaults = { method = "GET", body = "", headers = {} }
	local parsed_url = url.parse(uri)

	defaults.headers["Host"] = parsed_url.host
	if parsed_url.scheme == "https" then
		defaults.server_name = parsed_url.host
	end
	defaults.scheme = parsed_url.scheme
	options = std.merge_tables(defaults, options)
	options.url = uri
	http.TIMEOUT = timeout
	local body = {}
	options.sink = ltn12.sink.table(body)

	if #options.body > 0 then
		options.headers["content-length"] = string.len(options.body)
		options.source = ltn12.source.string(options.body)
	end

	local result, status, headers, status_line = http.request(options)
	if result == 1 then
		return { body = table.concat(body), status = status, headers = headers }
	end
	return nil, status
end

_M.request = request

-- HTTP Server related stuff below
_M.parse_args = function(body)
	local args = {}
	for k, v in body:gmatch("([^=]+)=([^&]+)&?") do
		local value = v:gsub("%+", " ") -- Bring back spaces!
		value = url.unescape(value)
		args[k] = html_escape(value)
	end
	return args
end

_M.parse_form_data = function(boundary, body)
	local args = {}
	local pattern = string.format("(.-)--%s", boundary)
	for part in body:gmatch(pattern) do
		local name = part:match([[^.-name="([^"]+)"]])
		local filename = part:match([[^.-filename="([^"]-)"]])
		if name then
			if filename and #filename > 0 then
				local s, e, cap = part:find("^.-Content%-Type:%s*([^\r\n%s]+)")
				args[name] = { filename = filename, content = part:sub(e + 5):sub(1, -3), content_type = cap }
			else
				local s, e = part:find([[^.-name="[^"]+"%s-]])
				local value = part:sub(e + 5):sub(1, -3)
				value = value:gsub("%+", " ")
				value = url.unescape(value)
				args[name] = html_escape(value)
			end
		end
	end
	return args
end

_M.log = function(msg, level)
	local level = level or "info"
	if _M.server_config.log.levels[level] and _M.server_config.log.levels[level] >= _M.server_config.log.level then
		local log_msg_base = { level = level, ts = os.date() }
		if type(msg) ~= "table" then
			msg = { msg = msg }
		end
		msg = std.merge_tables(log_msg_base, msg)
		local log_json = json.encode(msg)
		print(log_json)
	end
end

-- HTTP Server defaults
_M.server_config = {
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
	log = { level = 1, levels = { debug = 0, info = 1, warn = 2, error = 3, access = 3 } },
	access_log = { enabled = true, headers = { "referer", "x-real-ip", "user-agent" } }, -- request headers to include in the access log.
}

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

local function process_request(client, handle, count)
	local start_time = os.clock()
	local lines = {}
	local line = ""
	repeat
		line, err = client:receive()
		if not line then
			return nil, err
		end
		if line ~= "" then
			if #line > _M.server_config.request_line_limit then
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
		if content_length > _M.server_config.max_body_size then
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
		and _M.server_config.compression.enabled
	then
		compress_output = true
	end

	local content, status, response_headers = handle(method, query, args, headers, body)
	response_headers = response_headers or {}
	if not response_headers["content-type"] then
		response_headers["content-type"] = "text/html"
	end
	if content and #content > 0 then
		if
			compress_output
			and _M.server_config.compression.types[response_headers["content-type"]]
			and #content >= _M.server_config.compression.min_size
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
	if (headers["connection"] and headers["connection"] == "close") or count == _M.server_config.requests_per_fork then
		response_headers["connection"] = "close"
	end

	local response = "HTTP/1.1 " .. tostring(status) .. " \n"
	for h, v in pairs(response_headers) do
		response = response .. h .. ": " .. v .. "\n"
	end
	response = response .. "\n" .. content or ""
	local _, err = client:send(response)
	if err then
		return nil, "failed to send response: " .. err
	end

	if _M.server_config.access_log.enabled and host ~= _M.server_config.metrics_host then
		local elapsed_time = os.clock() - start_time
		local log_msg = {
			vhost = host,
			method = method,
			query = query,
			status = status,
			size = #content,
			time = string.format("%.4f", elapsed_time),
		}
		for _, h in ipairs(_M.server_config.access_log.headers) do
			if headers[h] then
				log_msg[h] = headers[h]
			end
		end
		_M.log(log_msg, "access")
	end
	return response_headers["connection"]
end

local server_forks = {}
local server_fork_count = 0

_M.server = function(ip, port, handle)
	local ip = ip or "127.0.0.1"
	local port = port or 8080

	local handle = handle or function()
		return "Hi there!", 200, {}
	end

	local server = assert(socket.tcp())
	assert(server:bind(ip, port))
	server:listen(_M.server_config.backlog)
	server:settimeout(0)
	ip, port = server:getsockname()
	_M.log({
		msg = "Started HTTP server",
		ip = ip,
		port = port,
		config = "backlog="
			.. _M.server_config.backlog
			.. ", fork_limit="
			.. _M.server_config.fork_limit
			.. ", requests_per_fork="
			.. _M.server_config.requests_per_fork,
	})

	while true do
		-- Do house keeping
		for i = 1, server_fork_count do
			local id = std.waitpid(-1)
			if server_forks[id] then
				server_fork_count = server_fork_count - 1
				server_forks[id] = nil
			end
		end
		local _, _, timeout = socket.select({ server }, nil, 1)
		if not timeout then
			if server_fork_count < _M.server_config.fork_limit then
				local client, err = server:accept()

				local pid = 1
				pid = std.fork()
				if pid < 0 then
					_M.log("failed to fork for request processing", "error")
				end

				if pid > 0 then
					server_forks[pid] = os.time()
					server_fork_count = server_fork_count + 1
				end

				if pid == 0 and client then
					local count = 1
					repeat
						local state, err = process_request(client, handle, count)
						if err then
							if err == "closed" then
								_M.log("client closed connection", "debug")
							else
								_M.log(err, "error")
							end
							state = "close"
						end
						count = count + 1
					until state == "close" or count > _M.server_config.requests_per_fork
					client:close()
					os.exit(0)
				end
			else
				_M.log("fork limit reached", "error")
			end
		end
	end
end

return _M
