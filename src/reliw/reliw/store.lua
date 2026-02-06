local std = require("std")
local redis = require("redis")
local json = require("cjson.safe")
local crypto = require("crypto")

local normalize_virtual_path = function(path)
	if type(path) ~= "string" or path == "" then
		return nil, "invalid/empty file path"
	end
	if path:find("[%z\1-\31]") then
		return nil, "control chars in file path"
	end
	local has_leading_slash = path:sub(1, 1) == "/"
	path = path:gsub("\\", "/")
	path = path:gsub("/+", "/")
	local segments = {}
	for segment in path:gmatch("[^/]+") do
		if segment == ".." then
			return nil, "path traversal detected"
		end
		if segment ~= "." then
			table.insert(segments, segment)
		end
	end
	if #segments == 0 then
		return nil, "empty normalized file path"
	end
	local normalized = table.concat(segments, "/")
	if has_leading_slash then
		normalized = "/" .. normalized
	end
	return normalized
end

local build_safe_path = function(root_dir, normalized_path)
	local relative = normalized_path:gsub("^/+", "")
	if relative == "" then
		return nil, "empty relative path"
	end
	return root_dir .. "/" .. relative
end

local resolve_storage_paths = function(data_dir, host, filename)
	local normalized, path_err = normalize_virtual_path(filename)
	if not normalized then
		return nil, nil, nil, path_err
	end
	local host_path, host_path_err = build_safe_path(data_dir .. "/" .. host, normalized)
	if not host_path then
		return nil, nil, nil, host_path_err
	end
	local fallback_path, fallback_path_err = build_safe_path(data_dir .. "/__", normalized)
	if not fallback_path then
		return nil, nil, nil, fallback_path_err
	end
	return normalized, host_path, fallback_path, nil
end

local fetch_proxy_config = function(self, host)
	if not host or type(host) ~= "string" then
		return nil, "no host/invalid type provided"
	end
	local config, err = self.red:cmd("GET", self.prefix .. ":PROXY:" .. host)
	if err then
		return nil, "proxy config not found"
	end
	return json.decode(config)
end

local fetch_host_schema = function(self, host)
	if not host or type(host) ~= "string" then
		return nil, "no host/invalid type provided"
	end
	local paths, err = self.red:cmd("GET", self.prefix .. ":API:" .. host)
	if err then
		return nil, "API schema not found"
	end
	return json.decode(paths)
end

local fetch_entry_metadata = function(self, host, entry_id)
	if not host or not entry_id then
		return nil, "host or entry_id not provided"
	end
	local metadata, err = self.red:cmd("GET", self.prefix .. ":API:" .. host .. ":" .. entry_id)
	if err then
		return nil, "metadata: " .. tostring(err)
	end
	return json.decode(metadata)
end

local fetch_userinfo = function(self, host, user)
	if not host or not user then
		return nil, "host/user not provided"
	end
	local user_info, err = self.red:cmd("HGET", self.prefix .. ":USERS:" .. host, user)
	if err then
		return nil, err
	end
	return json.decode(user_info)
end

local fetch_userdata = function(self, host, file)
	if not host or not file then
		return nil, "host/file not provided"
	end
	local userdata, err = self.red:cmd("GET", self.prefix .. ":DATA:" .. host .. ":" .. file)
	if err then
		userdata, err = self.red:cmd("GET", self.prefix .. ":DATA:__:" .. file)
	end
	if not userdata then
		return nil, "userdata not found"
	end
	if std.mime.type(file) == "application/lua" then
		local fn, err = load(userdata)
		if not fn then
			return nil, "failed to load Lua userdata: " .. tostring(err)
		end
		userdata = fn()
	end
	return userdata
end

