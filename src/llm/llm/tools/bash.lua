-- SPDX-FileCopyrightText: © 2022—2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: LicenseRef-OWL-1.0-or-later OR GPL-3.0-or-later
-- Dual-licensed under OWL v1.0+ and GPLv3+. See LICENSE and LICENSE-GPL3.

local std = require("std")
local txt = require("std.txt")
local TOOL_NAME = "bash"

-- Maximum output size to prevent context overflow
local MAX_OUTPUT_CHARS = 10000

-- Patterns for potentially destructive commands.
-- Each entry: { lua_pattern_check_function, reason_string }
-- Checked against whitespace-normalized, lowercased command.
local DANGER_PATTERNS = {
	{
		function(cmd)
			return cmd:find("rm%s") and (cmd:find("%-r") or cmd:find("%-%-recursive"))
		end,
		"recursive delete",
	},
	{
		function(cmd)
			return cmd:find("mkfs")
		end,
		"filesystem format",
	},
	{
		function(cmd)
			return cmd:find("dd%s") and cmd:find("of=")
		end,
		"raw disk write",
	},
	{
		function(cmd)
			return cmd:find(">%s*/dev/sd.*")
				or cmd:find(">%s*/dev/nvme.*")
				or cmd:find(">%s*/dev/hd.*")
				or cmd:find(">%s*/dev/mmcblk.*")
		end,
		"device write",
	},
	{
		function(cmd)
			return cmd:find("git%s+push") and (cmd:find("%-%-force") or cmd:find("%s%-f") or cmd:find("^%-f"))
		end,
		"git force push",
	},
	{
		function(cmd)
			return cmd:find("git%s+reset") and cmd:find("%-%-hard")
		end,
		"git hard reset",
	},
	{
		function(cmd)
			return cmd:find("git%s+clean") and (cmd:find("%-f") or cmd:find("%-%-force"))
		end,
		"git force clean",
	},
	{
		function(cmd)
			return cmd:find(":%(%)") and cmd:find(":|:")
		end,
		"fork bomb",
	},
	{
		function(cmd)
			return cmd:find("%f[%w]shutdown%f[%W]") or cmd:find("%f[%w]reboot%f[%W]")
		end,
		"system shutdown/reboot",
	},
}

-- Returns nil if command looks safe, or a reason string if potentially destructive.
local function check_command(command)
	if type(command) ~= "string" or command == "" then
		return nil
	end
	local normalized = command:lower():gsub("%s+", " ")
	for _, entry in ipairs(DANGER_PATTERNS) do
		if entry[1](normalized) then
			return entry[2]
		end
	end
	return nil
end

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
	name = TOOL_NAME,
	description = {
		type = "function",
		["function"] = {
			name = TOOL_NAME,
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
			return { name = TOOL_NAME, ok = false, error = "command is required" }
		end

		local stdout_pipe = std.ps.pipe()
		local stderr_pipe = std.ps.pipe()

		local pid = std.ps.launch("/bin/bash", nil, stdout_pipe.inn, stderr_pipe.inn, "-c", command)
		if not pid then
			stdout_pipe:close_inn()
			stdout_pipe:close_out()
			stderr_pipe:close_inn()
			stderr_pipe:close_out()
			return { name = TOOL_NAME, ok = false, error = "failed to launch bash" }
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
			name = TOOL_NAME,
			ok = true,
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
	check_command = check_command,
}
