-- SPDX-FileCopyrightText: © 2023 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: GPL-3.0-or-later
local buffer = require("string.buffer")
local utf = require("std.utf")
local txt = require("std.txt")

local render
render = function(t, indent)
	local t = t or "nil"
	if type(t) ~= "table" then
		return tostring(t)
	end
	local indent = indent or 1
	local buf = buffer.new()
	if indent == 1 then
		buf:put("{\n")
	end
	for k, v in pairs(t) do
		formatting = string.rep("  ", indent) .. k .. " = "
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
	local defaults = defaults or {}
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
		if not obj[e] then
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
	local t = t or {}
	local pattern = pattern or ".*"
	local matched = {}
	for _, v in ipairs(t) do
		if v:match("^" .. pattern) then
			table.insert(matched, v)
		end
	end
	return matched
end

local function exclude_keys(t, pattern)
	local t = t or {}
	local pattern = pattern or ".*"
	local matched = {}
	for _, v in ipairs(t) do
		if not v:match("^" .. pattern) then
			table.insert(matched, v)
		end
	end
	return matched
end

local function longest(t)
	local max = 0
	local t = t or {}
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

local parse_pipe_table_header = function(header)
	local header = header or ""
	local name = header
	local align = "left"
	if type(header) == "table" then
		name = header[1]
		align = header[2]
	end
	return name, align
end

local calc_table_maxes = function(headers, tbl)
	local maxes = {}
	local headers = headers or {}
	local tbl = tbl or {}
	for i, header in ipairs(headers) do
		local h_name, h_align = parse_pipe_table_header(header)
		maxes[h_name] = utf.len(h_name)
	end
	for i, row in ipairs(tbl) do
		for j, col in ipairs(row) do
			if headers[j] then
				local len = utf.len(tostring(col))
				local h_name = parse_pipe_table_header(headers[j])
				if len > maxes[h_name] then
					maxes[h_name] = len
				end
			end
		end
	end
	return maxes
end

local pipe_table = function(headers, tbl)
	local lines = {}
	local maxes = calc_table_maxes(headers, tbl)
	local h_line = "|"
	local s_line = "|"
	for i, header in ipairs(headers) do
		local h_name, h_align = parse_pipe_table_header(header)
		-- We want headers themselves to be centrally aligned
		h_line = h_line .. " " .. txt.align(h_name, maxes[h_name], "center") .. " |"
		if h_align == "center" then
			s_line = s_line .. ":" .. string.rep("-", maxes[h_name]) .. ":|"
		elseif h_align == "right" then
			s_line = s_line .. string.rep("-", maxes[h_name] + 1) .. ":|"
		else
			s_line = s_line .. ":" .. string.rep("-", maxes[h_name] + 1) .. "|"
		end
	end
	lines[1] = h_line
	lines[2] = s_line
	for i, row in ipairs(tbl) do
		local line = "|"
		for j, col in ipairs(row) do
			local h_name, h_align = parse_pipe_table_header(headers[j])
			line = line .. " " .. txt.align(col, maxes[h_name], h_align) .. " |"
		end
		lines[i + 2] = line
	end
	return lines
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
	include_keys = include_keys,
	exclude_keys = exclude_keys,
	sort_by_str_len = sort_by_str_len,
	get_value_by_ref = get_value_by_ref,
}
return tbl