local fetch_content = function(self, host, query, metadata)
	if not metadata or type(metadata) ~= "table" then
		return nil, "invalid metadata"
	end
	if not host or not query then
		return nil, "host/query not provided"
	end
	local filename = metadata.file
	if not filename then
		filename = query
		if query:match("/$") and metadata.index then
			filename = filename .. metadata.index
		end
		local normalized_filename, host_path, _, path_err = resolve_storage_paths(self.data_dir, host, filename)
		if not normalized_filename then
			return nil, "invalid file path: " .. tostring(path_err)
		end
		filename = normalized_filename
		if not std.fs.file_exists(host_path) then
			if metadata.try_extensions then
				local extension_candidates = { ".lua", ".dj", ".md" }
				for _, ext in ipairs(extension_candidates) do
					local candidate, candidate_host_path = resolve_storage_paths(self.data_dir, host, filename .. ext)
					if candidate and std.fs.file_exists(candidate_host_path) then
						filename = candidate
						break
					end
				end
			elseif metadata.gsub then
				local remapped_query = query:gsub(metadata.gsub.pattern, metadata.gsub.replacement)
				local remapped_filename, _, _, remap_err = resolve_storage_paths(self.data_dir, host, remapped_query)
				if not remapped_filename then
					return nil, "invalid file path: " .. tostring(remap_err)
				end
				filename = remapped_filename
			end
		end
	else
		local normalized_filename, _, _, path_err = resolve_storage_paths(self.data_dir, host, filename)
		if not normalized_filename then
			return nil, "invalid file path: " .. tostring(path_err)
		end
		filename = normalized_filename
	end
	local mime_type = std.mime.type(filename)
	local count, _ = self.red:cmd("HEXISTS", self.prefix .. ":FILES:" .. host .. ":" .. filename, "content")
	if count and count == 1 then
		local resp, _ = self.red:cmd(
			"HMGET",
			self.prefix .. ":FILES:" .. host .. ":" .. filename,
			"content",
			"hash",
			"size",
			"mime",
			"title"
		)
		if resp then
			local content = resp[1]
			if resp[4] == "application/lua" then
				local fn, err = load(resp[1])
				if not fn then
					return nil, "failed to load cached Lua content: " .. tostring(err)
				end
				content = fn()
			end
			return content, resp[2], resp[3], resp[4], resp[5]
		end
		return nil, "something went wrong"
	end
	local _, primary_path, fallback_path, path_err = resolve_storage_paths(self.data_dir, host, filename)
	if not primary_path then
		return nil, "invalid file path: " .. tostring(path_err)
	end
	local content = std.fs.read_file(primary_path) or std.fs.read_file(fallback_path)
	if not content then
		return nil, filename .. " not found"
	end
	local title = metadata.title or ""
	local resp, _ = self.red:cmd("HGET", self.prefix .. ":TITLES:" .. host, filename)
	if resp then
		title = resp
	end
	local size = #content
	local hash = crypto.bin_to_hex(crypto.sha256(content))
	if size <= self.cache_max_size then
		self.red:cmd(
			"HSET",
			self.prefix .. ":FILES:" .. host .. ":" .. filename,
			"content",
			content,
			"hash",
			hash,
			"size",
			size,
			"mime",
			mime_type,
			"title",
			title
		)
		self.red:cmd("EXPIRE", self.prefix .. ":FILES:" .. host .. ":" .. filename, 3600)
	end
	if mime_type == "application/lua" then
		local fn, err = load(content)
		if not fn then
			return nil, "failed to load Lua content: " .. tostring(err)
		end
		content = fn()
	end
	return content, hash, size, mime_type, title
end

local fetch_hash_and_size = function(self, host, file)
	if not host or not file then
		return nil, "host/file not provided"
	end
	local target = self.prefix .. ":FILES:" .. host .. ":" .. file
	local resp, err = self.red:cmd("HMGET", target, "hash", "size")
	if err then
		return nil, "not found"
	end
	return resp[1], resp[2]
end

local check_waf = function(self, host, query, headers)
	if not headers or type(headers) ~= "table" then
		return nil
	end
	if not host or not query then
		return nil
	end

	local global = self.red:cmd("HGET", self.prefix .. ":WAF", "__")
	local per_host = self.red:cmd("HGET", self.prefix .. ":WAF", host)
	if not global and not per_host then
		return nil
	end
	local global_rules = json.decode(global)
	local per_host_rules = json.decode(per_host)
	if global_rules then
		if global_rules.query then
			for _, rule in ipairs(global_rules.query) do
				if query:match(rule) then
					return true, rule, global_rules.ip_header or "x-forwarded-for"
				end
			end
		end
		if global_rules.headers then
			for header, rules in pairs(global_rules.headers) do
				for _, rule in ipairs(rules) do
					if headers[header] and headers[header]:match(rule) then
						return true, rule, global_rules.ip_header or "x-forwarded-for"
					end
				end
			end
		end
	end
	if per_host_rules then
		if per_host_rules.query then
			for _, rule in ipairs(per_host_rules.query) do
				if query:match(rule) then
					return true, rule, per_host_rules.ip_header or "x-forwarded-for"
				end
			end
		end
		if per_host_rules.headers then
			for header, rules in pairs(per_host_rules.headers) do
				for _, rule in ipairs(rules) do
					if headers[header] and headers[header]:match(rule) then
						return true, rule, per_host_rules.ip_header or "x-forwarded-for"
					end
				end
			end
		end
	end
	return nil
end

local add_waffer = function(self, ip)
	if not ip then
		return nil, "no IP provided"
	end
	return self.red:cmd("PUBLISH", self.prefix .. ":WAFFERS", ip)
end

