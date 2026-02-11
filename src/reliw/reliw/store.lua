-- SPDX-FileCopyrightText: © 2022—2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: LicenseRef-OWL-1.0-or-later OR GPL-3.0-or-later
-- Dual-licensed under OWL v1.0+ and GPLv3+. See LICENSE and LICENSE-GPL3.

local std = require("std")
local redis = require("redis")
local json = require("cjson.safe")
local crypto = require("crypto")

local validate_redis_client = function(client)
	if type(client) ~= "table" then
		return nil, "client must be a table"
	end
	if type(client.cmd) ~= "function" then
		return nil, "missing cmd method"
	end
	if type(client.close) ~= "function" then
		return nil, "missing close method"
	end
	return true
end

local get_redis = function(self)
	return self.__state.red
end

local get_prefix = function(self)
	return self.cfg.prefix
end

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

local normalize_acme_domain = function(domain)
	if type(domain) ~= "string" then
		return nil, "domain must be a string"
	end
	domain = domain:match("^%s*(.-)%s*$"):lower()
	if domain == "" then
		return nil, "domain must not be empty"
	end
	if domain:find("[%z\1-\31\127]") then
		return nil, "domain has invalid chars"
	end
	if domain:find("/", 1, true) or domain:find(":", 1, true) then
		return nil, "domain has invalid separators"
	end
	return domain
end

local normalize_acme_token = function(token)
	if type(token) ~= "string" then
		return nil, "token must be a string"
	end
	token = token:match("^%s*(.-)%s*$")
	if token == "" then
		return nil, "token must not be empty"
	end
	if token:find("[%z\1-\31\127]") then
		return nil, "token has invalid chars"
	end
	if token:find("/", 1, true) or token:find(":", 1, true) then
		return nil, "token has invalid separators"
	end
	if not token:match("^[A-Za-z0-9._%-]+$") then
		return nil, "token has unsupported chars"
	end
	return token
end

local build_acme_key = function(self, domain, token)
	return get_prefix(self) .. ":DATA:" .. domain .. ":.well-known/acme-challenge/" .. token
end

local fetch_proxy_config = function(self, host)
	if not host or type(host) ~= "string" then
		return nil, "no host/invalid type provided"
	end
	local red = get_redis(self)
	local config, err = red:cmd("GET", get_prefix(self) .. ":PROXY:" .. host)
	if err then
		return nil, "proxy config not found"
	end
	return json.decode(config)
end

local fetch_host_schema = function(self, host)
	if not host or type(host) ~= "string" then
		return nil, "no host/invalid type provided"
	end
	local red = get_redis(self)
	local paths, err = red:cmd("GET", get_prefix(self) .. ":API:" .. host)
	if err then
		return nil, "API schema not found"
	end
	return json.decode(paths)
end

local fetch_entry_metadata = function(self, host, entry_id)
	if not host or not entry_id then
		return nil, "host or entry_id not provided"
	end
	local red = get_redis(self)
	local metadata, err = red:cmd("GET", get_prefix(self) .. ":API:" .. host .. ":" .. entry_id)
	if err then
		return nil, "metadata: " .. tostring(err)
	end
	return json.decode(metadata)
end

local fetch_userinfo = function(self, host, user)
	if not host or not user then
		return nil, "host/user not provided"
	end
	local red = get_redis(self)
	local user_info, err = red:cmd("HGET", get_prefix(self) .. ":USERS:" .. host, user)
	if err then
		return nil, err
	end
	return json.decode(user_info)
end

