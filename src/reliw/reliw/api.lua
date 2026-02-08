-- SPDX-FileCopyrightText: © 2022—2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: LicenseRef-OWL-1.0-or-later OR GPL-3.0-or-later
-- Dual-licensed under OWL v1.0+ and GPLv3+. See LICENSE and LICENSE-GPL3.

--[[ 
     RELIW assumes the following data schema in the redis DB:

     `RLW:API:vhost` is a JSON array of pattern-to-index mappings:
        [
          [ pattern, idx, true ],
          ...
          [ pattern, idx ]
        ]

     `RLW:API:vhost:idx` -- an API entry

     An API entry is a JSON object with the following structure:

     {
       file = "filename.dj", try_extensions = false,
       methods = { GET = true, POST = true },
       title = "Some title",
       index = "index.dj",
       css_file = "/css/some.css",
       favicon_file = "/images/favicon.svg",
       cache_control = "max-age=1800",
       auth = { "user1", "user2" },
       rate_limit = { GET = { limit = 5, period = 60 }}
     }

     `methods` table is the only required field.

     `title`, `css_file`, `favicon_file` only make sense for dynamically generated content,
     i.e. `text/djot`, `text/markdown` and `application/lua`.

     When `try_extensions` is true and no match found for raw query, 
     reliw will try adding `.lua` , `.dj` or `.md` to the query.

     `RLW:FILES:vhost:filename` -- Hashes for data files, fields: content, hash, size, mime, title
     `RLW:DATA:vhost:filename` -- Simple keys for userdata (data without API entries)

     `RLW:USERS:vhost` -- Hashes for vhost user, each user is a JSON object:
        { pass = hashed_password, salt = unique_salt }
]]

local proxy_config = function(store, host)
	return store:fetch_proxy_config(host)
end

local entry_index = function(store, host, query)
	local schema = store:fetch_host_schema(host) or {}
	for _, path in ipairs(schema) do
		-- path is an indexed array of 2 (optionally 3) elements: pattern, idx, is_exact_match
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

local entry_metadata = function(store, host, entry_id)
	return store:fetch_entry_metadata(host, entry_id)
end

local get_userdata = function(store, host, file)
	return store:fetch_userdata(host, file)
end

local get_content = function(store, host, query, metadata)
	return store:fetch_content(host, query, metadata)
end

local check_waf = function(store, host, query, headers)
	return store:check_waf(host, query, headers)
end

local add_waffer = function(store, ip)
	return store:add_waffer(ip)
end

local check_rate_limit = function(store, host, method, query, remote_ip, period)
	return store:check_rate_limit(host, method, query, remote_ip, period)
end

return {
	proxy_config = proxy_config,
	entry_index = entry_index,
	entry_metadata = entry_metadata,
	get_content = get_content,
	get_userdata = get_userdata,
	check_rate_limit = check_rate_limit,
	check_waf = check_waf,
	add_waffer = add_waffer,
}
