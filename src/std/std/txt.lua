-- SPDX-FileCopyrightText: © 2023 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: GPL-3.0-or-later
local buffer = require("string.buffer")
local utf = require("std.utf")
local core = require("std.core")

local ascii_printable = function(filename)
	local f = io.open(filename)
	if f then
		local start = f:read(512)
		f:close()
		for c in start:gmatch(".") do
			local b = string.byte(c)
			if b < 32 or b > 126 then
				if b ~= 13 and b ~= 10 then
					return false
				end
			end
		end
		return true
	end
	return false
end

local valid_utf = function(filename)
	local f = io.open(filename)
	if f then
		local start = f:read(512)
		f:close()
		return utf.valid(start)
	end
	return false
end

local function lines(raw)
	raw = raw or ""
	local lines = {}
	if not raw:match("\n") then
		table.insert(lines, raw)
		return lines
	end
	for line in raw:gmatch("(.-)\r?\n") do
		table.insert(lines, line)
	end
	local tail = raw:match("\n([^\n\r]+)$")
	if tail then
		table.insert(lines, tail)
	end
	return lines
end

local function template(tmpl, sub_tbl, pattern)
	pattern = pattern or "%${([^}]+)}"
	if sub_tbl then
		return string.gsub(tmpl, pattern, sub_tbl)
	end
	local env = {}
	local strings = core.environ()
	for _, s in ipairs(strings) do
		local name = s:match("^([^=]+)")
		local value = s:match("^[^=]+=(.*)")
		env[name] = value
	end
	return string.gsub(tmpl, pattern, env)
end

local indent_lines = function(input, ind, exclude)
	input = input or {}
	ind = ind or 0
	exclude = exclude or {}
	setmetatable(exclude, {
		__index = function(t, k)
			return false
		end,
	})
	local indent_content = ""
	if type(ind) == "number" then
		indent_content = "\027[0m" .. string.rep(" ", ind)
	else
		indent_content = ind
	end
	local input_lines
	if type(input) == "table" then
		input_lines = input
	else
		input_lines = lines(input)
	end
	if type(ind) == "number" and ind == 0 then
		return input_lines
	end
	local output = {}
	for i, l in ipairs(input_lines) do
		if exclude[i] then
			table.insert(output, l)
		else
			table.insert(output, indent_content .. l)
		end
	end
	return output
end

local indent_all_lines_but_first = function(input, ind)
	return indent_lines(input, ind, { true })
end

local indent = function(input, ind, newline)
	local indented = indent_lines(input, ind)
	newline = newline or "\r\n"
	return table.concat(indented, newline)
end

--[[

    `lines_of` splits the `input` string into strings
    of `width` length and returns them in an array.

    When `force_split` is false, which is the default,
    the splits won't neccessarily be exactly of `width` length.

    That's because in this case the `input` string is only split 
    on spaces and hyphens. In other words, when we are processing a chunk
    and the chunk has reached the length of `width`, we continue to
    add characters to the chunk unil we encounter a space or a hyphen 
    in the `input`. 

    When `force_split` is true, all splits will be exactly of `width` length,
    and the `input` string is split on any character.
    
    When `remove_extra_spaces` is true (default is false), all
    occurences of consecutive spaces will be replaced by a single space.

]]
--
local lines_of = function(input, width, force_split, remove_extra_spaces)
	input = input or ""
	width = tonumber(width) or 80
	margin = math.ceil(width * 0.05)
	local buf = buffer.new()
	local state = {
		count = 0,
		esc = false,
		last_esc = "",
		last_space = 0,
	}
	for char in input:gmatch(utf.patterns.glob) do
		if state.esc then
			buf:put(char)
			if char == "m" then
				state.esc = false
			end
			state.last_esc = state.last_esc .. char
			if state.last_esc:match("\027%[0m$") then
				state.last_esc = ""
			end
		else
			if char == "\27" then
				state.esc = true
				state.last_esc = state.last_esc .. char
				buf:put(char)
			else
				state.count = state.count + 1
				if char == "\n" then
					buf:put("\n")
					if state.last_esc ~= "" then
						buf:put(state.last_esc)
					end
					state.count = 0
				else
					if
						(state.count == width and force_split)
						or (state.count >= width - margin and char:match("[%s-]"))
					then
						if char:match("%s") then
							char = "\n"
						else
							char = char .. "\n"
						end
						if state.last_esc ~= "" then
							char = char .. state.last_esc
						end
						state.count = 0
					else
						if char:match("^%s") then
							if state.count - state.last_space == 1 and remove_extra_spaces then
								char = ""
								state.count = state.count - 1
							else
								state.last_space = state.count
							end
						else
							state.last_space = 0
						end
					end
					buf:put(char)
				end
			end
		end
	end
	return lines(buf:get())
