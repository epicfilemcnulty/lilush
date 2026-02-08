-- SPDX-FileCopyrightText: © 2022—2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: LicenseRef-OWL-1.0-or-later OR GPL-3.0-or-later
-- Dual-licensed under OWL v1.0+ and GPLv3+. See LICENSE and LICENSE-GPL3.

local show = function(method, query, args, headers, body, ctx)
	local storage = require("reliw.store")
	local store, err = storage.new(ctx.cfg)
	if not store then
		if ctx and ctx.logger and ctx.logger.log then
			ctx.logger:log({
				msg = "metrics store init failed",
				process = "metrics",
				error = tostring(err),
			}, "error")
		end
		return "db connection error", 503, { ["content-type"] = "text/plain" }
	end
	if query == "/metrics" and method == "GET" then
		local result = store:fetch_metrics()
		store:close()
		return result, 200, { ["content-type"] = "text/plain" }
	end
	store:close()
	return "Not Found", 404, { ["content-type"] = "text/plain" }
end

local update = function(store, host, method, query, status)
	return store:update_metrics(host, method, query, status)
end

return { show = show, update = update }