local check_rate_limit = function(self, host, method, query, remote_ip, period)
	if not host or not method or not query or not remote_ip then
		return nil, "not all required args provided"
	end
	local count =
		self.red:cmd("INCR", self.prefix .. ":LIMITS:" .. host .. ":" .. method .. ":" .. query .. ":" .. remote_ip)
	if not count then
		return nil
	end
	if count == 1 then
		self.red:cmd(
			"EXPIRE",
			self.prefix .. ":LIMITS:" .. host .. ":" .. method .. ":" .. query .. ":" .. remote_ip,
			period
		)
	end
	return count
end

local set_session_data = function(self, host, user, ttl)
	if not host or not user or not ttl then
		return nil, "required args not present"
	end
	local uuid = std.nanoid()
	local ok, err = self.red:cmd("SET", self.prefix .. ":SESSIONS:" .. host .. ":" .. uuid, user, "EX", ttl)
	if ok then
		return uuid
	end
	return ok, err
end

local destroy_session = function(self, host, token)
	if not host or not token then
		return nil, "required args not provided"
	end
	local ok, err = self.red:cmd("DEL", self.prefix .. ":SESSIONS:" .. host .. ":" .. token)
	return ok, err
end

local fetch_session_user = function(self, host, token)
	if not host or not token then
		return nil, "required args not provided"
	end
	local session_user, err = self.red:cmd("GET", self.prefix .. ":SESSIONS:" .. host .. ":" .. token)
	if err then
		return nil
	end
	local user = self.red:cmd("HEXISTS", self.prefix .. ":USERS:" .. host, session_user)
	if not user or user <= 0 then
		return nil
	end
	return session_user
end

local fetch_metrics = function(self)
	local metrics_total = "# TYPE http_requests_total counter\n"
	local metrics_by_method = "# TYPE http_requests_by_method counter\n"
	local vhosts, _ = self.red:cmd("KEYS", self.prefix .. ":METRICS:*:total")
	if vhosts then
		for _, v in ipairs(vhosts) do
			local vhost_name = v:match(self.prefix .. ":METRICS:(.-):total")
			local values = self.red:cmd("HGETALL", v)
			if values then
				for i = 1, #values, 2 do
					metrics_total = metrics_total
						.. [[http_requests_total{host="]]
						.. vhost_name
						.. [[",code="]]
						.. values[i]
						.. [["} ]]
						.. values[i + 1]
						.. "\n"
				end
			end
			values = self.red:cmd("HGETALL", self.prefix .. ":METRICS:" .. vhost_name .. ":by_method")
			if values then
				for i = 1, #values, 2 do
					metrics_by_method = metrics_by_method
						.. [[http_requests_by_method{host="]]
						.. vhost_name
						.. [[",method="]]
						.. values[i]
						.. [["} ]]
						.. values[i + 1]
						.. "\n"
				end
			end
		end
	end
	return metrics_total .. metrics_by_method
end

local update_metrics = function(self, host, method, query, status)
	local resp, err
	if host ~= "unknown" then
		resp, err = self.red:cmd("HINCRBY", self.prefix .. ":METRICS:" .. host .. ":total", status, "1")
		resp, err = self.red:cmd("HINCRBY", self.prefix .. ":METRICS:" .. host .. ":by_method", method, "1")
	end
	resp, err = self.red:cmd("HINCRBY", self.prefix .. ":METRICS:" .. host .. ":by_request", query, "1")
	return resp, err
end

local send_ctl_msg = function(self, msg)
	local resp, err = self.red:cmd("PUBLISH", self.prefix .. ":CTL", msg)
	return resp, err
end

local new = function(srv_cfg)
	local red, err = redis.connect(srv_cfg.redis)
	if err then
		return nil, err
	end
	return {
		prefix = srv_cfg.redis.prefix,
		data_dir = srv_cfg.data_dir,
		cache_max_size = srv_cfg.cache_max_size,
		red = red,
		close = function(self)
			if self.red then
				self.red:close()
			end
		end,
		fetch_host_schema = fetch_host_schema,
		fetch_proxy_config = fetch_proxy_config,
		fetch_userinfo = fetch_userinfo,
		fetch_entry_metadata = fetch_entry_metadata,
		fetch_content = fetch_content,
		fetch_hash_and_size = fetch_hash_and_size,
		fetch_userdata = fetch_userdata,
		fetch_session_user = fetch_session_user,
		fetch_metrics = fetch_metrics,
		check_rate_limit = check_rate_limit,
		check_waf = check_waf,
		add_waffer = add_waffer,
		set_session_data = set_session_data,
		destroy_session = destroy_session,
		update_metrics = update_metrics,
		send_ctl_msg = send_ctl_msg,
	}
end

return { new = new }
