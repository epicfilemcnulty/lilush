-- SPDX-FileCopyrightText: © 2022—2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: OWL-1.0 or later
-- Licensed under the Open Weights License v1.0. See LICENSE for details.

local web = require("web")
local json = require("cjson.safe")

local api_url = "https://api.linkup.so/v1/search"

return {
	name = "web_search",
	description = {
		type = "function",
		["function"] = {
			name = "web_search",
			description = "Returns google search results and a suggested answer for the provided query, in JSON format.",
			parameters = {
				type = "object",
				properties = {
					query = { type = "string", description = "Search query" },
				},
				required = { "query" },
			},
		},
	},
	execute = function(arguments)
		arguments = arguments or {}
		local token = os.getenv("LINKUP_API_TOKEN")
		if not token then
			return { error = "LINKUP_API_TOKEN is not set" }
		end
		if not arguments.query then
			return { error = "no query provided" }
		end

		local headers = {
			["Content-Type"] = "application/json",
			["Authorization"] = "Bearer " .. token,
		}
		local req = {
			depth = "standard",
			outputType = "sourcedAnswer",
			includeImages = false,
			q = arguments.query,
		}
		local body, err = json.encode(req)
		if err then
			return { error = "failed to JSON encode request: " .. err }
		end

		local res, err = web.request(api_url, { method = "POST", headers = headers, body = body })
		if res and res.body and res.status >= 200 and res.status < 400 then
			local answer, err = json.decode(res.body)
			if err then
				return { error = "failed to decode response: " .. err }
			end
			return { name = "web_search", results = answer }
		end

		res = res or {}
		return { msg = "request failed", error = err, status = tostring(res.status) }
	end,
}
