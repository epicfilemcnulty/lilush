-- SPDX-FileCopyrightText: © 2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: OWL-1.0 or later
-- Licensed under the Open Weights License v1.0. See LICENSE for details.

local std = require("std")
local txt = require("std.txt")

-- Maximum output size to prevent context overflow
local MAX_OUTPUT_CHARS = 10000

-- Truncate string to max length, returning truncated flag
-- Uses UTF-8-aware length/substring for proper character handling
-- Returns byte count for total size (useful for debugging)
local function truncate_output(str, max_chars)
	local char_len = std.utf.len(str)
	if char_len <= max_chars then
		return str, false, #str
	end
	return std.utf.sub(str, 1, max_chars), true, #str
end

return {
	name = "bash",
	description = {
		type = "function",
		["function"] = {
			name = "bash",
			description = "Executes a shell command and returns stdout, stderr, and exit code. "
				.. "Command runs in the current working directory. "
				.. "Output is truncated to 10K characters per stream to prevent context overflow.",
			parameters = {
				type = "object",
				properties = {
					command = { type = "string", description = "Shell command to execute" },
				},
				required = { "command" },
			},
		},
	},
	execute = function(arguments)
		arguments = arguments or {}
		local command = arguments.command

		if not command then
			return { error = "command is required" }
		end

		local stdout_pipe = std.ps.pipe()
		local stderr_pipe = std.ps.pipe()

		local pid = std.ps.launch("/bin/bash", nil, stdout_pipe.inn, stderr_pipe.inn, "-c", command)
		if not pid then
			stdout_pipe:close_inn()
			stdout_pipe:close_out()
			stderr_pipe:close_inn()
			stderr_pipe:close_out()
			return { error = "failed to launch bash" }
		end

		-- Close write ends in parent, read output, then close read ends
		stdout_pipe:close_inn()
		stderr_pipe:close_inn()
		local stdout_raw = stdout_pipe:read() or ""
		local stderr_raw = stderr_pipe:read() or ""
		stdout_pipe:close_out()
		stderr_pipe:close_out()

		-- Wait for process to finish
		local _, exit_code = std.ps.wait(pid)

		-- Split output into lines and rejoin (to normalize line endings)
		local stdout = table.concat(txt.lines(stdout_raw), "\n")
		local stderr = table.concat(txt.lines(stderr_raw), "\n")

		-- Truncate if necessary
		local stdout_truncated, stderr_truncated
		local stdout_total, stderr_total
		stdout, stdout_truncated, stdout_total = truncate_output(stdout, MAX_OUTPUT_CHARS)
		stderr, stderr_truncated, stderr_total = truncate_output(stderr, MAX_OUTPUT_CHARS)

		-- Build result
		local response = {
			name = "bash",
			command = command,
			exit_code = exit_code or 255,
			stdout = stdout,
			stderr = stderr,
		}

		-- Add truncation info if needed
		if stdout_truncated then
			response.stdout_truncated = true
			response.stdout_total_bytes = stdout_total
		end
		if stderr_truncated then
			response.stderr_truncated = true
			response.stderr_total_bytes = stderr_total
		end

		-- Add hint if any output was truncated
		if stdout_truncated or stderr_truncated then
			response.hint = "Output truncated. Consider piping to head/tail or filtering output."
		end

		return response
	end,
}
