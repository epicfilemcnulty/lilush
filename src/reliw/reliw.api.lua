local std = require("std")
local store = require("reliw.store")
--[[ 
     RELIW assumes the following data schema in the redis DB:

     An API entry is a JSON object with the following structure:

     {
       file = "filename.dj",
       methods = { GET = true, POST = true },
       hash = sha256_checksum, size = size_in_bytes,
       title = "Some title", css_file = "/css/some.css", favicon_file = "/images/favicon.svg",
       cache_control = "max-age=1800",
       rate_limit = { GET = { limit = 5, period = 60 }}
     }

     `file` field is required for dynamic resources, `methods` table is required.
     `title`,`css_file`,`favicon_file` only make sense for dynamically generated content,
     i.e. `text/djot` and `application/lua`.


     `RLW:USERS:vhost` -- Hashes for vhost user, each user is a JSON object:
        { pass = hashed_password, salt = unique_salt }

     `RLW:API:vhost` is a JSON object:
        {
          exact = { pattern_1 = idx1, pattern2 = idx2, ...},
          patterns = { pattern_1 = idx1, pattern2 = idx2, ...},
          static = { pattern_1 = idx1, pattern2 = idx2, ...},
        }

     `RLW:API:vhost:idx` -- an API entry

     `RLW:TEXT:vhost:filename` -- Hashes for text files (MIME types `text/plain`, `text/html`, `text/djot`, `text/markdown`)
     `RLW:FILES:vhost:filename` -- Hashes for data files
        Required fields: `content` and `added`
        Optional fields: `updated` and `tags`

     `RLW:DATA:vhost:filename` -- Simple keys for userdata (data without API entries)
]]

local entry_index = function(host, query)
	local store, err = store.new()
	if err then
		return nil, err
	end
	local schema = store:fetch_host_schema(host) or {}
	for _, path in ipairs(schema) do
		-- path is an indexed array of 3 elements: pattern, idx, match_type
		if path[3] then -- exact matching
			if path[1] == query then
				return path[2]
			end
		elseif query:match(path[1]) then
			return path[2]
		end
	end
	return nil, "page not found"
end

local entry_metadata = function(host, entry_id)
	local store, err = store.new()
	if err then
		return nil, err
	end
	return store:fetch_entry_metadata(host, entry_id)
end

local get_userdata = function(host, file)
	local store, err = store.new()
	if err then
		return nil, err
	end
	return store:fetch_userdata(host, file)
end

local get_content = function(host, file)
	local store, err = store.new()
	if err then
		return nil, err
	end
	return store:fetch_content(host, file)
end

local get_static_content = function(host, query, metadata)
	local store, err = store.new()
	if err then
		return nil, err
	end
	return store:fetch_static_content(host, query, metadata)
end

local check_rate_limit = function(host, method, query, remote_ip, period)
	local store, err = store.new()
	if err then
		return nil, err
	end
	return store:check_rate_limit(host, method, query, remote_ip, period)
end

local api = {
	entry_index = entry_index,
	entry_metadata = entry_metadata,
	get_content = get_content,
	get_static_content = get_static_content,
	get_userdata = get_userdata,
	check_rate_limit = check_rate_limit,
}
return api