local std = require("std")
local redis = require("redis")
local json = require("cjson.safe")
local crypto = require("crypto")

local fetch_proxy_config = function(self, host)
	if not host or type(host) ~= "string" then
		return nil, "no host/invalid type provided"
	end
	local config, err = self.red:cmd("GET", self.prefix .. ":PROXY:" .. host)
	self.red:close()
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
	self.red:close()
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
	self.red:close()
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
	self.red:close()
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
	self.red:close()
	if not userdata then
		return nil, "userdata not found"
	end
	if std.mime.type(file) == "application/lua" then
		userdata = load(userdata)()
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
	local prefix = self.data_dir .. "/" .. host
	if not filename then
		filename = query
		if query:match("/$") and metadata.index then
			filename = filename .. metadata.index
		end
		if not std.fs.file_exists(prefix .. filename) then
			if metadata.try_extensions then
				if std.fs.file_exists(prefix .. filename .. ".lua") then
					filename = filename .. ".lua"
				elseif std.fs.file_exists(prefix .. filename .. ".dj") then
					filename = filename .. ".dj"
				elseif std.fs.file_exists(prefix .. filename .. ".md") then
					filename = filename .. ".md"
				end
			elseif metadata.gsub then
				local remapped_query = query:gsub(metadata.gsub.pattern, metadata.gsub.replacement)
				filename = remapped_query
			end
		end
	end
	local mime_type = std.mime.type(filename)
	local count, err = self.red:cmd("HEXISTS", self.prefix .. ":FILES:" .. host .. ":" .. filename, "content")
	if count and count == 1 then
		local resp, err = self.red:cmd(
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
				content = load(resp[1])()
			end
			return content, resp[2], resp[3], resp[4], resp[5]
		end
		return nil, "something went wrong"
	end
	local content = std.fs.read_file(prefix .. filename) or std.fs.read_file(self.data_dir .. "/__" .. filename)
	if not content then
		self.red:close()
		return nil, filename .. " not found"
	end
	local title = metadata.title or ""
	local resp, err = self.red:cmd("HGET", self.prefix .. ":TITLES:" .. host, filename)
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
		content = load(content)()
	end
	self.red:close()
	return content, hash, size, mime_type, title
end

local fetch_hash_and_size = function(self, host, file)
	if not host or not file then
		return nil, "host/file not provided"
	end
	local target = self.prefix .. ":FILES:" .. host .. ":" .. file
	local resp, err = self.red:cmd("HMGET", target, "hash", "size")
	self.red:close()
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
	self.red:close()
	if not global and not per_host then
		return nil
	end
	local global_rules = json.decode(global)
	local per_host_rules = json.decode(per_host)
	if global_rules then
		if global_rules.query then
			for _, rule in ipairs(global_rules.query) do
				if query:match(rule) then
					return true, rule
				end
			end
		end
		if global_rules.headers then
			for header, rules in pairs(global_rules.headers) do
				for _, rule in ipairs(rules) do
					if headers[header] and headers[header]:match(rule) then
						return true, rule
					end
				end
			end
		end
	end
	if per_host_rules then
		if per_host_rules.query then
			for _, rule in ipairs(per_host_rules.query) do
				if query:match(rule) then
					return true, rule
				end
			end
		end
		if per_host_rules.headers then
			for header, rules in pairs(per_host_rules.headers) do
				for _, rule in ipairs(rules) do
					if headers[header] and headers[header]:match(rule) then
						return true, rule
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
		self.red:close()
		return nil
	end
	if count == 1 then
		self.red:cmd(
			"EXPIRE",
			self.prefix .. ":LIMITS:" .. host .. ":" .. method .. ":" .. query .. ":" .. remote_ip,
			period
		)
	end
	self.red:close()
	return count
end

local set_session_data = function(self, host, user, ttl)
	if not host or not user or not ttl then
		return nil, "required args not present"
	end
	local uuid = std.uuid()
	local ok, err = self.red:cmd("SET", self.prefix .. ":SESSIONS:" .. host .. ":" .. uuid, user, "EX", ttl)
	self.red:close()
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
	self.red:close()
	return ok, err
end

local fetch_session_user = function(self, host, token)
	if not host or not token then
		return nil, "required args not provided"
	end
	local session_user, err = self.red:cmd("GET", self.prefix .. ":SESSIONS:" .. host .. ":" .. token)
	if err then
		self.red:close()
		return nil
	end
	local user = self.red:cmd("HEXISTS", self.prefix .. ":USERS:" .. host, session_user)
	self.red:close()
	if not user or user <= 0 then
		return nil
	end
	return session_user
end

local fetch_metrics = function(self)
	local metrics_total = "# TYPE http_requests_total counter\n"
	local metrics_by_method = "# TYPE http_requests_by_method counter\n"
	local vhosts, err = self.red:cmd("KEYS", self.prefix .. ":METRICS:*:total")
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
			local values = self.red:cmd("HGETALL", self.prefix .. ":METRICS:" .. vhost_name .. ":by_method")
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
	self.red:close()
	return metrics_total .. metrics_by_method
end

local update_metrics = function(self, host, method, query, status)
	local resp, err = self.red:cmd("HINCRBY", self.prefix .. ":METRICS:" .. host .. ":total", status, "1")
	resp, err = self.red:cmd("HINCRBY", self.prefix .. ":METRICS:" .. host .. ":by_method", method, "1")
	resp, err = self.red:cmd("HINCRBY", self.prefix .. ":METRICS:" .. host .. ":by_request", query, "1")
	self.red:close()
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
		fetch_host_schema = fetch_host_schema,
		fetch_proxy_config = fetch_proxy_config,
		fetch_userinfo = fetch_userinfo,
		fetch_entry_metadata = fetch_entry_metadata,
		fetch_content = fetch_content,
		fetch_hash_and_size = fetch_hash_and_size,
		fetch_userdata = fetch_userdata,
		check_rate_limit = check_rate_limit,
		check_waf = check_waf,
		add_waffer = add_waffer,
		set_session_data = set_session_data,
		destroy_session = destroy_session,
		fetch_session_user = fetch_session_user,
		fetch_metrics = fetch_metrics,
		update_metrics = update_metrics,
		send_ctl_msg = send_ctl_msg,
	}
end

return { new = new }
