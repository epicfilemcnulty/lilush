local store = require("reliw.store")
local json = require("cjson")
local crypto = require("crypto")
local web = require("web")

-- Set-Cookie: sessionToken=random_token; expires=Thu, 28 Jan 2022 00:00:00 UTC; path=/; domain=example.com; secure; HttpOnly
-- local expires = os.date("%a, %d-%b-%Y %H:%M:%S GMT", os.time())
-- local expires = os.date("%a, %d-%b-%Y %H:%M:%S GMT", os.time() + 60*60*24*7) 7 days in the future

local login = function(host, user, pass)
	local store, err = store.new()
	if not store then
		return nil, err
	end
	local user = user or ""
	local pass = pass or ""
	local user_info = store:fetch_userinfo(host, user)
	if user_info then
		local h = crypto.hmac(user_info.salt, pass)
		if crypto.bin_to_hex(h) == user_info.pass then
			return true
		end
	end
	return nil, "wrong login/pass"
end

local start_session = function(host, user, ttl)
	local store, err = store.new()
	if not store then
		return nil, err
	end
	local ttl = ttl or "600"
	local uuid, err = store:set_session_data(host, user, ttl)
	if uuid then
		return "rlw_session_token=" .. uuid .. "; secure; HttpOnly"
	end
	return nil, err
end

local get_session_user = function(headers)
	local store, err = store.new()
	if not store then
		return nil, err
	end
	local token = ""
	local host = headers.host
	local cookie = headers.cookie
	if cookie then
		token = cookie:match("rlw_session_token=([^%s;]+)")
	end
	return store:fetch_session_user(host, token)
end

local authorized = function(headers, allowed_users)
	local user = get_session_user(headers) or ""
	for _, u in ipairs(allowed_users) do
		if u == user then
			return true
		end
	end
	return false
end

local form = [[<form id="login_form" method="post">
<div>
<label for="login">login</label>
<input type="text" id="login" name="login" class="login">
</div>
<div>
<label for="path">password</label>
<input type="password" id="password" name="password" class="login"><br>
</div>
<button type="submit">Submit</button></form>]]

local login_page = function(method, query, args, headers, body)
	if method == "GET" then
		local content = form
		return content, 200
	end
	local args = web.parse_args(body)
	if login(headers["host"], args.login, args.password) then
		local session_cookie = start_session(headers["host"], args.login, 10800)
		if session_cookie then
			return "We're all good, babe.",
				303,
				{
					["Set-Cookie"] = session_cookie,
					["Location"] = query,
					["Content-Type"] = "text/plain",
				}
		end
	end
	return "Wrong login/pass", 401
end

local _M = {
	login = login,
	login_page = login_page,
	start_session = start_session,
	get_session_user = get_session_user,
	authenticated_as = get_session_user,
	authorized = authorized,
}
return _M
