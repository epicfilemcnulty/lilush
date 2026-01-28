-- SPDX-FileCopyrightText: © 2022—2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: OWL-1.0 or later
-- Licensed under the Open Weights License v1.0. See LICENSE for details.

local std = require("std")
local web = require("web")

return {
	name = "fetch_webpage",
	description = {
		type = "function",
		["function"] = {
			name = "fetch_webpage",
			description = "Fetches the content of the webpage at the provided url, and returns it converted to plain text with `elinks -dump`.",
			parameters = {
				type = "object",
				properties = {
					url = { type = "string", description = "URL for the web page to fetch" },
				},
				required = { "url" },
			},
		},
	},
	execute = function(arguments)
		arguments = arguments or {}
		if not arguments.url then
			return { error = "url must be provided" }
		end

		local res, err = web.request(arguments.url)
		if err then
			return { error = "request failed: " .. err }
		end
		if res.status < 200 or res.status >= 400 then
			return { error = "request failed", status = res.status, body = tostring(res.body) }
		end

		local tmpfile = "/tmp/page_" .. std.nanoid() .. ".html"
		std.fs.write_file(tmpfile, res.body)
		local exec_res = std.ps.exec_simple("elinks -dump " .. tmpfile)
		std.fs.remove(tmpfile)
		return { name = "fetch_webpage", url = arguments.url, page = table.concat(exec_res.stdout, "\n") }
	end,
}
