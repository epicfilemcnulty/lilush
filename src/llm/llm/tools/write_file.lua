-- SPDX-FileCopyrightText: © 2022—2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: LicenseRef-OWL-1.0-or-later OR GPL-3.0-or-later
-- Dual-licensed under OWL v1.0+ and GPLv3+. See LICENSE and LICENSE-GPL3.

local std = require("std")
local TOOL_NAME = "write"

return {
	name = TOOL_NAME,
	description = {
		type = "function",
		["function"] = {
			name = TOOL_NAME,
			description = "Writes content to a file at the specified path. "
				.. "Overwrites the file if it exists, creates it if it doesn't. "
				.. "Use create_dirs=true to create parent directories if they don't exist.",
			parameters = {
				type = "object",
				properties = {
					filepath = { type = "string", description = "Path to the file to write" },
					content = { type = "string", description = "Content to write to the file" },
					create_dirs = {
						type = "boolean",
						description = "Create parent directories if they don't exist (default: false)",
					},
				},
				required = { "filepath", "content" },
			},
		},
	},
	execute = function(arguments)
		arguments = arguments or {}
		local filepath = arguments.filepath
		local content = arguments.content

		if not filepath then
			return { name = TOOL_NAME, ok = false, error = "filepath is required" }
		end
		if content == nil then
			return { name = TOOL_NAME, ok = false, error = "content is required" }
		end

		-- Check if file exists before writing
		local existed = std.fs.file_exists(filepath)

		-- Create parent directories if requested
		if arguments.create_dirs then
			local parent_dir = filepath:match("^(.+)/[^/]+$")
			if parent_dir and not std.fs.dir_exists(parent_dir) then
				local ok, err = std.fs.mkdir(parent_dir, nil, true)
				if not ok then
					return {
						name = TOOL_NAME,
						ok = false,
						filepath = filepath,
						error = "failed to create directory: " .. err,
					}
				end
			end
		end

		-- Write the file
		local ok, err = std.fs.write_file(filepath, content)
		if not ok then
			return { name = TOOL_NAME, ok = false, filepath = filepath, error = err }
		end

		return {
			name = TOOL_NAME,
			ok = true,
			filepath = filepath,
			bytes_written = #content,
			created = not existed,
		}
	end,
}
