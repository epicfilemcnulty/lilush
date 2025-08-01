-- SPDX-FileCopyrightText: © 2023 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: GPL-3.0-or-later
local std = require("std")
local url = require("socket.url")
local http = require("socket.http")
local ltn12 = require("ltn12")
local socket = require("socket")
local json = require("cjson.safe")

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
	local client = {}
	local buffer = ""
	local connected = false
	local sock = nil

	-- Parse SSE event from buffer
	local function parse_event(data)
		local event = {
			event = "message",
			data = "",
		}

		for line in data:gmatch("[^\r\n]+") do
			if line:match("^event: ") then
				event.event = line:sub(8)
			elseif line:match("^data: ") then
				event.data = line:sub(7)
			elseif line:match("^id: ") then
				event.id = line:sub(5)
			elseif line:match("^retry: ") then
				event.retry = tonumber(line:sub(8))
			end
		end

		-- Parse JSON data if present
		if event.data and event.data ~= "" then
			local parsed_data = json.decode(event.data)
			if parsed_data then
				event.data = parsed_data
			end
		end

		return event
	end
	-- Process the buffer for complete events
	local function process_buffer()
		while true do
			local event_end = buffer:find("\n\n")
			if not event_end then
				break
			end

			local event_data = buffer:sub(1, event_end - 1)
			buffer = buffer:sub(event_end + 2)

			local event = parse_event(event_data)

			-- Call the appropriate callback
			if callbacks[event.event] then
				callbacks[event.event](event.data)
			elseif callbacks.message then
				callbacks.message(event)
			end

			-- If this is the "done" event, close the connection
			if event.event == "done" then
				client:close()
				if callbacks.close then
					callbacks.close()
				end
				break
			end
		end
	end

	-- Connect to the SSE stream
	function client:connect()
		if connected then
			return false, "Already connected"
		end

		-- Prepare request headers
		local headers = {
			["Content-Type"] = "application/json",
			["Accept"] = "text/event-stream",
			["Cache-Control"] = "no-cache",
			["Connection"] = "keep-alive",
		}

		-- Add any custom headers from options
		if options.headers then
			for k, v in pairs(options.headers) do
				headers[k] = v
			end
		end

		local body = options.body or ""

		sock = socket.tcp()

		local parsed_url = url.parse(uri)
		local ok, err = sock:connect(parsed_url.host, parsed_url.port)
		if not ok and err ~= "timeout" then
			return false, "Connection failed: " .. err
		end
		sock:settimeout(0) -- Non-blocking sock

		local method = options.method or "GET"
		-- Construct HTTP request
		local request = method .. " " .. parsed_url.path .. " HTTP/1.1\r\n"
		request = request .. "Host: " .. parsed_url.host .. ":" .. parsed_url.port .. "\r\n"
		for k, v in pairs(headers) do
			request = request .. k .. ": " .. v .. "\r\n"
		end
		request = request .. "Content-Length: " .. #body .. "\r\n"
		request = request .. "\r\n"
		request = request .. body

		-- Send the request
		local ok, err = sock:send(request)
		if not ok then
			sock:close()
			return false, "Failed to send request: " .. err
		end

		connected = true

		-- Trigger connect callback
		if callbacks.connect then
			callbacks.connect()
		end

		return true
	end
	-- Update function to process incoming data
	function client:update()
		if not connected or not sock then
			return false
		end

		-- Try to receive data
		local chunk, status, partial = sock:receive("*a")
		local data = chunk or partial

		if data and #data > 0 then
			buffer = buffer .. data
			process_buffer()
		end

		-- Check if connection is closed
		if status == "closed" then
			connected = false
			sock:close()
			sock = nil

			if callbacks.close then
				callbacks.close()
			end

			return false
		end

		return true
	end
	-- Close the connection
	function client:close()
		if connected and sock then
			sock:close()
			sock = nil
			connected = false
			if callbacks.close then
				callbacks.close()
			end
		end
	end

	-- Check if still connected
	function client:is_connected()
		return connected
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
