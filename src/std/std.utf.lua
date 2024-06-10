-- SPDX-FileCopyrightText: © 2023 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: GPL-3.0-or-later
local bit = require("bit")
local byte = string.byte

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
				elseif byte(first) == 0xF4 and (byte(char) < 0x90 or byte(char) > 0x8F) then
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
		local count = 0
		local esc_count = 0
		local str = str or ""
		if str:match(utf.patterns.sgr_csi_pattern) then
			str, esc_count = str:gsub(utf.patterns.sgr_csi_pattern, "")
		end
		for char in str:gmatch(utf.patterns.glob) do
			count = count + 1
		end
		return count, esc_count
	end,
	sub = function(str, i, j)
		if not str or not i then
			return nil, "no string or index"
		end
		local l = utf.len(str)
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
		for char in str:gmatch(utf.patterns.glob) do
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
}

return utf