local fetch_userdata = function(self, host, file)
	if not host or not file then
		return nil, "host/file not provided"
	end
	local red = get_redis(self)
	local prefix = get_prefix(self)
	local userdata, err = red:cmd("GET", prefix .. ":DATA:" .. host .. ":" .. file)
	if err then
		userdata, err = red:cmd("GET", prefix .. ":DATA:__:" .. file)
	end
	if not userdata then
		return nil, "userdata not found"
	end
	if std.mime.type(file) == "application/lua" then
		local fn, load_err = load(userdata)
		if not fn then
			return nil, "failed to load Lua userdata: " .. tostring(load_err)
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
	local data_dir = self.cfg.data_dir
	local cache_max_size = self.cfg.cache_max_size
	local red = get_redis(self)
	local prefix = get_prefix(self)
	local filename = metadata.file
	if not filename then
		filename = query
		if query:match("/$") and metadata.index then
			filename = filename .. metadata.index
		end
		local normalized_filename, host_path, _, path_err = resolve_storage_paths(data_dir, host, filename)
		if not normalized_filename then
			return nil, "invalid file path: " .. tostring(path_err)
		end
		filename = normalized_filename
		if not std.fs.file_exists(host_path) then
			if metadata.try_extensions then
				local extension_candidates = { ".lua", ".dj", ".md" }
				for _, ext in ipairs(extension_candidates) do
					local candidate, candidate_host_path = resolve_storage_paths(data_dir, host, filename .. ext)
					if candidate and std.fs.file_exists(candidate_host_path) then
						filename = candidate
						break
					end
				end
			elseif metadata.gsub then
				local remapped_query = query:gsub(metadata.gsub.pattern, metadata.gsub.replacement)
				local remapped_filename, _, _, remap_err = resolve_storage_paths(data_dir, host, remapped_query)
				if not remapped_filename then
					return nil, "invalid file path: " .. tostring(remap_err)
				end
				filename = remapped_filename
			end
		end
	else
		local normalized_filename, _, _, path_err = resolve_storage_paths(data_dir, host, filename)
		if not normalized_filename then
			return nil, "invalid file path: " .. tostring(path_err)
		end
		filename = normalized_filename
	end
	local mime_type = std.mime.type(filename)
	local target = prefix .. ":FILES:" .. host .. ":" .. filename
	local count, _ = red:cmd("HEXISTS", target, "content")
	if count and count == 1 then
		local resp, _ = red:cmd("HMGET", target, "content", "hash", "size", "mime", "title")
		if resp then
			local content = resp[1]
			if resp[4] == "application/lua" then
				local fn, load_err = load(resp[1])
				if not fn then
					return nil, "failed to load cached Lua content: " .. tostring(load_err)
				end
				content = fn()
			end
			return content, resp[2], resp[3], resp[4], resp[5]
		end
		return nil, "something went wrong"
	end
	local _, primary_path, fallback_path, path_err = resolve_storage_paths(data_dir, host, filename)
	if not primary_path then
		return nil, "invalid file path: " .. tostring(path_err)
	end
	local content = std.fs.read_file(primary_path) or std.fs.read_file(fallback_path)
	if not content then
		return nil, filename .. " not found"
	end
	local title = metadata.title or ""
	local resp, _ = red:cmd("HGET", prefix .. ":TITLES:" .. host, filename)
	if resp then
		title = resp
	end
	local size = #content
	local hash = crypto.bin_to_hex(crypto.sha256(content))
	if size <= cache_max_size then
		red:cmd("HSET", target, "content", content, "hash", hash, "size", size, "mime", mime_type, "title", title)
		red:cmd("EXPIRE", target, 3600)
	end
	if mime_type == "application/lua" then
		local fn, load_err = load(content)
		if not fn then
			return nil, "failed to load Lua content: " .. tostring(load_err)
		end
		content = fn()
	end
	return content, hash, size, mime_type, title
end

local fetch_hash_and_size = function(self, host, file)
	if not host or not file then
		return nil, "host/file not provided"
	end
	local red = get_redis(self)
	local target = get_prefix(self) .. ":FILES:" .. host .. ":" .. file
	local resp, err = red:cmd("HMGET", target, "hash", "size")
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

	local red = get_redis(self)
	local prefix = get_prefix(self)
	local global = red:cmd("HGET", prefix .. ":WAF", "__")
	local per_host = red:cmd("HGET", prefix .. ":WAF", host)
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
	local red = get_redis(self)
	return red:cmd("PUBLISH", get_prefix(self) .. ":WAFFERS", ip)
end

local check_rate_limit = function(self, host, method, query, remote_ip, period)
	if not host or not method or not query or not remote_ip then
		return nil, "not all required args provided"
	end
	local red = get_redis(self)
	local target = get_prefix(self) .. ":LIMITS:" .. host .. ":" .. method .. ":" .. query .. ":" .. remote_ip
	local count = red:cmd("INCR", target)
	if not count then
		return nil
	end
	if count == 1 then
		red:cmd("EXPIRE", target, period)
	end
	return count
end

local set_session_data = function(self, host, user, ttl)
	if not host or not user or not ttl then
		return nil, "required args not present"
	end
	local uuid = std.nanoid()
	local red = get_redis(self)
	local ok, err = red:cmd("SET", get_prefix(self) .. ":SESSIONS:" .. host .. ":" .. uuid, user, "EX", ttl)
	if ok then
		return uuid
	end
	return ok, err
end

local destroy_session = function(self, host, token)
	if not host or not token then
		return nil, "required args not provided"
	end
	local red = get_redis(self)
	local ok, err = red:cmd("DEL", get_prefix(self) .. ":SESSIONS:" .. host .. ":" .. token)
	return ok, err
end

local fetch_session_user = function(self, host, token)
	if not host or not token then
		return nil, "required args not provided"
	end
	local red = get_redis(self)
	local prefix = get_prefix(self)
	local session_user, err = red:cmd("GET", prefix .. ":SESSIONS:" .. host .. ":" .. token)
	if err then
		return nil
	end
	local user = red:cmd("HEXISTS", prefix .. ":USERS:" .. host, session_user)
	if not user or user <= 0 then
		return nil
	end
	return session_user
end

