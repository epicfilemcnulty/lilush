local api = require("reliw.api")
local auth = require("reliw.auth")
local tmpls = require("reliw.templates")
local metrics = require("reliw.metrics")
local storage = require("reliw.store")

local handle = function(method, query, args, headers, body, ctx)
	local host = headers.host or "localhost"
	local ctx = ctx or {}
	local client = ctx.client -- Get the client socket
	local srv_cfg = ctx.cfg
	local db, store_err = storage.new(srv_cfg)
	if not db then
		if ctx.logger and ctx.logger.log then
			ctx.logger:log({
				msg = "store init failed",
				process = srv_cfg and srv_cfg.process or "server",
				error = tostring(store_err),
				host = host,
				query = query,
				method = method,
			}, "error")
		end
		return "Service Unavailable", 503, { ["content-type"] = "text/plain" }
	end

	-- Remove port from the host header
	if not host:match("^%[") then
		host = host:match("^([^:]+)")
	else
		-- IPv6 as the Host needs special treatment
		host = host:match("^%[(.+)%]")
	end

	local blocked, rule, ip_header = api.check_waf(db, host, query, headers)
	if blocked then
		local ip = headers[ip_header]
		api.add_waffer(db, ip)
		ctx.logger:log({ msg = "blocked by WAF", waf_rule = rule, query = query, vhost = host, ip = ip }, 30)
		db:close()
		return "Fuck Off", 301, {
			["location"] = "http://127.0.0.1/Fuck_Off",
			["content-type"] = "text/rude",
		}
	end
	local proxy_config = api.proxy_config(db, host)
	if proxy_config then
		local proxy = require("reliw.proxy")
		local target = {
			scheme = proxy_config.scheme or "http",
			host = proxy_config.target,
			port = proxy_config.port,
			tls_cafile = proxy_config.tls_cafile,
			tls_capath = proxy_config.tls_capath,
			tls_handshake_timeout = proxy_config.tls_handshake_timeout,
			tls_insecure = proxy_config.tls_insecure,
			tls_no_verify = proxy_config.tls_no_verify,
			no_verify_mode = proxy_config.no_verify_mode,
		}

		ctx.logger:log({
			msg = "proxying request",
			target_host = target.host,
			target_port = target.port,
			method = method,
			query = query,
		}, "debug")

		local content, status, headers = proxy.handle(client, method, query, headers, body, target)
		if not content then
			ctx.logger:log("proxy error: " .. tostring(status), "error")
			db:close()
			return "proxy failed: " .. tostring(status), 502
		end

		-- Remove any transfer-encoding headers and set correct content-length
		if headers then
			if headers["transfer-encoding"] then
				headers["transfer-encoding"] = nil
			end
			headers["content-length"] = tostring(#content)
		end

		ctx.logger:log({
			msg = "proxy response",
			status = status,
			content_length = #content,
		}, "debug")

		db:close()
		return content, status, headers
	end
	local response_headers = { ["content-type"] = "text/html" }
	local status = 200
	local default_css_file = "/css/default.css"
	local user_tmpl = api.get_userdata(db, host, "template.lua")
	local index = api.entry_index(db, host, query)
	if not index then
		local hit_count = metrics.update(db, "unknown", method, host .. query, 404)
		db:close()
		return tmpls.error_page(404, hit_count, user_tmpl), 404, response_headers
	end
	local metadata = api.entry_metadata(db, host, index)
	if not metadata then
		ctx.logger:log("no metadata found for query " .. query, 0)
		local hit_count = metrics.update(db, host, method, query, 500)
		db:close()
		return tmpls.error_page(500, hit_count, user_tmpl), 500, response_headers
	end

	local err_img = metadata.error or {}
	-- Require valid auth first
	if metadata.auth then
		if metadata.auth.logout then
			local content, status, headers = auth.logout(db, headers)
			db:close()
			return content, status, headers
		end
		if metadata.auth.login then
			local vars = {
				css_file = metadata.css_file or default_css_file,
				favicon_file = metadata.favicon_file or "/images/favicon.svg",
				title = "May we see your papers, please?",
				class = "login",
			}
			local resp, status, r_headers = auth.login_page(db, method, query, args, headers, body)
			if not r_headers then
				resp = tmpls.render_page(resp, vars, user_tmpl)
			else
				response_headers = r_headers
			end
			local hit_count = metrics.update(db, host, method, query, status)
			if status >= 400 then
				db:close()
				return tmpls.error_page(status, hit_count, user_tmpl, err_img[tostring(status)]),
					status,
					response_headers
			end
			db:close()
			return resp, status, response_headers
		end
		local authorized = auth.authorized(db, headers, metadata.auth)
		if not authorized then
			db:close()
			return "Just a second, please",
				302,
				{
					["set-cookie"] = "rlw_redirect=" .. query,
					["location"] = "/login",
				}
		end
	end
	-- See if the method is allowed
	if not metadata.methods[method] then
		local hit_count = metrics.update(db, host, method, query, 405)
		local allow = ""
		for m, _ in pairs(metadata.methods) do
			allow = allow .. m .. ", "
		end
		response_headers["allow"] = allow:sub(1, -3) -- remove last comma and space
		db:close()
		return tmpls.error_page(405, hit_count, user_tmpl, err_img["405"]), 405, response_headers
	end
	-- Check rate limits
	if metadata.rate_limit and metadata.rate_limit[method] then
		local remote_ip = headers["x-real-ip"]
		-- better move all this whitelist stuff into a dedicated func
		local whitelisted = metadata.rate_limit.whitelisted_ip or "127.0.66.6"
		if remote_ip ~= whitelisted then
			local count = api.check_rate_limit(db, host, method, query, remote_ip, metadata.rate_limit[method].period)
			if count and count > metadata.rate_limit[method].limit then
				local hit_count = metrics.update(db, host, method, query, 429)
				db:close()
				return tmpls.error_page(429, hit_count, user_tmpl, err_img["429"]), 429, response_headers
			end
		end
	end

	local content, hash, size, mime, title = api.get_content(db, host, query, metadata)
	if not content then
		local hit_count = metrics.update(db, host, method, query, 404)
		db:close()
		return tmpls.error_page(404, hit_count, user_tmpl, err_img["404"]), 404, response_headers
	end
	local ttl = metadata.cache_control or "max-age=86400"

	local request_etag = headers["if-none-match"] or ""
	if method == "HEAD" or (method == "GET" and request_etag == hash) then
		if method ~= "HEAD" then
			status = 304
		end
		response_headers["content-length"] = size
		if mime ~= "text/djot" then
			response_headers["content-type"] = mime
		end
		response_headers["etag"] = hash
		response_headers["cache-control"] = ttl
		metrics.update(db, host, method, query, status)
		db:close()
		return "", status, response_headers
	end

	local tmpl_vars = {
		css_file = metadata.css_file or default_css_file,
		favicon_file = metadata.favicon_file or "/images/favicon.svg",
		title = title,
		published = os.date("%A, %d of %B, %Y", os.time()),
		class = "page",
	}
	if mime == "application/lua" then
		local r_headers
		content, status, r_headers = content(method, query, args, headers, body)
		if not status then
			local hit_count = metrics.update(db, host, method, query, 500)
			db:close()
			return tmpls.error_page(500, hit_count, user_tmpl, err_img["500"]), 500, response_headers
		end
		if r_headers then
			response_headers = r_headers
		else
			content = tmpls.render_page(content, tmpl_vars, user_tmpl)
		end
	elseif mime == "text/djot" or mime == "text/markdown" then
		if headers.accept and headers.accept:match("text/markdown") then
			response_headers["content-type"] = mime
		else
			content = tmpls.render_page(tmpls.markdown_to_html(content), tmpl_vars, user_tmpl)
		end
	else
		response_headers["content-type"] = mime
	end
	if metadata.cache_control or mime:match("css") or mime:match("image") then
		response_headers["etag"] = hash
		response_headers["cache-control"] = ttl
	end
	metrics.update(db, host, method, query, status)
	db:close()
	return content, status, response_headers
end

return { func = handle }
