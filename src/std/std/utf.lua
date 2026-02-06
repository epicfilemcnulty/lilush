-- SPDX-FileCopyrightText: © 2023 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: GPL-3.0-or-later
local bit = require("bit")
local byte = string.byte
local core = require("std.core")
local ts_width_mode = "combined"

local is_c0_control = function(b)
	return (b and b <= 0x1F) or b == 0x7F
end

local consume_csi = function(str, i, len)
	local j = i + 2
	while j <= len do
		local b = byte(str, j)
		if b and b >= 0x40 and b <= 0x7E then
			return j + 1
		end
		j = j + 1
	end
	return len + 1
end

local consume_st_terminated = function(str, i, len)
	local j = i + 2
	while j <= len do
		local b = byte(str, j)
		local next_b = byte(str, j + 1)
		if b == 0x1B and next_b == 0x5C then
			return j + 2
		end
		j = j + 1
	end
	return len + 1
end

local find_osc_terminator = function(str, i, len)
	local j = i
	while j <= len do
		local b = byte(str, j)
		local next_b = byte(str, j + 1)
		if b == 0x07 then
			return j, 1
		end
		if b == 0x1B and next_b == 0x5C then
			return j, 2
		end
		j = j + 1
	end
	return len + 1, 0
end

local parse_meta_uint_param = function(meta, key, min, max)
	for token in meta:gmatch("([^:]+)") do
		local k, v = token:match("^([a-z])=(%d+)$")
		if k == key and v then
			local n = tonumber(v)
			if n and n >= min and n <= max then
				return n
			end
		end
	end
	return nil
end

local cell_len_lua
local cell_height_lua
cell_len_lua = function(str)
	local str = tostring(str) or ""
	local i = 1
	local len = #str
	local width = 0
	local seg = {}
	local seg_count = 0

	local flush_segment = function()
		if seg_count > 0 then
			width = width + core.display_len(table.concat(seg, "", 1, seg_count))
			seg = {}
			seg_count = 0
		end
	end

	while i <= len do
		local b = byte(str, i)
		local next_b = byte(str, i + 1)

		if b == 0x1B then
			flush_segment()
			if next_b == 0x5B then
				i = consume_csi(str, i, len)
			elseif next_b == 0x5D then
				local term_pos, term_len = find_osc_terminator(str, i + 2, len)
				local end_pos = term_pos - 1
				if end_pos >= i + 2 then
					local content = str:sub(i + 2, end_pos)
					if content:sub(1, 3) == "66;" then
						local second_sep = content:find(";", 4, true)
						if second_sep then
							local meta = content:sub(4, second_sep - 1)
							local payload = content:sub(second_sep + 1)
							local payload_cells = cell_len_lua(payload)
							local s = parse_meta_uint_param(meta, "s", 1, 7)
							local w = parse_meta_uint_param(meta, "w", 0, 7)
							local n = parse_meta_uint_param(meta, "n", 0, 15)
							local d = parse_meta_uint_param(meta, "d", 0, 15)
							if w and w > 0 then
								local seg_cells = w
								if ts_width_mode == "combined" and s then
									seg_cells = seg_cells * s
								end
								-- Fractional + explicit width can still overflow in some
								-- terminals depending on glyph metrics. Use a conservative
								-- lower bound.
								if ts_width_mode == "combined" and s and n and d and d > n then
									seg_cells = math.max(seg_cells, payload_cells * s)
								end
								width = width + seg_cells
							elseif s then
								width = width + (payload_cells * s)
							else
								width = width + payload_cells
							end
						end
					end
				end
				if term_len == 0 then
					i = len + 1
				else
					i = term_pos + term_len
				end
			elseif next_b == 0x50 or next_b == 0x58 or next_b == 0x5E or next_b == 0x5F then
				i = consume_st_terminated(str, i, len)
			elseif next_b then
				i = i + 2
			else
				i = i + 1
			end
		elseif is_c0_control(b) then
			flush_segment()
			i = i + 1
		else
			seg_count = seg_count + 1
			seg[seg_count] = str:sub(i, i)
			i = i + 1
		end
	end

	flush_segment()
	return width
end

