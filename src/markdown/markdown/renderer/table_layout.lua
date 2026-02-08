-- SPDX-FileCopyrightText: © 2022—2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: LicenseRef-OWL-1.0-or-later OR GPL-3.0-or-later
-- Dual-licensed under OWL v1.0+ and GPLv3+. See LICENSE and LICENSE-GPL3.

local std = require("std")

local take_prefix_by_display = function(text, max_width)
	local utf_len = std.utf.len(text)
	if utf_len == 0 or max_width <= 0 then
		return "", 0, 0
	end

	local lo, hi = 0, utf_len
	while lo < hi do
		local mid = math.floor((lo + hi + 1) / 2)
		local sub = std.utf.sub(text, 1, mid)
		if std.utf.display_len(sub) <= max_width then
			lo = mid
		else
			hi = mid - 1
		end
	end

	if lo == 0 then
		return "", 0, 0
	end

	local prefix = std.utf.sub(text, 1, lo)
	return prefix, lo, std.utf.display_len(prefix)
end

local trim_trailing_spaces = function(parts, line_width)
	local trimmed = {}
	for i = 1, #parts do
		trimmed[i] = parts[i]
	end

	while #trimmed > 0 and trimmed[#trimmed].is_space do
		line_width = line_width - trimmed[#trimmed].width
		trimmed[#trimmed] = nil
	end

	return trimmed, math.max(0, line_width)
end

-- Wrap plain text to width while tracking source UTF character spans.
-- Returns array of lines: { text, width, parts = { { text, width, start, stop, is_space } } }
local wrap_text_with_spans = function(text, width)
	text = text or ""
	width = math.max(1, math.floor(tonumber(width) or 1))

	local tokens = {}
	local char_pos = 1
	local active = nil

	for ch in text:gmatch(std.utf.patterns.glob) do
		local is_space = ch:match("^%s$") ~= nil
		local ch_w = std.utf.display_len(ch)
		if not active or active.is_space ~= is_space then
			active = {
				text = ch,
				width = ch_w,
				start = char_pos,
				stop = char_pos,
				is_space = is_space,
			}
			tokens[#tokens + 1] = active
		else
			active.text = active.text .. ch
			active.width = active.width + ch_w
			active.stop = char_pos
		end
		char_pos = char_pos + 1
	end

	local lines = {}
	local line_parts = {}
	local line_width = 0

	local function add_part(text_part, width_part, start_pos, stop_pos, is_space)
		line_parts[#line_parts + 1] = {
			text = text_part,
			width = width_part,
			start = start_pos,
			stop = stop_pos,
			is_space = is_space,
		}
		line_width = line_width + width_part
	end

	local function emit_line(force_empty)
		local parts, width_now = trim_trailing_spaces(line_parts, line_width)
		if #parts > 0 or force_empty then
			local text_parts = {}
			for i = 1, #parts do
				text_parts[i] = parts[i].text
			end
			lines[#lines + 1] = {
				text = table.concat(text_parts),
				width = width_now,
				parts = parts,
			}
		end
		line_parts = {}
		line_width = 0
	end

	for _, token in ipairs(tokens) do
		if token.is_space then
			if #line_parts > 0 then
				if line_width + token.width <= width then
					add_part(token.text, token.width, token.start, token.stop, true)
				else
					emit_line(false)
				end
			end
		else
			local rem_text = token.text
			local rem_start = token.start
			local rem_chars = std.utf.len(rem_text)
			local rem_width = token.width

			while rem_chars > 0 do
				local available = width - line_width
				if available <= 0 then
					emit_line(false)
					available = width
				end

				if rem_width <= available then
					add_part(rem_text, rem_width, rem_start, rem_start + rem_chars - 1, false)
					break
				end

				if #line_parts > 0 then
					emit_line(false)
				else
					local part_text, part_chars, part_width = take_prefix_by_display(rem_text, available)
					if part_chars == 0 then
						part_text = std.utf.sub(rem_text, 1, 1)
						part_chars = 1
						part_width = std.utf.display_len(part_text)
					end

					add_part(part_text, part_width, rem_start, rem_start + part_chars - 1, false)
					emit_line(false)

					if part_chars >= rem_chars then
						break
					end

					rem_start = rem_start + part_chars
					rem_chars = rem_chars - part_chars
					rem_text = std.utf.sub(rem_text, part_chars + 1, part_chars + rem_chars)
					rem_width = std.utf.display_len(rem_text)
				end
			end
		end
	end

	emit_line(#lines == 0)
	return lines
end

local fit_table_width = function(col_widths, available_width)
	local cols = #col_widths
	if cols == 0 then
		return col_widths
	end

	-- Row width = sum(col_widths) + (3 * cols + 1)
	local fixed_width = 3 * cols + 1
	local target_sum = available_width - fixed_width

	local min_col_width = 3
	if target_sum < cols * min_col_width then
		min_col_width = 1
	end

	local total = 0
	for i = 1, cols do
		local w = math.floor(tonumber(col_widths[i]) or 0)
		if w < min_col_width then
			w = min_col_width
		end
		col_widths[i] = w
		total = total + w
	end

	local min_total = cols * min_col_width
	if target_sum < min_total then
		target_sum = min_total
	end

	while total > target_sum do
		local widest_idx = nil
		local widest = min_col_width
		for i = 1, cols do
			if col_widths[i] > widest then
				widest = col_widths[i]
				widest_idx = i
			end
		end
		if not widest_idx then
			break
		end
		col_widths[widest_idx] = col_widths[widest_idx] - 1
		total = total - 1
	end

	return col_widths
end

local compute_padding = function(align, width, content_width)
	align = align or "left"
	width = math.max(0, tonumber(width) or 0)
	content_width = math.max(0, tonumber(content_width) or 0)
	local total_pad = math.max(0, width - content_width)

	if align == "right" then
		return total_pad, 0
	end
	if align == "center" then
		local left_pad = math.floor(total_pad / 2)
		return left_pad, total_pad - left_pad
	end
	return 0, total_pad
end

local normalize_overflow = function(mode)
	if mode == "clip" then
		return "clip"
	end
	return "wrap"
end

return {
	compute_padding = compute_padding,
	fit_table_width = fit_table_width,
	normalize_overflow = normalize_overflow,
	wrap_text_with_spans = wrap_text_with_spans,
}