end

--[[ 
    Limits the string to a max terminal display width.
    If truncation is needed, inserts an ellipsis.
    Note: result may be shorter than `max` when wide glyphs are present.
]]
local limit = function(str, max, prefix)
	str = str or ""
	max = max or math.huge
	prefix = tonumber(prefix) or max
	if prefix > max then
		prefix = max
	end
	local ulen = utf.len(str)
	local dlen = utf.display_len(str)
	if dlen > max then
		local ellipsis = "…"
		local ellipsis_w = utf.display_len(ellipsis)
		local function prefix_by_display(target)
			if target <= 0 then
				return ""
			end
			local lo, hi = 0, ulen
			while lo < hi do
				local mid = math.floor((lo + hi + 1) / 2)
				local sub = utf.sub(str, 1, mid)
				if utf.display_len(sub) <= target then
					lo = mid
				else
					hi = mid - 1
				end
			end
			if lo == 0 then
				return ""
			end
			return utf.sub(str, 1, lo)
		end
		local function suffix_by_display(target)
			if target <= 0 then
				return ""
			end
			local lo, hi = 0, ulen
			while lo < hi do
				local mid = math.floor((lo + hi + 1) / 2)
				local start = ulen - mid + 1
				local sub = utf.sub(str, start, ulen)
				if utf.display_len(sub) <= target then
					lo = mid
				else
					hi = mid - 1
				end
			end
			if lo == 0 then
				return ""
			end
			return utf.sub(str, ulen - lo + 1, ulen)
		end
		if max == prefix then
			return prefix_by_display(prefix - ellipsis_w) .. ellipsis
		end
		local rest = max - prefix
		return prefix_by_display(prefix - ellipsis_w) .. ellipsis .. suffix_by_display(rest)
	end
	return str
end

local find_all_positions = function(input, pattern)
	if not input or not pattern then
		return nil
	end
	local i = 1
	local results = {}
	while i <= #input do
		local s, e = input:find(pattern, i)
		if not s then
			break
		end
		table.insert(results, { s, e })
		i = e + 1
	end
	return results
end

local split_by = function(input, pattern, ltrim, rtrim)
	local splits = find_all_positions(input, pattern)
	if not splits or #splits == 0 then
		return { { t = "reg", c = input } }
	end
	local ltrim = ltrim or 0
	local rtrim = rtrim or 0
	local lines = {}
	local idx = 1
	for i, v in ipairs(splits) do
		local reg = input:sub(idx, v[1] - 1)
		local cap = input:sub(v[1] + ltrim, v[2] - rtrim)
		idx = v[2] + 1
		if reg ~= "" then
			table.insert(lines, { t = "reg", c = reg })
		end
		table.insert(lines, { t = "cap", c = cap })
		if i == #splits then
			local reg = input:sub(v[2] + 1)
			if reg and reg ~= "" then
				table.insert(lines, { t = "reg", c = reg })
			end
		end
	end
	return lines
end

local align = function(text, max, side)
	text = tostring(text)
	max = max or math.huge
	side = side or "left"
	if side == "left" then
		local suf = max - utf.len(text)
		return text .. string.rep(" ", suf)
	end
	if side == "right" then
		local pre = max - utf.len(text)
		return string.rep(" ", pre) .. text
	end
	local pre, frac = math.modf((max - utf.len(text)) / 2)
	local suf = pre
	if frac == 0.5 then
		pre = pre + 1
	end
	return string.rep(" ", pre) .. text .. string.rep(" ", suf)
end

local txt = {
	lines = lines,
	lines_of = lines_of,
	limit = limit,
	indent = indent,
	align = align,
	indent_lines = indent_lines,
	indent_all_lines_but_first = indent_all_lines_but_first,
	find_all_positions = find_all_positions,
	template = template,
	split_by = split_by,
	ascii_printable = ascii_printable,
	valid_utf = valid_utf,
}
return txt
