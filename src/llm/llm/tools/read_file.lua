-- SPDX-FileCopyrightText: © 2022—2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: OWL-1.0 or later
-- Licensed under the Open Weights License v1.0. See LICENSE for details.

local std = require("std")

return {
	name = "read_file",
	description = {
		type = "function",
		["function"] = {
			name = "read_file",
			description = "Reads the local file at `filepath` and returns its content",
			parameters = {
				type = "object",
				properties = {
					filepath = { type = "string", description = "Absolute or relative path to the file to read" },
				},
				required = { "filepath" },
			},
		},
	},
	execute = function(arguments)
		arguments = arguments or {}
		local content, err = std.fs.read_file(arguments.filepath)
		if err then
			return { filename = arguments.filepath, error = err }
		end
		return { name = "read_file", filename = arguments.filepath, content = content }
	end,
}
