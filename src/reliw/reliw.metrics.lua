local std = require("std")

local show = function(method, query, args, headers, body, ctx)
	local storage = require("reliw.store")
	local store, err = storage.new(ctx.cfg)
	if err then
		return "db connection error", 501, { ["content-type"] = "text/plain" }
	end
	if query == "/metrics" and method == "GET" then
		return store:fetch_metrics(), 200, { ["content-type"] = "text/plain" }
	end
	return "Not Found", 404, { ["content-type"] = "text/plain" }
end

local update = function(store, host, method, query, status)
	return store:update_metrics(host, method, query, status)
end

return { show = show, update = update }
