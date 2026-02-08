-- SPDX-FileCopyrightText: © 2022—2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: LicenseRef-OWL-1.0-or-later OR GPL-3.0-or-later
-- Dual-licensed under OWL v1.0+ and GPLv3+. See LICENSE and LICENSE-GPL3.

local web = require("web")
local json = require("cjson.safe")

local api_url = "https://api.linkup.so/v1/search"
local TOOL_NAME = "web_search"

return {
	name = TOOL_NAME,
	description = {
		type = "function",
		["function"] = {
			name = TOOL_NAME,
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
			return { name = TOOL_NAME, ok = false, error = "LINKUP_API_TOKEN is not set" }
		end
		if not arguments.query then
			return { name = TOOL_NAME, ok = false, error = "no query provided" }
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
			return { name = TOOL_NAME, ok = false, error = "failed to JSON encode request: " .. err }
		end

		local res, err = web.request(api_url, { method = "POST", headers = headers, body = body })
		if res and res.body and res.status >= 200 and res.status < 400 then
			local answer, err = json.decode(res.body)
			if err then
				return { name = TOOL_NAME, ok = false, error = "failed to decode response: " .. err }
			end
			return { name = TOOL_NAME, ok = true, results = answer }
		end

		res = res or {}
		return {
			name = TOOL_NAME,
			ok = false,
			error = err or "request failed",
			status = tonumber(res.status) or nil,
		}
	end,
}