local fetch_metrics = function(self)
	local metrics_total = "# TYPE http_requests_total counter\n"
	local metrics_by_method = "# TYPE http_requests_by_method counter\n"
	local vhosts = {}
	local seen_hosts = {}
	local prefix = get_prefix(self) .. ":METRICS:"
	local suffix = ":total"
	local match = get_prefix(self) .. ":METRICS:*:total"
	local scan_count = tostring(self.cfg.metrics_scan_count or 100)
	local scan_limit = self.cfg.metrics_scan_limit or 2000
	local scanned_keys = 0
	local cursor = "0"
	local red = get_redis(self)
	while true do
		local resp = red:cmd("SCAN", cursor, "MATCH", match, "COUNT", scan_count)
		if not resp then
			break
		end
		cursor = tostring(resp[1] or "0")
		local keys = resp[2]
		if type(keys) == "table" then
			for _, key in ipairs(keys) do
				if scanned_keys >= scan_limit then
					cursor = "0"
					break
				end
				scanned_keys = scanned_keys + 1
				if key:sub(1, #prefix) == prefix and key:sub(-#suffix) == suffix then
					local host = key:sub(#prefix + 1, #key - #suffix)
					if host ~= "" and not seen_hosts[host] then
						seen_hosts[host] = true
						table.insert(vhosts, host)
					end
				end
			end
		end
		if cursor == "0" then
			break
		end
	end
	table.sort(vhosts)

	for _, vhost_name in ipairs(vhosts) do
		local values = red:cmd("HGETALL", get_prefix(self) .. ":METRICS:" .. vhost_name .. ":total")
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
		values = red:cmd("HGETALL", get_prefix(self) .. ":METRICS:" .. vhost_name .. ":by_method")
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
	return metrics_total .. metrics_by_method
end

local update_metrics = function(self, host, method, query, status)
	local red = get_redis(self)
	local prefix = get_prefix(self)
	local resp, err
	if host ~= "unknown" then
		resp, err = red:cmd("HINCRBY", prefix .. ":METRICS:" .. host .. ":total", status, "1")
		resp, err = red:cmd("HINCRBY", prefix .. ":METRICS:" .. host .. ":by_method", method, "1")
	end
	resp, err = red:cmd("HINCRBY", prefix .. ":METRICS:" .. host .. ":by_request", query, "1")
	return resp, err
end

local send_ctl_msg = function(self, msg)
	local red = get_redis(self)
	local resp, err = red:cmd("PUBLISH", get_prefix(self) .. ":CTL", msg)
	return resp, err
end

local provision_acme_challenge = function(self, domain, token, value)
	local normalized_domain, domain_err = normalize_acme_domain(domain)
	if not normalized_domain then
		return nil, domain_err
	end
	local normalized_token, token_err = normalize_acme_token(token)
	if not normalized_token then
		return nil, token_err
	end
	if type(value) ~= "string" or value == "" then
		return nil, "value must be a non-empty string"
	end
	local red = get_redis(self)
	local key = build_acme_key(self, normalized_domain, normalized_token)
	local ok, err = red:cmd("SET", key, value)
	if err then
		return nil, err
	end
	return ok
end

local cleanup_acme_challenge = function(self, domain, token)
	local normalized_domain, domain_err = normalize_acme_domain(domain)
	if not normalized_domain then
		return nil, domain_err
	end
	local normalized_token, token_err = normalize_acme_token(token)
	if not normalized_token then
		return nil, token_err
	end
	local red = get_redis(self)
	local key = build_acme_key(self, normalized_domain, normalized_token)
	return red:cmd("DEL", key)
end

local close = function(self, no_keepalive)
	local red = self.__state.red
	if not red then
		return true
	end
	self.__state.red = nil
	return red:close(no_keepalive)
end

local new = function(srv_cfg)
	local red, err = redis.connect(srv_cfg.redis)
	if err then
		return nil, err
	end
	local ok, client_err = validate_redis_client(red)
	if not ok then
		return nil, "invalid redis client: " .. client_err
	end
	local metrics_cfg = srv_cfg.metrics or {}
	local scan_count = tonumber(metrics_cfg.scan_count) or 100
	if scan_count < 1 then
		scan_count = 1
	elseif scan_count > 1000 then
		scan_count = 1000
	end
	local scan_limit = tonumber(metrics_cfg.scan_limit) or 2000
	if scan_limit < 1 then
		scan_limit = 1
	elseif scan_limit > 10000 then
		scan_limit = 10000
	end
	return {
		cfg = {
			prefix = srv_cfg.redis.prefix,
			data_dir = srv_cfg.data_dir,
			cache_max_size = srv_cfg.cache_max_size,
			metrics_scan_count = scan_count,
			metrics_scan_limit = scan_limit,
		},
		__state = {
			red = red,
		},
		close = close,
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
		provision_acme_challenge = provision_acme_challenge,
		cleanup_acme_challenge = cleanup_acme_challenge,
	}
end

return {
	new = new,
}
