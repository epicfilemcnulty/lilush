-- SPDX-FileCopyrightText: © 2023 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: GPL-3.0-or-later
local buffer = require("string.buffer")
local utf = require("std.utf")
local txt = require("std.txt")

local render
render = function(t, indent)
	t = t or "nil"
	if type(t) ~= "table" then
		return tostring(t)
	end
	indent = indent or 1
	local buf = buffer.new()
	if indent == 1 then
		buf:put("{\n")
	end
	for k, v in pairs(t) do
		local formatting = string.rep("  ", indent) .. k .. " = "
		if type(v) == "table" then
			buf:put(formatting .. "{\n", render(v, indent + 1), string.rep(" ", indent + indent), "},\n")
		elseif type(v) == "string" then
			buf:put(formatting, '"', v, '",\n')
		else
			buf:put(formatting, tostring(v), ",\n")
		end
	end
	if indent == 1 then
		buf:put("}\n")
	end
	return buf:get()
end

local print_tbl = function(t)
	print(render(t))
end

local table_deep_copy
table_deep_copy = function(source_table, _cyclic_cache)
	-- NOTE: We remember "seen" source tables, to avoid infinite loops with cyclic tables.
	local result = {}
	_cyclic_cache = _cyclic_cache or {}
	_cyclic_cache[source_table] = result
	for key, value in pairs(source_table) do
		if type(value) == "table" then
			-- Check cyclic cache for a previous result.
			-- NOTE: We use "ternary" assignment, since we can be sure that every
			-- value in the "cyclic cache" is "truthy" (they're always tables).
			result[key] = _cyclic_cache[value] or table_deep_copy(value, _cyclic_cache)
		else
			result[key] = value
		end
	end

	return result
end

local merge_tables
merge_tables = function(defaults, options)
	defaults = defaults or {}
	if options then
		for k, v in pairs(options) do
			if (type(v) == "table") and (type(defaults[k] or false) == "table") then
				merge_tables(defaults[k], options[k])
			else
				defaults[k] = v
			end
		end
	end
	return defaults
end

local get_value_by_ref = function(tbl, ref)
	local obj = tbl
	for e in ref:gmatch("([^.]+)%.?") do
		if obj[e] == nil then
			return nil
		end
		obj = obj[e]
	end
	return obj
end
--[[
    `alphanumsort` below is authored by [Paul Kulchenko](http://kulchenko.com/), 
    the creator of [ZeroBrane Studio Lua IDE](https://studio.zerobrane.com/).

    See [notebook](http://notebook.kulchenko.com/algorithms/alphanumeric-natural-sorting-for-humans-in-lua)
    for the details and variants of the implementation with different "precision".

]]
--
local alphanumsort = function(o)
	local function padnum(d)
		local r = string.match(d, "0*(.+)")
		return ("%03d%s"):format(#r, r)
	end
	table.sort(o, function(a, b)
		return tostring(a):gsub("%d+", padnum) < tostring(b):gsub("%d+", padnum)
	end)
	return o
end

local sort_keys = function(t)
	local tkeys = {}
	for k in pairs(t) do
		table.insert(tkeys, k)
	end
	return alphanumsort(tkeys)
end

local function include_keys(t, pattern)
	t = t or {}
	pattern = pattern or ".*"
	local matched = {}
	for _, v in ipairs(t) do
		if type(v) == "string" and v:match("^" .. pattern) then
			table.insert(matched, v)
		end
	end
	return matched
end

local function exclude_keys(t, pattern)
	t = t or {}
	pattern = pattern or ".*"
	local matched = {}
	for _, v in ipairs(t) do
		if type(v) == "string" and not v:match("^" .. pattern) then
			table.insert(matched, v)
		end
	end
	return matched
end

local function longest(t)
	local max = 0
	t = t or {}
	for _, v in ipairs(t) do
		if type(v) == "string" then
			local utf_len = utf.len(v)
			if utf_len > max then
				max = utf_len
			end
		end
	end
	return max
end

local contains = function(tbl, element, fuzzy)
	tbl = tbl or {}
	local element_is_string = type(element) == "string"
	for i, v in ipairs(tbl) do
		if v == element then
			return i
		end
		if fuzzy and element_is_string and type(v) == "string" then
			local esc_element = element:gsub("[+*%%%.%$[%]%?%(%)-]", "%%%1")
			if v:match(esc_element) then
				return i
			end
		end
	end
	return nil
end

-- Shuffle a table in place,
-- Fisher-Yates shuffle method
local shuffle = function(tbl)
	for i = #tbl, 2, -1 do
		local j = math.random(i)
		tbl[i], tbl[j] = tbl[j], tbl[i]
	end
end

local sort_by_str_len = function(tbl)
	if tbl then
		table.sort(tbl, function(a, b)
			if utf.len(a) < utf.len(b) then
				return true
			elseif utf.len(a) == utf.len(b) then
				return tostring(a) < tostring(b)
			end
			return false
		end)
	end
	return tbl
end

--[[
Parse a pipe table header definition.

Supports multiple formats:
  - "Name"           -> name="Name", align="left" (default)
  - "Name:right"     -> name="Name", align="right"
  - "Name:r"         -> name="Name", align="right"
  - "Name:center"    -> name="Name", align="center"
  - "Name:c"         -> name="Name", align="center"
  - "Name:left"      -> name="Name", align="left"
  - "Name:l"         -> name="Name", align="left"
  - {"Name", "right"} -> name="Name", align="right" (legacy format)

Returns: name (string), align ("left"|"center"|"right")
]]
local parse_pipe_table_header = function(header)
	header = header or ""
	local name = header
	local align = "left"

	if type(header) == "table" then
		-- Legacy format: {"Name", "align"}
		name = header[1] or ""
		align = header[2] or "left"
	elseif type(header) == "string" then
		-- New format: "Name:align" or just "Name"
		local base, suffix = header:match("^(.+):([lcr]?[a-z]*)$")
		if base and suffix then
			name = base
			-- Normalize alignment suffix
			if suffix == "r" or suffix == "right" then
				align = "right"
			elseif suffix == "c" or suffix == "center" then
				align = "center"
			elseif suffix == "l" or suffix == "left" then
				align = "left"
			end
		end
	end

	return name, align
end

--[[
Calculate maximum display widths for each column in a table.

Uses utf.display_len for proper handling of wide characters (CJK, emoji, etc.).

Parameters:
  headers - array of header definitions (see parse_pipe_table_header)
  tbl     - array of rows, each row is an array of cell values

Returns: table mapping column index to max display width
]]
local calc_table_maxes = function(headers, tbl)
	local maxes = {}
	headers = headers or {}
	tbl = tbl or {}

	-- Initialize with header widths
	for i, header in ipairs(headers) do
		local h_name = parse_pipe_table_header(header)
		maxes[i] = utf.display_len(h_name)
	end

	-- Update with cell widths
	for _, row in ipairs(tbl) do
		for j, col in ipairs(row) do
			if headers[j] then
				local display_width = utf.display_len(tostring(col))
				if display_width > (maxes[j] or 0) then
					maxes[j] = display_width
				end
			end
		end
	end

	return maxes
end

--[[
Generate a markdown pipe table from headers and data.

Parameters:
  headers - array of header definitions, each can be:
            - "Name"           (left aligned)
            - "Name:right"     (right aligned)
            - "Name:center"    (center aligned)
            - {"Name", "right"} (legacy format)
  tbl     - array of rows, each row is an array of cell values

Returns: array of strings (one per line) forming the markdown table

Example:
  local lines = pipe_table(
    { "Name", "Age:right", "City:center" },
    {
      { "Alice", 30, "New York" },
      { "Bob", 25, "Los Angeles" },
    }
  )
]]
local pipe_table = function(headers, tbl)
	local lines = {}
	local maxes = calc_table_maxes(headers, tbl)

	-- Build header line and separator line
	local h_line = "|"
	local s_line = "|"

	for i, header in ipairs(headers) do
		local h_name, h_align = parse_pipe_table_header(header)
		local col_width = maxes[i] or utf.display_len(h_name)

		-- Headers are center-aligned within their column
		h_line = h_line .. " " .. txt.align(h_name, col_width, "center") .. " |"

		-- Build separator with alignment markers
		if h_align == "center" then
			s_line = s_line .. ":" .. string.rep("-", col_width) .. ":|"
		elseif h_align == "right" then
			s_line = s_line .. string.rep("-", col_width + 1) .. ":|"
		else -- left (default)
			s_line = s_line .. ":" .. string.rep("-", col_width + 1) .. "|"
		end
	end

	lines[1] = h_line
	lines[2] = s_line

	-- Build data rows
	for i, row in ipairs(tbl) do
		local line = "|"
		for j, col in ipairs(row) do
			if headers[j] then
				local _, h_align = parse_pipe_table_header(headers[j])
				local col_width = maxes[j]
				line = line .. " " .. txt.align(tostring(col), col_width, h_align) .. " |"
			end
		end
		lines[i + 2] = line
	end

	return lines
end

local empty = function(tbl)
	if type(tbl) == "table" and next(tbl) == nil then
		return true
	end
	return false
end

local tbl = {
	render = render,
	print = print_tbl,
	merge = merge_tables,
	copy = table_deep_copy,
	pipe_table = pipe_table,
	parse_pipe_table_header = parse_pipe_table_header,
	calc_table_maxes = calc_table_maxes,
	alphanumsort = alphanumsort,
	sort_keys = sort_keys,
	longest = longest,
	contains = contains,
	shuffle = shuffle,
	empty = empty,
	include_keys = include_keys,
	exclude_keys = exclude_keys,
	sort_by_str_len = sort_by_str_len,
	get_value_by_ref = get_value_by_ref,
}
return tbl
