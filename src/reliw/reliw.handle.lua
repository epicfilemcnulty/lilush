local std = require("std")
local api = require("reliw.api")
local auth = require("reliw.auth")
local tmpls = require("reliw.templates")
local metrics = require("reliw.metrics")

local handle = function(method, query, args, headers, body, ctx)
	local host = headers.host or "localhost"
	local ctx = ctx or {}
	host = host:match("^([^:]+)") -- make sure to remove port from the host header
	if ctx.metrics_host and host == ctx.metrics_host and query == "/metrics" and method == "GET" then
		return metrics.show()
	end
	local response_headers = { ["content-type"] = "text/html" }
	local status = 200
	local default_css_file = "/css/default.css"

	local user_tmpl = api.get_userdata(host, "template.lua")
	local real_host = host
	local index = api.entry_index(host, query)
	if not index then
		index = api.entry_index("__", query)
		real_host = "__"
	end
	if not index then
		local hit_count = metrics.update(host, method, query, 404)
		return tmpls.error_page(404, hit_count, user_tmpl), 404, response_headers
	end

	local metadata = api.entry_metadata(real_host, index)
	if not metadata then
		local hit_count = metrics.update(host, method, query, 500)
		return tmpls.error_page(500, hit_count, user_tmpl), 500, response_headers
	end

	-- Require valid auth first
	if metadata.auth then
		local authorized = auth.authorized(headers, metadata.auth)
		if not authorized then
			local vars = {
				css_file = metadata.css_file or default_css_file,
				favicon_file = metadata.favicon_file or "/images/favicon.svg",
				title = metadata.title,
			}
			local resp, status, r_headers = auth.login_page(method, query, args, headers, body)
			if not r_headers then
				resp = tmpls.render_page(resp, vars, t)
			else
				response_headers = r_headers
			end
			local hit_count = metrics.update(host, method, query, code)
			if status >= 400 then
				return tmpls.error_page(status, hit_count, user_tmpl), status, response_headers
			end
			return resp, status, response_headers
		end
	end
	-- See if the method is allowed
	if not metadata.methods[method] then
		local hit_count = metrics.update(host, method, query, 405)
		local allow = ""
		for method, _ in pairs(metadata.methods) do
			allow = allow .. method .. ", "
		end
		response_headers["Allow"] = allow:sub(1, -3) -- remove last comma and space
		return tmpls.error_page(405, hit_count, user_tmpl), 405, response_headers
	end
	-- Check rate limits
	if metadata.rate_limit and metadata.rate_limit[method] then
		local remote_ip = headers["x-real-ip"]
		-- better move all this whitelist stuff into a dedicated func
		local whitelisted = metadata.rate_limit.whitelisted_ip or "127.0.66.6"
		if remote_ip ~= whitelisted then
			local count = api.check_rate_limit(host, method, query, remote_ip, metadata.rate_limit[method].period)
			if count and count > metadata.rate_limit[method].limit then
				local hit_count = metrics.update(host, method, query, 429)
				return tmpls.error_page(429, hit_count, user_tmpl), 429, response_headers
			end
		end
	end

	local content, ts, tags
	-- Since API entries for static locations most of the time
	-- won't have `filename`, `size` and `hash` fields, we have
	-- to load the actual file from disk before we can say if it
	-- matches ETAG in the request,
	if metadata.static then
		content = api.get_static_content(host, query, metadata)
		if not content then
			local hit_count = metrics.update(host, method, query, 404)
			return tmpls.error_page(404, hit_count, user_tmpl), 404, response_headers
		end
	end
	local content_type = std.mime.type(metadata.file)

	local request_etag = headers["if-none-match"] or ""
	if request_etag == metadata.hash or method == "HEAD" then
		if method ~= "HEAD" then
			status = 304
		end
		response_headers["content-length"] = metadata.size
		if content_type ~= "text/djot" then
			response_headers["content-type"] = content_type
		end
		response_headers["etag"] = metadata.hash
		response_headers["cache-control"] = metadata.cache_control
		metrics.update(host, method, query, status)
		return "", status, response_headers
	end

	if not metadata.static then
		content, ts, tags = api.get_content(real_host, metadata.file)
	end
	-- Convert comma-separated tags into span-separated =)
	if tags then
		tags = tags:gsub("(%w+),?", "<span class='tags'>%1</span>")
	end
	local tmpl_vars = {
		css_file = metadata.css_file or default_css_file,
		favicon_file = metadata.favicon_file or "/images/favicon.svg",
		title = metadata.title or "",
		published = os.date("%A, %d of %B, %Y", tonumber(ts) or os.time()),
		tags = tags,
		class = "page",
	}
	if content_type == "application/lua" then
		local r_headers
		content, status, r_headers = content(method, query, args, headers, body)
		if not status then
			local hit_count = metrics.update(host, method, query, 500)
			return tmpls.error_page(500, hit_count, user_tmpl), 500, response_headers
		end
		if r_headers then
			response_headers = r_headers
		else
			content = tmpls.render_page(content, tmpl_vars, user_tmpl)
		end
	elseif content_type == "text/djot" then
		if headers.accept and headers.accept:match("text/djot") then
			response_headers["content-type"] = content_type
		else
			content = tmpls.render_page(tmpls.djot_to_html(content), tmpl_vars, user_tmpl)
		end
	else
		response_headers["content-type"] = content_type
	end
	if metadata.cache_control then
		response_headers["etag"] = metadata.hash
		response_headers["cache-control"] = metadata.cache_control
	end
	metrics.update(host, method, query, status)
	return content, status, response_headers
end

return { func = handle }
