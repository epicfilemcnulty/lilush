local crypto = require("crypto")
local web = require("web")

-- Set-Cookie: sessionToken=random_token; expires=Thu, 28 Jan 2022 00:00:00 UTC; path=/; domain=example.com; secure; HttpOnly
-- local expires = os.date("%a, %d-%b-%Y %H:%M:%S GMT", os.time())
-- local expires = os.date("%a, %d-%b-%Y %H:%M:%S GMT", os.time() + 60*60*24*7) 7 days in the future

local login = function(store, host, user, pass)
	local host = host:match("^([^:]+)")
	local user = user or ""
	local pass = pass or ""
	local user_info, err = store:fetch_userinfo(host, user)
	if user_info then
		local h = crypto.hmac(user_info.salt, pass)
		if crypto.bin_to_hex(h) == user_info.pass then
			return true
		end
	end
	return nil, "wrong login/pass"
end

local start_session = function(store, host, user, ttl)
	local host = host:match("^([^:]+)")
	local ttl = ttl or "600"
	local uuid, err = store:set_session_data(host, user, ttl)
	if uuid then
		return "rlw_session_token=" .. uuid .. "; secure; HttpOnly"
	end
	return nil, err
end

local get_session_user = function(store, headers)
	local token = ""
	local host = headers.host
	host = host:match("^([^:]+)")
	local cookie = headers.cookie
	if cookie then
		token = cookie:match("rlw_session_token=([^%s;]+)")
	end
	return store:fetch_session_user(host, token)
end

local logout = function(store, headers)
	local token = ""
	local host = headers.host
	-- TO DO: Should add `parse_host_from_headers` func to `web_server`...
	host = host:match("^([^:]+)")
	local cookie = headers.cookie
	if cookie then
		token = cookie:match("rlw_session_token=([^%s;]+)") or ""
	end
	store:destroy_session(host, token)
	return "Logging out...",
		303,
		{
			["set-cookie"] = { "rlw_session_token=" .. token .. "; Max-Age=0", "rlw_redirect=; Max-Age=0" },
			["location"] = "/",
		}
end

local authorized = function(store, headers, allowed_users)
	local user = get_session_user(store, headers) or ""
	for _, u in ipairs(allowed_users) do
		if u == user then
			return true
		end
	end
	return false
end

local login_form = [[<form id="login_form" method="post">
<div>
<label for="login">login</label>
<input type="text" id="login" name="login" class="login">
</div>
<div>
<label for="path">password</label>
<input type="password" id="password" name="password" class="login"><br>
</div>
<button type="submit">Submit</button></form>]]

local login_page = function(store, method, query, args, headers, body)
	if method == "GET" then
		return login_form, 200
	end
	local body_args = web.parse_args(body)
	if login(store, headers["host"], body_args.login, body_args.password) then
		local session_cookie = start_session(store, headers["host"], body_args.login, 10800) -- 3 hours TTL by default
		local cookie = headers.cookie
		local redirect_url = "/"
		if cookie then
			redirect_url = cookie:match("rlw_redirect=([^%s;]+)") or "/"
		end
		if session_cookie then
			return "We're all good, babe.",
				303,
				{
					["set-cookie"] = session_cookie,
					["location"] = redirect_url,
				}
		end
	end
	return "Wrong login/pass", 401
end

local _M = {
	login = login,
	logout = logout,
	login_page = login_page,
	start_session = start_session,
	get_session_user = get_session_user,
	authenticated_as = get_session_user,
	authorized = authorized,
}
return _M
