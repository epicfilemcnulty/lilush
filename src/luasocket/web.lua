-- SPDX-FileCopyrightText: © 2023 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: GPL-3.0-or-later
local std = require("std")
local url = require("socket.url")
local http = require("socket.http")
local ltn12 = require("ltn12")
local socket = require("socket")
local json = require("cjson.safe")
local ssl = require("ssl")

local debug_mode = os.getenv("LILUSH_DEBUG")

local url_escape = function(str)
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

local make_form_data = function(items)
	local boundary = std.uuid()
	local boundary_line = "--" .. boundary
	local content_type_header = "multipart/form-data; boundary=" .. boundary
	local t = {}

	for i, item in ipairs(items) do
		local content = item.content or ""
		local name = item.name
		local filename, mime
		if item.path and std.fs.file_exists(item.path) then
			content = std.fs.read_file(item.path)
			filename = item.path:match("[^/]+$")
			mime = std.mime.type(filename)
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

local request = function(uri, options, timeout)
	local options = options or {}
	local timeout = timeout or 1 -- default timeout is 1 second

	local defaults = { method = "GET", body = "", headers = {} }
	local parsed_url = url.parse(uri)

	defaults.headers["Host"] = parsed_url.host
	defaults.scheme = parsed_url.scheme
	options = std.tbl.merge(defaults, options)
	if parsed_url.scheme == "https" and not options.no_sni then
		options.server_name = options.headers["Host"]
	end
	options.url = uri
	http.TIMEOUT = timeout
	local body = {}
	options.sink = ltn12.sink.table(body)

	if #options.body > 0 then
		options.headers["content-length"] = string.len(options.body)
		options.source = ltn12.source.string(options.body)
	end
	if debug_mode then
		print("--web.request DEBUG: request options table--")
		std.tbl.print(options)
		print("--web.request END of requst options table--")
	end
	local result, status, headers, status_line = http.request(options)
	if result == 1 then
		return { body = table.concat(body), status = status, headers = headers }
	end
	return nil, status
end

