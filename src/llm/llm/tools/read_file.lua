-- SPDX-FileCopyrightText: © 2022—2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: LicenseRef-OWL-1.0-or-later OR GPL-3.0-or-later
-- Dual-licensed under OWL v1.0+ and GPLv3+. See LICENSE and LICENSE-GPL3.

local std = require("std")

local DEFAULT_LIMIT = 1000
local TOOL_NAME = "read"

return {
	name = TOOL_NAME,
	description = {
		type = "function",
		["function"] = {
			name = TOOL_NAME,
			description = "Reads the local file at `filepath` and returns its content. "
				.. "Supports optional line pagination with offset/limit. "
				.. string.format(
					"Output is truncated to limit (default %d) to prevent context overflow.",
					DEFAULT_LIMIT
				),
			parameters = {
				type = "object",
				properties = {
					filepath = { type = "string", description = "Absolute or relative path to the file to read" },
					offset = {
						type = "integer",
						description = "Number of lines to skip from the start of file (1-indexed, default: 1).",
					},
					limit = {
						type = "integer",
						description = string.format("Maximum number of lines to return (default: %d).", DEFAULT_LIMIT),
					},
				},
				required = { "filepath" },
			},
		},
	},
	execute = function(arguments)
		arguments = arguments or {}
		local filepath = arguments.filepath
		if not filepath then
			return { name = TOOL_NAME, ok = false, error = "filepath is required" }
		end

		-- Read file content
		local content, err = std.fs.read_file(filepath)
		if err then
			return { name = TOOL_NAME, ok = false, filepath = filepath, error = err }
		end

		-- Split into lines
		local lines = {}
		for line in content:gmatch("([^\n]*)\n?") do
			table.insert(lines, line)
		end
		-- Remove trailing empty line if file doesn't end with newline
		if #lines > 0 and lines[#lines] == "" then
			table.remove(lines)
		end

		local total_lines = #lines
		local offset = tonumber(arguments.offset) or 1
		local requested_limit = tonumber(arguments.limit) or DEFAULT_LIMIT

		if offset < 1 then
			offset = 1
		end
		if requested_limit < 1 then
			requested_limit = 1
		end

		local start_line = offset
		if start_line > total_lines then
			return {
				name = TOOL_NAME,
				ok = true,
				filepath = filepath,
				content = "",
				lines = { start = start_line, ["end"] = total_lines },
				total_lines = total_lines,
				truncated = false,
				offset = offset,
				limit = requested_limit,
			}
		end

		local limit = requested_limit
		if limit > DEFAULT_LIMIT then
			limit = DEFAULT_LIMIT
		end

		local end_line = math.min(total_lines, start_line + limit - 1)
		local selected = {}
		for i = start_line, end_line do
			table.insert(selected, lines[i])
		end

		local truncated = end_line < total_lines

		local result = {
			name = TOOL_NAME,
			ok = true,
			filepath = filepath,
			content = table.concat(selected, "\n"),
			lines = { start = start_line, ["end"] = end_line },
			total_lines = total_lines,
			truncated = truncated,
			offset = offset,
			limit = requested_limit,
		}

		if truncated then
			result.hint = "Output truncated at "
				.. #selected
				.. " lines. Use offset="
				.. end_line
				.. " to continue reading."
		end

		return result
	end,
}
