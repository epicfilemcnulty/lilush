local store = require("reliw.store")

local show = function(method, query, args, headers, body)
	local store, err = store.new()
	if err then
		return nil, err
	end
	return store:fetch_metrics(), 200, { ["content-type"] = "text/plain" }
end

local update = function(host, method, query, status)
	local store, err = store.new()
	if err then
		return nil, err
	end
	return store:update_metrics(host, method, query, status)
end

return { show = show, update = update }
