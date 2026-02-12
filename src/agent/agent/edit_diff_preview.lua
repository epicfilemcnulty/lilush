-- SPDX-FileCopyrightText: © 2022—2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: LicenseRef-OWL-1.0-or-later OR GPL-3.0-or-later
-- Dual-licensed under OWL v1.0+ and GPLv3+. See LICENSE and LICENSE-GPL3.

local std = require("std")

local DEFAULTS = {
	max_inline_lines = 20,
	max_inline_bytes = 4096,
}

local function split_lines(text)
	if type(text) ~= "string" then
		return { "" }
	end

	local lines = {}
	for line in (text .. "\n"):gmatch("(.-)\n") do
		lines[#lines + 1] = line
	end
	if #lines == 0 then
		lines[1] = ""
	end
	return lines
end

local function line_number_at_pos(content, pos)
	if type(content) ~= "string" or type(pos) ~= "number" or pos < 1 then
		return nil
	end
	local line = 1
	for _ in content:sub(1, pos - 1):gmatch("\n") do
		line = line + 1
	end
	return line
end

local function find_edit_start_line(filepath, old_text)
	if type(filepath) ~= "string" or filepath == "" then
		return nil
	end
	if type(old_text) ~= "string" or old_text == "" then
		return nil
	end

	local content = std.fs.read_file(filepath)
	if type(content) ~= "string" then
		return nil
	end

	local start_pos = content:find(old_text, 1, true)
	if not start_pos then
		return nil
	end

	return line_number_at_pos(content, start_pos)
end

local function build_header(start_line, old_count, new_count)
	local line = start_line and tostring(start_line) or "?"
	return "@@ -" .. line .. "," .. tostring(old_count) .. " +" .. line .. "," .. tostring(new_count) .. " @@"
end

local function build_preview(args, opts)
	args = args or {}
	opts = opts or {}

	local old_text = args.old_text
	local new_text = args.new_text
	if type(old_text) ~= "string" then
		return nil, "old_text must be a string"
	end
	if type(new_text) ~= "string" then
		return nil, "new_text must be a string"
	end

	local max_inline_lines = tonumber(opts.max_inline_lines) or DEFAULTS.max_inline_lines
	local max_inline_bytes = tonumber(opts.max_inline_bytes) or DEFAULTS.max_inline_bytes

	local old_lines = split_lines(old_text)
	local new_lines = split_lines(new_text)
	local start_line = find_edit_start_line(args.filepath, old_text)

	local full_lines = { build_header(start_line, #old_lines, #new_lines) }
	for _, line in ipairs(old_lines) do
		full_lines[#full_lines + 1] = "-" .. line
	end
	for _, line in ipairs(new_lines) do
		full_lines[#full_lines + 1] = "+" .. line
	end

	local changed_lines = #old_lines + #new_lines
	local full_bytes = #table.concat(full_lines, "\n")

	local truncated_reason = nil
	if changed_lines > max_inline_lines then
		truncated_reason = "line_limit"
	elseif full_bytes > max_inline_bytes then
		truncated_reason = "byte_limit"
	end

	return {
		start_line = start_line,
		inline_lines = truncated_reason and {} or std.tbl.copy(full_lines),
		full_lines = full_lines,
		truncated = truncated_reason ~= nil,
		truncated_reason = truncated_reason,
		stats = {
			old_lines = #old_lines,
			new_lines = #new_lines,
			delta_lines = #new_lines - #old_lines,
			changed_lines = changed_lines,
			old_bytes = #old_text,
			new_bytes = #new_text,
			full_bytes = full_bytes,
		},
	}
end

return {
	defaults = DEFAULTS,
	split_lines = split_lines,
	find_edit_start_line = find_edit_start_line,
	build = build_preview,
}