local sse_client = function(uri, options, callbacks)
	options = options or {}
	callbacks = callbacks or {}

	local client = {}
	local rx = "" -- raw bytes from socket
	local sse_buf = "" -- decoded body bytes for SSE parsing
	local connected = false
	local closed = false
	local sock = nil
	local response_open = false
	local response_status = nil
	local response_headers = {}
	local chunked = false
	local chunk_state = { mode = "size", size = nil }

	local function header_end_pos(buf)
		local i = buf:find("\r\n\r\n", 1, true)
		local j = buf:find("\n\n", 1, true)
		if i and j then
			if i < j then
				return i, 4
			end
			return j, 2
		end
		if i then
			return i, 4
		end
		if j then
			return j, 2
		end
		return nil
	end

	local function parse_response_headers(h)
		local lines = {}
		for line in h:gmatch("[^\r\n]+") do
			table.insert(lines, line)
		end
		local status_line = lines[1] or ""
		local status = tonumber(status_line:match("^HTTP/%d+%.%d+%s+(%d+)%s"))
		local headers = {}
		for i = 2, #lines do
			local k, v = lines[i]:match("^([^:]+):%s*(.*)$")
			if k then
				headers[k:lower()] = v
			end
		end
		return status, headers
	end

	local function find_event_end(buf)
		local i = buf:find("\r\n\r\n", 1, true)
		local j = buf:find("\n\n", 1, true)
		if i and j then
			if i < j then
				return i, 4
			end
			return j, 2
		end
		if i then
			return i, 4
		end
		if j then
			return j, 2
		end
		return nil
	end

	local function parse_event(data)
		local event = { event = "message", data = "" }
		local data_lines = {}
		for line in data:gmatch("[^\r\n]+") do
			if line:sub(1, 1) == ":" then
				-- comment / keepalive
			elseif line:match("^event:") then
				event.event = (line:match("^event:%s*(.*)$") or "message")
			elseif line:match("^data:") then
				table.insert(data_lines, line:match("^data:%s*(.*)$") or "")
			elseif line:match("^id:") then
				event.id = line:match("^id:%s*(.*)$")
			elseif line:match("^retry:") then
				event.retry = tonumber(line:match("^retry:%s*(.*)$"))
			end
		end
		local raw = table.concat(data_lines, "\n")
		if raw == "[DONE]" then
			event.event = "done"
			event.data = raw
			return event
		end
		event.data = raw
		if raw ~= "" and (raw:sub(1, 1) == "{" or raw:sub(1, 1) == "[") then
			local parsed = json.decode(raw)
			if parsed ~= nil then
				event.data = parsed
			end
		end
		return event
	end

	local function dispatch_event(event)
		if callbacks[event.event] then
			callbacks[event.event](event.data)
		elseif callbacks.message then
			callbacks.message(event)
		end
		if event.event == "done" then
			client:close()
		end
	end

	local function process_sse_buffer()
		while true do
			local pos, delim_len = find_event_end(sse_buf)
			if not pos then
				break
			end
			local event_data = sse_buf:sub(1, pos - 1)
			sse_buf = sse_buf:sub(pos + delim_len)
			if event_data ~= "" then
				dispatch_event(parse_event(event_data))
			end
		end
	end

	local function consume_line(buf)
		local rn = buf:find("\r\n", 1, true)
		local n = buf:find("\n", 1, true)
		if not rn and not n then
			return nil, buf
		end
		local eol, len
		if rn and n then
			if rn < n then
				eol, len = rn, 2
			else
				eol, len = n, 1
			end
		elseif rn then
			eol, len = rn, 2
		else
			eol, len = n, 1
		end
		local line = buf:sub(1, eol - 1)
		return line, buf:sub(eol + len)
	end

	local function decode_chunked()
		while true do
			if chunk_state.mode == "size" then
				local line
				line, rx = consume_line(rx)
				if not line then
					return
				end
				local size_hex = line:match("^%s*([0-9A-Fa-f]+)")
				if not size_hex then
					if callbacks.error then
						callbacks.error("invalid chunk size line")
					end
					client:close()
					return
				end
				local size = tonumber(size_hex, 16)
				if size == 0 then
					client:close()
					return
				end
				chunk_state.size = size
				chunk_state.mode = "data"
			elseif chunk_state.mode == "data" then
				if #rx < chunk_state.size then
					return
				end
				sse_buf = sse_buf .. rx:sub(1, chunk_state.size)
				rx = rx:sub(chunk_state.size + 1)
				-- consume trailing CRLF/LF
				if rx:sub(1, 2) == "\r\n" then
					rx = rx:sub(3)
				elseif rx:sub(1, 1) == "\n" then
					rx = rx:sub(2)
				end
				chunk_state.size = nil
				chunk_state.mode = "size"
			end
		end
	end

	function client:connect()
		if connected then
			return false, "Already connected"
		end

		local parsed_url = url.parse(uri)
		if not parsed_url or not parsed_url.host then
			return false, "bad url: " .. tostring(uri)
		end
		local scheme = parsed_url.scheme or "http"
		local host = parsed_url.host
		local port = tonumber(parsed_url.port) or (scheme == "https" and 443 or 80)
		local path = parsed_url.path or "/"
		if parsed_url.query and #parsed_url.query > 0 then
			path = path .. "?" .. parsed_url.query
		end

		local body = options.body or ""
		local headers = {
			["Accept"] = "text/event-stream",
			["Cache-Control"] = "no-cache",
			["Connection"] = "keep-alive",
			["Content-Type"] = "application/json",
			["User-Agent"] = "lilush-sse-client",
		}
		if options.headers then
			for k, v in pairs(options.headers) do
				if v ~= nil then
					headers[k] = v
				end
			end
		end

		sock = socket.tcp()
		sock:settimeout(options.connect_timeout or 10)
		local ok, err = sock:connect(host, port)
		if not ok then
			sock:close()
			sock = nil
			return false, "Connection failed: " .. tostring(err)
		end

		if scheme == "https" then
			sock = ssl.wrap(sock, {
				mode = "client",
				server_name = host,
				cafile = options.tls_cafile,
				capath = options.tls_capath,
			})
			sock:settimeout(options.handshake_timeout or 10)
			local ok_hs, err_hs = sock:dohandshake()
			if not ok_hs then
				sock:close()
				sock = nil
				return false, "TLS handshake failed: " .. tostring(err_hs)
			end
		end

		sock:settimeout(0)
		local method = options.method or "GET"
		local req = method .. " " .. path .. " HTTP/1.1\r\n"
		local host_hdr = host
		if not ((scheme == "http" and port == 80) or (scheme == "https" and port == 443)) then
			host_hdr = host_hdr .. ":" .. tostring(port)
		end
		req = req .. "Host: " .. host_hdr .. "\r\n"
		for k, v in pairs(headers) do
			req = req .. k .. ": " .. tostring(v) .. "\r\n"
		end
		req = req .. "Content-Length: " .. tostring(#body) .. "\r\n\r\n" .. body

		local ok_send, err_send = sock:send(req)
		if not ok_send then
			sock:close()
			sock = nil
			return false, "Failed to send request: " .. tostring(err_send)
		end

		connected = true
		if callbacks.connect then
			callbacks.connect()
		end
		return true
	end

	function client:update()
		if not connected or not sock or closed then
			return false
		end
		local chunk, status, partial = sock:receive("*a")
		local data = chunk or partial
		if data and #data > 0 then
			rx = rx .. data
		end

		if not response_open then
			local pos, delim_len = header_end_pos(rx)
			if pos then
				local header_blob = rx:sub(1, pos - 1)
				rx = rx:sub(pos + delim_len)
				response_status, response_headers = parse_response_headers(header_blob)
				response_open = true
				local te = (response_headers["transfer-encoding"] or "")
				chunked = te:lower():find("chunked", 1, true) ~= nil
				if callbacks.open then
					callbacks.open(response_status, response_headers)
				end
				if not response_status or response_status < 200 or response_status >= 300 then
					local msg = "bad response status: " .. tostring(response_status)
					if callbacks.error then
						callbacks.error(msg)
					end
					client:close()
					return false
				end
			end
		end

		if response_open and #rx > 0 then
			if chunked then
				decode_chunked()
			else
				sse_buf = sse_buf .. rx
				rx = ""
			end
			process_sse_buffer()
		end

		if status == "closed" then
			client:close()
			return false
		end
		return true
	end

	function client:close()
		if closed then
			return
		end
		closed = true
		connected = false
		if sock then
			sock:close()
			sock = nil
		end
		if callbacks.close then
			callbacks.close()
		end
	end

	function client:is_connected()
		return connected and not closed
	end

	return client
end

-- HTTP Server related stuff below
local parse_args = function(body)
	local args = {}
	for k, v in body:gmatch("([^=]+)=([^&]+)&?") do
		local value = v:gsub("%+", " ") -- Bring back spaces!
		value = url.unescape(value)
		args[k] = html_escape(value)
	end
	return args
end

local parse_form_data = function(boundary, body)
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

return {
	url_escape = url_escape,
	html_escape = html_escape,
	html_unescape = html_unescape,
	html_to_djot = html_to_djot,
	make_form_data = make_form_data,
	request = request,
	sse_client = sse_client,
	parse_args = parse_args,
	parse_form_data = parse_form_data,
}
