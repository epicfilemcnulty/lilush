-- SPDX-FileCopyrightText: © 2022—2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: LicenseRef-OWL-1.0-or-later OR GPL-3.0-or-later
-- Dual-licensed under OWL v1.0+ and GPLv3+. See LICENSE and LICENSE-GPL3.

local std = require("std")
local TOOL_NAME = "edit"

-- Count occurrences of a pattern in a string
local function count_occurrences(str, pattern)
	local count = 0
	local start = 1
	while true do
		local start_pos, end_pos = str:find(pattern, start, true) -- plain text search
		if not start_pos then
			break
		end
		count = count + 1
		start = end_pos + 1
	end
	return count
end

-- Find line number for a position in content
local function find_line_number(content, pos)
	local line = 1
	for i = 1, pos - 1 do
		if content:sub(i, i) == "\n" then
			line = line + 1
		end
	end
	return line
end

return {
	name = TOOL_NAME,
	description = {
		type = "function",
		["function"] = {
			name = TOOL_NAME,
			description = "Edits a file by replacing exact text. "
				.. "Finds `old_text` in the file and replaces it with `new_text`. "
				.. "The old_text must match exactly (including whitespace and indentation). "
				.. "Fails if old_text is not found or if it appears multiple times (provide more context to disambiguate).",
			parameters = {
				type = "object",
				properties = {
					filepath = { type = "string", description = "Path to the file to edit" },
					old_text = {
						type = "string",
						description = "Exact text to find and replace (must be unique in file)",
					},
					new_text = { type = "string", description = "Text to replace old_text with" },
				},
				required = { "filepath", "old_text", "new_text" },
			},
		},
	},
	execute = function(arguments)
		arguments = arguments or {}
		local filepath = arguments.filepath
		local old_text = arguments.old_text
		local new_text = arguments.new_text

		if not filepath then
			return { name = TOOL_NAME, ok = false, error = "filepath is required" }
		end
		if not old_text or old_text == "" then
			return { name = TOOL_NAME, ok = false, error = "old_text is required and cannot be empty" }
		end
		if new_text == nil then
			return { name = TOOL_NAME, ok = false, error = "new_text is required" }
		end

		-- Read file content
		local content, err = std.fs.read_file(filepath)
		if err then
			return { name = TOOL_NAME, ok = false, filepath = filepath, error = "failed to read file: " .. err }
		end

		-- Check for occurrences
		local occurrences = count_occurrences(content, old_text)

		if occurrences == 0 then
			return {
				name = TOOL_NAME,
				ok = false,
				filepath = filepath,
				error = "old_text not found in file",
			}
		end

		if occurrences > 1 then
			return {
				name = TOOL_NAME,
				ok = false,
				filepath = filepath,
				error = "old_text found "
					.. occurrences
					.. " times in file. Provide more surrounding context to make the match unique.",
			}
		end

		-- Find position and line number before replacement
		local start_pos, end_pos = content:find(old_text, 1, true)
		local line_number = find_line_number(content, start_pos)
		-- Perform replacement
		local new_content = content:sub(1, start_pos - 1) .. new_text .. content:sub(end_pos + 1)

		-- Write back to file
		local ok, write_err = std.fs.write_file(filepath, new_content)
		if not ok then
			return { name = TOOL_NAME, ok = false, filepath = filepath, error = "failed to write file: " .. write_err }
		end

		return {
			name = TOOL_NAME,
			ok = true,
			filepath = filepath,
			success = true,
			line = line_number,
		}
	end,
}
