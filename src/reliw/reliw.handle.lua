local api = require("reliw.api")
local auth = require("reliw.auth")
local tmpls = require("reliw.templates")
local metrics = require("reliw.metrics")
local store = require("reliw.store")

local handle = function(method, query, args, headers, body, ctx)
	local host = headers.host or "localhost"
	local ctx = ctx or {}
	local client = ctx.client -- Get the client socket
	local srv_cfg = ctx.cfg
	local store = store.new(srv_cfg)

	-- Remove port from the host header
	if not host:match("^%[") then
		host = host:match("^([^:]+)")
	else
		-- IPv6 as the Host needs special treatment
		host = host:match("^%[(.+)%]")
	end

	local blocked, rule = api.check_waf(store, host, query, headers)
	if blocked then
		local ip = headers["x-real-ip"]
		api.add_waffer(store, ip)
		ctx.logger:log({ msg = "blocked by WAF", waf_rule = rule, query = query, vhost = host, ip = ip }, 30)
		return "Fuck Off", 301, {
			["location"] = "http://127.0.0.1/Fuck_Off",
			["content-type"] = "text/rude",
		}
	end
	local proxy_config = api.proxy_config(store, host)
	if proxy_config then
		local proxy = require("reliw.proxy")
		local target = {
			scheme = proxy_config.scheme or "http",
			host = proxy_config.target,
			port = proxy_config.port,
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

		return content, status, headers
	end
	local response_headers = { ["content-type"] = "text/html" }
	local status = 200
	local default_css_file = "/css/default.css"
	local user_tmpl = api.get_userdata(store, host, "template.lua")
	local index = api.entry_index(store, host, query)
	if not index then
		local hit_count = metrics.update(store, host, method, query, 404)
		return tmpls.error_page(404, hit_count, user_tmpl), 404, response_headers
	end
	local metadata = api.entry_metadata(store, host, index)
	if not metadata then
		ctx.logger:log("no metadata found for query " .. query, 0)
		local hit_count = metrics.update(store, host, method, query, 500)
		return tmpls.error_page(500, hit_count, user_tmpl), 500, response_headers
	end

	local err_img = metadata.error or {}
	-- Require valid auth first
	if metadata.auth then
		if metadata.auth.logout then
			return auth.logout(store, headers)
		end
		if metadata.auth.login then
			local vars = {
				css_file = metadata.css_file or default_css_file,
				favicon_file = metadata.favicon_file or "/images/favicon.svg",
				title = "May we see your papers, please?",
				class = "login",
			}
			local resp, status, r_headers = auth.login_page(store, method, query, args, headers, body)
			if not r_headers then
				resp = tmpls.render_page(resp, vars, user_tmpl)
			else
				response_headers = r_headers
			end
			local hit_count = metrics.update(store, host, method, query, status)
			if status >= 400 then
				return tmpls.error_page(status, hit_count, user_tmpl, err_img[tostring(status)]),
					status,
					response_headers
			end
			return resp, status, response_headers
		end
		local authorized = auth.authorized(store, headers, metadata.auth)
		if not authorized then
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
		local hit_count = metrics.update(store, host, method, query, 405)
		local allow = ""
		for method, _ in pairs(metadata.methods) do
			allow = allow .. method .. ", "
		end
		response_headers["allow"] = allow:sub(1, -3) -- remove last comma and space
		return tmpls.error_page(405, hit_count, user_tmpl, err_img["405"]), 405, response_headers
	end
	-- Check rate limits
	if metadata.rate_limit and metadata.rate_limit[method] then
		local remote_ip = headers["x-real-ip"]
		-- better move all this whitelist stuff into a dedicated func
		local whitelisted = metadata.rate_limit.whitelisted_ip or "127.0.66.6"
		if remote_ip ~= whitelisted then
			local count =
				api.check_rate_limit(store, host, method, query, remote_ip, metadata.rate_limit[method].period)
			if count and count > metadata.rate_limit[method].limit then
				local hit_count = metrics.update(store, host, method, query, 429)
				return tmpls.error_page(429, hit_count, user_tmpl, err_img["429"]), 429, response_headers
			end
		end
	end

	local content, hash, size, mime, title = api.get_content(store, host, query, metadata)
	if not content then
		local hit_count = metrics.update(store, host, method, query, 404)
		return tmpls.error_page(404, hit_count, user_tmpl, err_img["404"]), 404, response_headers
	end
	local ttl = metadata.cache_control or "max-age=86400"

	local request_etag = headers["if-none-match"] or ""
	if request_etag == hash or method == "HEAD" then
		if method ~= "HEAD" then
			status = 304
		end
		response_headers["content-length"] = size
		if mime ~= "text/djot" then
			response_headers["content-type"] = mime
		end
		response_headers["etag"] = hash
		response_headers["cache-control"] = ttl
		metrics.update(store, host, method, query, status)
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
			local hit_count = metrics.update(store, host, method, query, 500)
			return tmpls.error_page(500, hit_count, user_tmpl, err_img["500"]), 500, response_headers
		end
		if r_headers then
			response_headers = r_headers
		else
			content = tmpls.render_page(content, tmpl_vars, user_tmpl)
		end
	elseif mime == "text/djot" or mime == "text/markdown" then
		if headers.accept and headers.accept:match("text/djot") then
			response_headers["content-type"] = mime
		else
			content = tmpls.render_page(tmpls.djot_to_html(content), tmpl_vars, user_tmpl)
		end
	else
		response_headers["content-type"] = mime
	end
	if metadata.cache_control or mime:match("css") or mime:match("image") then
		response_headers["etag"] = hash
		response_headers["cache-control"] = ttl
	end
	metrics.update(store, host, method, query, status)
	store:close()
	return content, status, response_headers
end

return { func = handle }
