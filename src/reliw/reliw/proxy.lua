local socket = require("socket")
local ssl = require("ssl")

local proxy = {}

local function read_chunk(upstream)
	local line = upstream:receive("*l")
	if not line then
		return nil, "failed to read chunk size"
	end

	-- RFC 7230 allows chunk extensions after chunk-size.
	local size_hex = line:match("^%s*([0-9A-Fa-f]+)")
	local size = size_hex and tonumber(size_hex, 16)
	if not size then
		return nil, "invalid chunk size: " .. line
	end

	if size == 0 then
		-- Read trailer-part until an empty line.
		while true do
			local trailer_line, trailer_err = upstream:receive("*l")
			if not trailer_line then
				return nil, "failed to read chunk trailer: " .. tostring(trailer_err)
			end
			if trailer_line == "" then
				break
			end
		end
		return 0
	end

	local chunk = upstream:receive(size)
	if not chunk then
		return nil, "failed to read chunk data"
	end

	-- Read the trailing CRLF
	local chunk_tail = upstream:receive("*l")
	if not chunk_tail then
		return nil, "failed to read chunk terminator"
	end

	return chunk
end

local function stream_response(upstream)
	local line = upstream:receive()
	if not line then
		return nil, "failed to read response line"
	end

	-- Parse status line
	local version, status, reason = line:match("^(HTTP/%d%.%d)%s+(%d+)%s+(.*)$")
	status = tonumber(status)
	if not status then
		return nil, "invalid response status line: " .. line
	end

	-- Read headers
	local headers = {}
	local cookies = {} -- Store cookies separately
	while true do
		line = upstream:receive()
		if not line or line == "" then
			break
		end

		local name, value = line:match("^([^:]+):%s*(.+)")
		if name then
			name = name:lower() -- normalize header names to lowercase
			if name == "set-cookie" then
				table.insert(cookies, value)
			else
				headers[name] = value
			end
		end
	end

	-- If we have cookies, add them as separate Set-Cookie headers
	if #cookies > 0 then
		headers["set-cookie"] = cookies
	end

	return status, headers
end

local function connect_upstream(target)
	local upstream, sock_err = socket.tcp()
	if not upstream then
		return nil, "failed to create upstream socket: " .. tostring(sock_err)
	end

	local connect_timeout = target.connect_timeout or 10
	upstream:settimeout(connect_timeout)

	local host = target.host
	local port = target.port or (target.scheme == "https" and 443 or 80)
	local ok, conn_err = upstream:connect(host, port)
	if not ok then
		upstream:close()
		return nil, "failed to connect upstream: " .. tostring(conn_err)
	end

	if target.scheme ~= "https" then
		return upstream, nil
	end

	local tls_cfg = {
		mode = "client",
		server_name = host,
	}
	if target.tls_cafile then
		tls_cfg.cafile = target.tls_cafile
	end
	if target.tls_capath then
		tls_cfg.capath = target.tls_capath
	end
	if target.tls_insecure or target.tls_no_verify or target.no_verify_mode then
		tls_cfg.no_verify_mode = true
	end

	local tls_sock, tls_err = ssl.wrap(upstream, tls_cfg)
	if not tls_sock then
		upstream:close()
		return nil, "failed to wrap upstream tls socket: " .. tostring(tls_err)
	end

	tls_sock:settimeout(target.tls_handshake_timeout or connect_timeout)
	local ok_hs, hs_err = tls_sock:dohandshake()
	if not ok_hs then
		tls_sock:close()
		return nil, "TLS handshake failed: " .. tostring(hs_err)
	end
	tls_sock:settimeout(connect_timeout)

	return tls_sock, nil
end

