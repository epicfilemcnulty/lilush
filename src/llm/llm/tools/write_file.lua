-- SPDX-FileCopyrightText: © 2022—2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: OWL-1.0 or later
-- Licensed under the Open Weights License v1.0. See LICENSE for details.

local std = require("std")

return {
	name = "write_file",
	description = {
		type = "function",
		["function"] = {
			name = "write_file",
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
			return { error = "filepath is required" }
		end
		if not content then
			return { error = "content is required" }
		end

		-- Check if file exists before writing
		local existed = std.fs.file_exists(filepath)

		-- Create parent directories if requested
		if arguments.create_dirs then
			local parent_dir = filepath:match("^(.+)/[^/]+$")
			if parent_dir and not std.fs.dir_exists(parent_dir) then
				local ok, err = std.fs.mkdir(parent_dir, nil, true)
				if not ok then
					return { name = "write_file", filepath = filepath, error = "failed to create directory: " .. err }
				end
			end
		end

		-- Write the file
		local ok, err = std.fs.write_file(filepath, content)
		if not ok then
			return { name = "write_file", filepath = filepath, error = err }
		end

		return {
			name = "write_file",
			filepath = filepath,
			bytes_written = #content,
			created = not existed,
		}
	end,
}
