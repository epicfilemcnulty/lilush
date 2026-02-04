-- SPDX-FileCopyrightText: © 2022—2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: OWL-1.0 or later
-- Licensed under the Open Weights License v1.0. See LICENSE for details.

local std = require("std")

-- Default max lines to prevent overwhelming context
local DEFAULT_MAX_LINES = 200

return {
	name = "read_file",
	description = {
		type = "function",
		["function"] = {
			name = "read_file",
			description = "Reads the local file at `filepath` and returns its content. "
				.. "Supports optional line range selection with start_line/end_line. "
				.. "Output is truncated to max_lines (default 200) to prevent context overflow.",
			parameters = {
				type = "object",
				properties = {
					filepath = { type = "string", description = "Absolute or relative path to the file to read" },
					start_line = {
						type = "integer",
						description = "First line to read (1-indexed). If omitted, starts from line 1.",
					},
					end_line = {
						type = "integer",
						description = "Last line to read (inclusive). If omitted, reads to end of file or max_lines.",
					},
					max_lines = {
						type = "integer",
						description = "Maximum number of lines to return (default: 200). Applied after range selection.",
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
			return { error = "filepath is required" }
		end

		-- Read file content
		local content, err = std.fs.read_file(filepath)
		if err then
			return { name = "read_file", filepath = filepath, error = err }
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
		local start_line = arguments.start_line or 1
		local end_line = arguments.end_line or total_lines
		local max_lines = arguments.max_lines or DEFAULT_MAX_LINES

		-- Validate range
		if start_line < 1 then
			start_line = 1
		end
		if end_line > total_lines then
			end_line = total_lines
		end
		if start_line > total_lines then
			return {
				name = "read_file",
				filepath = filepath,
				content = "",
				lines = { start = start_line, ["end"] = start_line - 1 },
				total_lines = total_lines,
				truncated = false,
				error = "start_line " .. start_line .. " is beyond file length (" .. total_lines .. " lines)",
			}
		end

		-- Extract requested range
		local selected = {}
		for i = start_line, end_line do
			table.insert(selected, lines[i])
		end

		-- Apply max_lines truncation
		local truncated = false
		local actual_end = end_line
		if #selected > max_lines then
			truncated = true
			actual_end = start_line + max_lines - 1
			local truncated_lines = {}
			for i = 1, max_lines do
				truncated_lines[i] = selected[i]
			end
			selected = truncated_lines
		end

		-- Build result
		local result = {
			name = "read_file",
			filepath = filepath,
			content = table.concat(selected, "\n"),
			lines = { start = start_line, ["end"] = actual_end },
			total_lines = total_lines,
			truncated = truncated,
		}

		-- Add hint if truncated
		if truncated then
			result.hint = "Output truncated at "
				.. max_lines
				.. " lines. Use start_line="
				.. (actual_end + 1)
				.. " to continue reading."
		end

		return result
	end,
}