function proxy.handle(client, method, path, headers, body, target)
	local port = target.port or (target.scheme == "https" and 443 or 80)
	local original_host = headers.host -- Save the original host
	local original_origin = headers.origin -- Save the original origin

	local upstream, upstream_err = connect_upstream(target)
	if not upstream then
		return nil, upstream_err
	end

	-- Build request
	local request = string.format("%s %s HTTP/1.1\r\n", method, path)

	-- Copy headers, but normalize them
	local upstream_headers = {}
	for name, value in pairs(headers) do
		local normalized_name = name:lower()
		if normalized_name == "cookie" then
			upstream_headers["cookie"] = value
		elseif normalized_name == "origin" then
			-- Rewrite origin to match upstream server
			upstream_headers["origin"] = string.format("%s://%s:%s", target.scheme, target.host, port)
		elseif normalized_name == "referer" then
			-- Rewrite referer to match upstream server
			local new_referer =
				value:gsub("https?://" .. original_host, string.format("%s://%s:%s", target.scheme, target.host, port))
			upstream_headers["referer"] = new_referer
		elseif normalized_name ~= "host" then
			upstream_headers[normalized_name] = value
		end
	end

	-- Set the Host header for the upstream server
	upstream_headers["host"] = target.host .. (target.port and (":" .. target.port) or "")

	-- Add X-Forwarded headers
	upstream_headers["x-forwarded-host"] = original_host
	upstream_headers["x-forwarded-proto"] = "https" -- Since your RELIW server is running on HTTPS
	if headers["x-real-ip"] then
		upstream_headers["x-forwarded-for"] = headers["x-real-ip"]
	end

	-- Send headers
	for name, value in pairs(upstream_headers) do
		request = request .. string.format("%s: %s\r\n", name, value)
	end

	if body then
		request = request .. string.format("Content-Length: %d\r\n", #body)
	end

	request = request .. "\r\n"

	if body then
		request = request .. body
	end

	-- Send request
	local bytes, err = upstream:send(request)
	if not bytes then
		upstream:close()
		return nil, "failed to send request: " .. tostring(err)
	end

	-- Get response status and headers
	local status, response_headers = stream_response(upstream)
	if not status then
		upstream:close()
		return nil, response_headers -- error message
	end

	-- Modify response headers for CORS and security
	if response_headers["access-control-allow-origin"] then
		-- If the upstream sends CORS headers, rewrite them to match the original origin
		if original_origin then
			response_headers["access-control-allow-origin"] = original_origin
		else
			response_headers["access-control-allow-origin"] = "https://" .. original_host
		end
	end

	-- Ensure cookies are secure when proxying to HTTPS
	if response_headers["set-cookie"] and type(response_headers["set-cookie"]) == "table" then
		local new_cookies = {}
		for _, cookie in ipairs(response_headers["set-cookie"]) do
			-- Add Secure attribute if not present
			if not cookie:find("Secure") then
				cookie = cookie .. "; Secure"
			end
			-- Rewrite domain if present
			cookie = cookie:gsub("Domain=[^;]+", "Domain=" .. original_host:match("([^:]+)"))
			table.insert(new_cookies, cookie)
		end
		response_headers["set-cookie"] = new_cookies
	end

	-- Now stream the body
	local content = {}

	-- If we have both transfer-encoding and content-length, prefer transfer-encoding
	if response_headers["transfer-encoding"] == "chunked" then
		while true do
			local chunk, err = read_chunk(upstream)
			if not chunk then
				upstream:close()
				return nil, "chunked reading error: " .. tostring(err)
			end

			if chunk == 0 then -- End of chunked data
				break
			end

			table.insert(content, chunk)
		end
	else
		local size = tonumber(response_headers["content-length"])
		if size then
			local remaining = size
			while remaining > 0 do
				local chunk = upstream:receive(math.min(8192, remaining))
				if not chunk then
					upstream:close()
					return nil, "failed to read content-length body"
				end
				table.insert(content, chunk)
				remaining = remaining - #chunk
			end
		else
			-- No content length, read until connection closes
			while true do
				local chunk = upstream:receive(8192)
				if not chunk then
					break
				end
				table.insert(content, chunk)
			end
		end
	end

	upstream:close()
	local final_content = table.concat(content)

	-- Remove conflicting headers
	if response_headers["transfer-encoding"] then
		response_headers["content-length"] = tostring(#final_content)
		response_headers["transfer-encoding"] = nil
	end

	return final_content, status, response_headers
end

return proxy