cell_height_lua = function(str)
	local str = tostring(str) or ""
	local i = 1
	local len = #str
	local height = 1

	while i <= len do
		local b = byte(str, i)
		local next_b = byte(str, i + 1)

		if b == 0x1B then
			if next_b == 0x5B then
				i = consume_csi(str, i, len)
			elseif next_b == 0x5D then
				local term_pos, term_len = find_osc_terminator(str, i + 2, len)
				local end_pos = term_pos - 1
				if end_pos >= i + 2 then
					local content = str:sub(i + 2, end_pos)
					if content:sub(1, 3) == "66;" then
						local second_sep = content:find(";", 4, true)
						if second_sep then
							local meta = content:sub(4, second_sep - 1)
							local payload = content:sub(second_sep + 1)
							local payload_height = cell_height_lua(payload)
							local s = parse_meta_uint_param(meta, "s", 1, 7)
							local seg_height = s and (payload_height * s) or payload_height
							if seg_height > height then
								height = seg_height
							end
						end
					end
				end
				if term_len == 0 then
					i = len + 1
				else
					i = term_pos + term_len
				end
			elseif next_b == 0x50 or next_b == 0x58 or next_b == 0x5E or next_b == 0x5F then
				i = consume_st_terminated(str, i, len)
			elseif next_b then
				i = i + 2
			else
				i = i + 1
			end
		elseif is_c0_control(b) then
			i = i + 1
		else
			-- Consume printable byte run until next control/escape.
			-- Any printable run contributes a baseline height of 1.
			while i <= len do
				local cur = byte(str, i)
				if cur == 0x1B or is_c0_control(cur) then
					break
				end
				i = i + 1
			end
		end
	end

	return math.max(height, 1)
end

local extract_printable = function(str)
	local out = {}
	local out_count = 0
	local str = tostring(str) or ""
	local i = 1
	local len = #str

	while i <= len do
		local b = byte(str, i)
		local next_b = byte(str, i + 1)

		-- Handle terminal escape sequences (ESC ...)
		if b == 0x1B then
			if next_b == 0x5B then
				-- CSI: ESC [ ... final-byte
				i = consume_csi(str, i, len)
			elseif next_b == 0x5D then
				-- OSC: ESC ] ... BEL or ST
				local term_pos, term_len = find_osc_terminator(str, i + 2, len)
				local end_pos = term_pos - 1
				if end_pos >= i + 2 then
					local content = str:sub(i + 2, end_pos)
					-- Kitty text sizing OSC 66: ESC ] 66 ; params ; text ST
					-- Keep printable text payload; drop protocol wrappers.
					if content:sub(1, 3) == "66;" then
						local second_sep = content:find(";", 4, true)
						if second_sep then
							out_count = out_count + 1
							out[out_count] = content:sub(second_sep + 1)
						end
					end
				end
				if term_len == 0 then
					i = len + 1
				else
					i = term_pos + term_len
				end
			elseif next_b == 0x50 or next_b == 0x58 or next_b == 0x5E or next_b == 0x5F then
				-- DCS/SOS/PM/APC: ESC P/X/^/_ ... ST
				i = consume_st_terminated(str, i, len)
			elseif next_b then
				-- Other single ESC sequences
				i = i + 2
			else
				i = i + 1
			end
		elseif is_c0_control(b) then
			-- C0 controls and DEL are non-printing for std.utf semantics
			i = i + 1
		else
			out_count = out_count + 1
			out[out_count] = str:sub(i, i)
			i = i + 1
		end
	end

	return table.concat(out, "")
end

local count_utf_chars = function(str, pattern)
	local count = 0
	for _ in str:gmatch(pattern) do
		count = count + 1
	end
	return count
end

