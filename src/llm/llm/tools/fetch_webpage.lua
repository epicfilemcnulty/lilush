-- SPDX-FileCopyrightText: © 2022—2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: LicenseRef-OWL-1.0-or-later OR GPL-3.0-or-later
-- Dual-licensed under OWL v1.0+ and GPLv3+. See LICENSE and LICENSE-GPL3.

local std = require("std")
local web = require("web")
local TOOL_NAME = "fetch_webpage"

return {
	name = TOOL_NAME,
	description = {
		type = "function",
		["function"] = {
			name = TOOL_NAME,
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
			return { name = TOOL_NAME, ok = false, error = "url must be provided" }
		end

		local res, err = web.request(arguments.url)
		if err then
			return { name = TOOL_NAME, ok = false, error = "request failed: " .. err }
		end
		if res.status < 200 or res.status >= 400 then
			return {
				name = TOOL_NAME,
				ok = false,
				error = "request failed",
				status = res.status,
				body = tostring(res.body),
			}
		end

		local tmpfile = "/tmp/page_" .. std.nanoid() .. ".html"
		local write_ok, write_err = std.fs.write_file(tmpfile, res.body)
		if not write_ok then
			return { name = TOOL_NAME, ok = false, error = "failed to write temp file: " .. tostring(write_err) }
		end
		local exec_res = std.ps.exec_simple("elinks -dump " .. tmpfile)
		std.fs.remove(tmpfile)
		if not exec_res or exec_res.status ~= 0 then
			return {
				name = TOOL_NAME,
				ok = false,
				error = "failed to render page with elinks",
				status = exec_res and exec_res.status or nil,
				stderr = exec_res and exec_res.stderr or nil,
			}
		end
		return {
			name = TOOL_NAME,
			ok = true,
			url = arguments.url,
			page = table.concat(exec_res.stdout or {}, "\n"),
		}
	end,
}
