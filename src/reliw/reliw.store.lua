local std = require("std")
local redis = require("redis")
local json = require("cjson.safe")
local crypto = require("crypto")

local fetch_host_schema = function(self, host)
	local paths, err = self.red:cmd("GET", self.prefix .. ":API:" .. host)
	self.red:close()
	if not paths or paths == "NULL" then
		return nil, "API schema not found"
	end
	return json.decode(paths)
end

local fetch_entry_metadata = function(self, host, entry_id)
	local metadata, err = self.red:cmd("GET", self.prefix .. ":API:" .. host .. ":" .. entry_id)
	self.red:close()
	if not metadata or metadata == "NULL" then
		return nil, "metadata not found"
	end
	return json.decode(metadata)
end

local fetch_userinfo = function(self, host, user)
	local user_info = self.red:cmd("HGET", self.prefix .. ":USERS:" .. host, user)
	self.red:close()
	if not user_info or user_info == "NULL" then
		return nil, "not found"
	end
	return json.decode(user_info)
end

local fetch_userdata = function(self, host, file)
	local userdata, err = self.red:cmd("GET", self.prefix .. ":DATA:" .. host .. ":" .. file)
	if not userdata or userdata == "NULL" then
		userdata, err = self.red:cmd("GET", self.prefix .. ":DATA:__:" .. file)
	end
	self.red:close()
	if not userdata or userdata == "NULL" then
		return nil, "userdata not found"
	end
	if std.mime.type(file) == "application/lua" then
		userdata = load(userdata)()
	end
	return userdata
end

local fetch_content = function(self, host, query, metadata)
	local filename = metadata.file
	if not filename then
		filename = self.data_dir .. "/" .. host .. query
		if query:match("/$") and metadata.index then
			filename = filename .. metadata.index
		end
		if not std.fs.file_exists(filename) then
			if metadata.try_extensions then
				if std.fs.file_exists(filename .. ".lua") then
					filename = filename .. ".lua"
				elseif std.fs.file_exists(filename .. ".dj") then
					filename = filename .. ".dj"
				else
					filename = filename .. ".md"
				end
			elseif metadata.gsub then
				local remapped_query = query:gsub(metadata.gsub.pattern, metadata.gsub.replacement)
				filename = self.data_dir .. "/" .. host .. remapped_query
			end
		end
	else
		filename = self.data_dir .. "/" .. host .. "/" .. filename
	end
	local short_filename = filename:gsub(self.data_dir .. "/" .. host, "")
	local mime_type = std.mime.type(filename)
	local count, err = self.red:cmd("HEXISTS", self.prefix .. ":FILES:" .. host .. ":" .. short_filename, "content")
	if count and count == 1 then
		local resp, err = self.red:cmd(
			"HMGET",
			self.prefix .. ":FILES:" .. host .. ":" .. short_filename,
			"content",
			"hash",
			"size",
			"mime",
			"title"
		)
		if resp and resp ~= "NULL" then
			local content = resp[1]
			if resp[4] == "application/lua" then
				content = load(resp[1])()
			end
			return content, resp[2], resp[3], resp[4], resp[5]
		end
		return nil, "something went wrong"
	end
	local content = std.fs.read_file(filename)
	if not content then
		self.red:close()
		return nil, filename .. " not found"
	end
	local title = metadata.title
	local resp, err = self.red:cmd("HGET", self.prefix .. ":TITLES:" .. host, short_filename)
	if resp and resp ~= "NULL" then
		title = resp
	end
	local size = #content
	local hash = crypto.bin_to_hex(crypto.sha256(content))
	if size <= self.cache_max_size then
		self.red:cmd(
			"HSET",
			self.prefix .. ":FILES:" .. host .. ":" .. short_filename,
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
		self.red:cmd(
			"HEXPIRE",
			self.prefix .. ":FILES:" .. host .. ":" .. short_filename,
			3600,
			"NX",
			"FIELDS",
			5,
			"content",
			"hash",
			"size",
			"mime",
			"title"
		)
	end
	if mime_type == "application/lua" then
		content = load(content)()
	end
	self.red:close()
	return content, hash, size, mime_type, title
end

local fetch_hash_and_size = function(self, host, file)
	local target = self.prefix .. ":FILES:" .. host .. ":" .. file
	local resp, err = self.red:cmd("HMGET", target, "hash", "size")
	self.red:close()
	if not resp or resp == "NULL" then
		return nil, "not found"
	end
	return resp[1], resp[2]
end

local check_rate_limit = function(self, host, method, query, remote_ip, period)
	local count =
		self.red:cmd("INCR", self.prefix .. ":LIMITS:" .. host .. ":" .. method .. ":" .. query .. ":" .. remote_ip)
	if not count or count == "NULL" then
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
	local uuid = std.uuid()
	local ok, err = self.red:cmd("SET", self.prefix .. ":SESSIONS:" .. host .. ":" .. uuid, user, "EX", ttl)
	self.red:close()
	if ok then
		return uuid
	end
	return ok, err
end

local destroy_session = function(self, host, token)
	local ok, err = self.red:cmd("DEL", self.prefix .. ":SESSIONS:" .. host .. ":" .. token)
	self.red:close()
	return ok, err
end

local fetch_session_user = function(self, host, token)
	local session_user, err = self.red:cmd("GET", self.prefix .. ":SESSIONS:" .. host .. ":" .. token)
	if not session_user or session_user == "NULL" then
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

local new = function()
	local static_data_dir = os.getenv("RELIW_DATA_DIR") or "/www"
	local data_prefix = os.getenv("RELIW_REDIS_PREFIX") or "RLW"
	local redis_url = os.getenv("RELIW_REDIS_URL") or "127.0.0.1:6379/13"
	local cache_max_size = tonumber(os.getenv("RELIW_CACHE_MAX")) or 5242880 -- 5 megabyte by default
	local red, err = redis.connect(redis_url)
	if err then
		return nil, err
	end
	return {
		prefix = data_prefix,
		red = red,
		data_dir = static_data_dir,
		cache_max_size = cache_max_size,
		fetch_host_schema = fetch_host_schema,
		fetch_userinfo = fetch_userinfo,
		fetch_entry_metadata = fetch_entry_metadata,
		fetch_content = fetch_content,
		fetch_hash_and_size = fetch_static_content,
		fetch_userdata = fetch_userdata,
		check_rate_limit = check_rate_limit,
		set_session_data = set_session_data,
		destroy_session = destroy_session,
		fetch_session_user = fetch_session_user,
		fetch_metrics = fetch_metrics,
		update_metrics = update_metrics,
	}
end

return { new = new }