local utf
utf = {
	-- U+FFFD, generally used to replace invalid UTF-8 sequences
	replacement_symbol = string.char(0xEF, 0xBF, 0xBD),
	patterns = {
		glob = "[\1-\x7F\xC2-\xF4][\x80-\xBF]*",
		multibyte = "[\xC2-\xF4][\x80-\xBF]+",
		onebyte = "[\1-\x7F]",
		-- Although not UTF-8 related, but we alse want to have the ability
		-- to detect and count the number or of ANSI ESC sequences in the string
		sgr_csi_pattern = "\27%[[0-9;]-m",
	},
	-- Check if a byte is a valid starting byte for a multi-byte UTF-8 sequence
	valid_b1 = function(b1)
		if not b1 then
			return false
		end
		if byte(b1) < 0xC2 or byte(b1) > 0xF4 then
			return false
		end
		return true
	end,
	byte_count = function(b1)
		local first = string.byte(b1)
		return first >= 0xF0 and 3 or first >= 0xE0 and 2 or first >= 0xC0 and 1
	end,
	valid_seq = function(seq)
		if not seq or #seq == 0 then
			return false
		end
		local i = 0
		local first = ""
		for char in seq:gmatch(".") do
			i = i + 1
			if i == 1 then
				if not utf.valid_b1(char) then
					return false
				end
				first = char
			end
			if i == 2 then
				if byte(first) == 0xE0 and (byte(char) < 0xA0 or byte(char) > 0xBF) then
					return false
				elseif byte(first) == 0xED and (byte(char) < 0x80 or byte(char) > 0x9F) then
					return false
				elseif byte(first) == 0xF0 and (byte(char) < 0x90 or byte(char) > 0xBF) then
					return false
				elseif byte(first) == 0xF4 and (byte(char) < 0x80 or byte(char) > 0x8F) then
					return false
				end
			end
			if i >= 2 and (byte(char) < 0x80 or byte(char) > 0xBF) then
				return false
			end
		end
		return true
	end,
	len = function(str)
		local printable = extract_printable(str)
		return count_utf_chars(printable, utf.patterns.glob)
	end,
	display_len = function(str)
		return core.display_len(str)
	end,
	cell_len = function(str)
		if ts_width_mode == "combined" and core.cell_len then
			return core.cell_len(str)
		end
		return cell_len_lua(str)
	end,
	cell_height = function(str)
		if core.cell_height then
			return core.cell_height(str)
		end
		return cell_height_lua(str)
	end,
	set_ts_width_mode = function(mode)
		if mode == "combined" or mode == "w_only" then
			ts_width_mode = mode
			return true
		end
		return nil, "invalid ts width mode: " .. tostring(mode)
	end,
	get_ts_width_mode = function()
		return ts_width_mode
	end,
	find_all_spaces = function(str)
		local spaces = {}
		local printable = extract_printable(str)
		local i = 1
		for c in printable:gmatch(utf.patterns.glob) do
			if c:match("%s") then
				table.insert(spaces, i)
			end
			i = i + 1
		end
		return spaces
	end,
	sub = function(str, i, j)
		if not str or not i then
			return nil, "no string or index"
		end
		local printable = extract_printable(str)
		local l = count_utf_chars(printable, utf.patterns.glob)
		local j = j or l
		-- Check and translate negative indices first
		if j < 0 then
			j = l + 1 + j
		end
		if i < 0 then
			i = l + 1 + i
		end
		-- Now do sanity checks
		if i < 1 then
			i = 1
		end
		if j > l then
			j = l
		end
		if i > j then
			return ""
		end
		local idx = 0
		local result = ""
		for char in printable:gmatch(utf.patterns.glob) do
			idx = idx + 1
			if idx >= i and idx <= j then
				result = result .. char
			end
		end
		return result
	end,
	-- The `char()` func below is taken verbatim from [Lua-5.1-UTF-8](https://github.com/meepen/Lua-5.1-UTF-8),
	-- credits to [willox](https://github.com/willox), I suppose, judging by the commit history...
	--
	-- Takes zero or more integers and returns a string containing the UTF-8 representation of each
	char = function(...)
		local buf = {}
		for k, v in ipairs({ ... }) do
			if v < 0 or v > 0x10FFFF then
				return nil, "bad argument #" .. k .. " to char (out of range)"
			end

			local b1, b2, b3, b4 = nil, nil, nil, nil
			if v < 0x80 then -- Single-byte sequence
				table.insert(buf, string.char(v))
			elseif v < 0x800 then -- Two-byte sequence
				b1 = bit.bor(0xC0, bit.band(bit.rshift(v, 6), 0x1F))
				b2 = bit.bor(0x80, bit.band(v, 0x3F))
				table.insert(buf, string.char(b1, b2))
			elseif v < 0x10000 then -- Three-byte sequence
				b1 = bit.bor(0xE0, bit.band(bit.rshift(v, 12), 0x0F))
				b2 = bit.bor(0x80, bit.band(bit.rshift(v, 6), 0x3F))
				b3 = bit.bor(0x80, bit.band(v, 0x3F))
				table.insert(buf, string.char(b1, b2, b3))
			else -- Four-byte sequence
				b1 = bit.bor(0xF0, bit.band(bit.rshift(v, 18), 0x07))
				b2 = bit.bor(0x80, bit.band(bit.rshift(v, 12), 0x3F))
				b3 = bit.bor(0x80, bit.band(bit.rshift(v, 6), 0x3F))
				b4 = bit.bor(0x80, bit.band(v, 0x3F))
				table.insert(buf, string.char(b1, b2, b3, b4))
			end
		end
		return table.concat(buf, "")
	end,

	-- The `valid` function below is taken from https://github.com/kikito/utf8_validator.lua
	valid = function(str)
		local find = string.find
		local i, len = 1, #str
		while i <= len do
			if i == find(str, "[%z\1-\127]", i) then
				i = i + 1
			elseif i == find(str, "[\194-\223][\128-\191]", i) then
				i = i + 2
			elseif
				i == find(str, "\224[\160-\191][\128-\191]", i)
				or i == find(str, "[\225-\236][\128-\191][\128-\191]", i)
				or i == find(str, "\237[\128-\159][\128-\191]", i)
				or i == find(str, "[\238-\239][\128-\191][\128-\191]", i)
			then
				i = i + 3
			elseif
				i == find(str, "\240[\144-\191][\128-\191][\128-\191]", i)
				or i == find(str, "[\241-\243][\128-\191][\128-\191][\128-\191]", i)
				or i == find(str, "\244[\128-\143][\128-\191][\128-\191]", i)
			then
				i = i + 4
			else
				return false, i
			end
		end
		return true
	end,
}

return utf
