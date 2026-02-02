-- SPDX-FileCopyrightText: © 2024 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: GPL-3.0-or-later
local std = require("std")
local term = require("term")

--[[
     TSS stands for Terminal Style Sheet. The idea is obviously inspired by CSS,
     but adapted to the harsh realms of terminal.

     In the code `tss` refers to the tss object -- table with methods + the style sheet itself,
     whereas `rss` denotes "raw" style sheet, i.e. a plain lua table, defining a style.

     A `rss` table defines a style, but it's user code's task to interprete and apply
     this style.

]]

--[[
     Text Sizing Protocol Support

     The `ts` property enables Kitty's text sizing protocol for scaling text.
     It can be either a preset string or a table with parameters:

     Preset strings: "double", "triple", "superscript", "subscript", "half", "compact"

     Table format: { s = 2, w = 0, n = 0, d = 0, v = 0, h = 0 }
     - s: scale factor (1-7)
     - w: explicit width (0-7, 0 = auto)
     - n: fractional numerator (0-15)
     - d: fractional denominator (0-15, must be > n)
     - v: vertical alignment (0=top, 1=bottom, 2=center)
     - h: horizontal alignment (0=left, 1=right, 2=center)

     String aliases for alignments are also supported:
     - v: "top" | "bottom" | "center"
     - h: "left" | "right" | "center"
]]

local resolve_ts = function(ts)
	if not ts then
		return nil
	end

	-- If ts is a string, look it up in presets
	if type(ts) == "string" then
		local preset = term.ts_presets[ts]
		if not preset then
			return nil -- Unknown preset, ignore
		end
		return std.tbl.copy(preset)
	end

	-- If ts is a table, validate and normalize it
	if type(ts) == "table" then
		local normalized = {}

		-- Copy and validate numeric parameters
		if ts.s and type(ts.s) == "number" and ts.s >= 1 and ts.s <= 7 then
			normalized.s = math.floor(ts.s)
		end

		if ts.w and type(ts.w) == "number" and ts.w >= 0 and ts.w <= 7 then
			normalized.w = math.floor(ts.w)
		end

		-- Validate fractional scaling (d must be > n when both are set)
		if ts.n and ts.d and type(ts.n) == "number" and type(ts.d) == "number" then
			local n = math.floor(ts.n)
			local d = math.floor(ts.d)
			if n >= 0 and n <= 15 and d >= 0 and d <= 15 and d > n then
				normalized.n = n
				normalized.d = d
			end
		end

		-- Convert alignment strings to numbers or validate numeric values
		if ts.v then
			if ts.v == "top" then
				normalized.v = 0
			elseif ts.v == "bottom" then
				normalized.v = 1
			elseif ts.v == "center" then
				normalized.v = 2
			elseif type(ts.v) == "number" and ts.v >= 0 and ts.v <= 2 then
				normalized.v = math.floor(ts.v)
			end
		end

		if ts.h then
			if ts.h == "left" then
				normalized.h = 0
			elseif ts.h == "right" then
				normalized.h = 1
			elseif ts.h == "center" then
				normalized.h = 2
			elseif type(ts.h) == "number" and ts.h >= 0 and ts.h <= 2 then
				normalized.h = math.floor(ts.h)
			end
		end

		-- Return normalized table only if it has at least one valid parameter
		if next(normalized) then
			return normalized
		end
	end

	return nil
end

local calc_el_width = function(self, w, max, scale)
	if not max then
		max = self.__window.w
	end
	local w = w or 0
	local scale = scale or 1

	if w <= 0 then
		return 0
	end
	if w < 1 then
		if max == 0 then
			return 0
		end
		return math.max(1, math.floor(max * w)) * scale
	end
	return math.min(w, max) * scale
end

local get = function(self, el, base_props)
	local props = base_props
		or { fg = "reset", bg = "reset", s = {}, align = "none", clip = 0, indent = 0, w = 0, ts = nil }

	local add_style = function(tbl, s)
		for opt in s:gmatch("([^,]+)") do
			if opt == "reset" then
				for k, _ in pairs(tbl) do
					tbl[k] = nil
				end
			else
				local duplicate = false
				for _, v in ipairs(tbl) do
					if opt == v then
						duplicate = true
						break
					end
				end
				if not duplicate then
					table.insert(tbl, opt)
				end
			end
		end
	end
	-- When base_props were provided, we
	-- don't want to merge it with the base
	-- values
	if base_props == nil then
		for k, _ in pairs(props) do
			if self.__style[k] then
				if k == "w" then
					props.w = self:calc_el_width(self.__style.w, self.__window.w)
				elseif k == "s" then
					add_style(props.s, self.__style[k])
				else
					props[k] = self.__style[k]
				end
			end
		end
	end

	local obj = self.__style
	for e in el:gmatch("([^.]+)%.?") do
		if obj[e] then
			for k, _ in pairs(props) do
				if obj[e][k] then
					if k == "w" then
						local max = props.w
						if max == 0 then
							max = self.__window.w
						end
						props.w = self:calc_el_width(obj[e].w, max)
					elseif k == "s" then
						add_style(props.s, obj[e][k])
					else
						props[k] = obj[e][k]
					end
				end
			end
			-- Handle ts property explicitly (not in pairs() because it starts as nil)
			-- ts does NOT cascade - each level either sets it or clears it
			if obj[e].ts ~= nil then
				props.ts = obj[e].ts
			else
				-- Explicitly clear ts if current element doesn't have it (prevent cascade)
				props.ts = nil
			end
			obj = obj[e]
		end
	end
	return props, obj
end

local apply = function(self, elements, content, position)
	local position = position or 0
	local all = {}
	if type(elements) == "string" then
		all = { elements }
	elseif type(elements) == "table" then
		all = elements
	end
	local props, obj
	for _, el in ipairs(all) do
		props, obj = self:get(el, props)
	end

	-- Resolve text sizing configuration
	local ts = resolve_ts(props.ts)
	local scale = ts and ts.s or 1

	local text = tostring(content) or ""
	if obj.content then
		text = tostring(obj.content)
	end
	if props.indent > 0 then
		text = string.rep(" ", props.indent) .. text
	end
	local ulen = std.utf.display_len(text)

	-- Calculate effective width with scale multiplier
	local effective_w = props.w
	if effective_w ~= 0 and scale > 1 then
		-- The logical width for layout purposes, but final display will be scaled
		-- We don't multiply here - that happens in the protocol
		effective_w = props.w
	end

	if effective_w ~= 0 then
		if obj.fill then
			text = string.rep(text, math.ceil(effective_w / ulen))
			text = std.utf.sub(text, 1, effective_w)
			ulen = std.utf.display_len(text)
		end
		if props.clip == 0 then
			props.clip = effective_w
		end
		if ulen <= effective_w and ulen * scale <= self.__window.w - position then
			if props.align == "center" then
				local indent = math.floor((effective_w - ulen) / 2)
				local postfix = effective_w - ulen - indent
				text = string.rep(" ", indent) .. text .. string.rep(" ", postfix)
			elseif props.align == "left" then
				local postfix = effective_w - ulen
				text = text .. string.rep(" ", postfix)
			elseif props.align == "right" then
				local indent = effective_w - ulen
				text = string.rep(" ", indent) .. text
			end
		elseif props.clip > 0 then
			text = std.txt.limit(text, effective_w, props.clip)
		end
		-- Final check: ensure we don't overflow the available window width
		ulen = std.utf.display_len(text)
		local available = math.floor((self.__window.w - position) / scale)
		if ulen > available and available > 0 then
			text = std.txt.limit(text, available, available)
		end
	else
		local available = math.floor((self.__window.w - position) / scale)
		if ulen > available and props.clip >= 0 then
			text = std.txt.limit(text, available, available)
		end
	end

	-- Add decorators AFTER fill/width/alignment processing but BEFORE styling
	-- This ensures:
	-- 1. fill repeats only the content, not the decorators (e.g., "─" not "╭─╮")
	-- 2. decorators receive the same ANSI styling as the content
	-- 3. decorators are included in text sizing (both styled AND scaled)
	if obj.before then
		text = obj.before .. text
	end
	if obj.after then
		text = text .. obj.after
	end

	-- Build the styled text (ANSI codes + text, including decorators)
	local styled_text
	if props.fg == props.bg and props.bg == "reset" and std.tbl.empty(props.s) then
		styled_text = term.style("reset") .. text
	else
		if std.tbl.empty(props.s) then
			props.s = { "reset" }
		end
		styled_text = term.style(unpack(props.s)) .. term.color(props.fg, props.bg) .. text .. term.style("reset")
	end

	-- Apply text sizing escape sequence if ts is configured
	-- Decorators are included in the text sizing (both styled AND scaled)
	if ts and text ~= "" then
		styled_text = term.text_size(styled_text, ts)
	end

	return styled_text
end

local set_property = function(self, path, property, value)
	local obj = self.__style
	for e in path:gmatch("([^.]+)%.?") do
		if not obj[e] then
			obj[e] = {}
		end
		obj = obj[e]
	end
	obj[property] = value
end

local get_property = function(self, path, property)
	local obj = self.__style
	for e in path:gmatch("([^.]+)%.?") do
		if obj[e] then
			obj = obj[e]
		else
			return nil
		end
	end
	return obj[property]
end

local new = function(rss)
	local win_l, win_c = term.window_size()
	return {
		__window = { h = win_l, w = win_c },
		__style = rss or {},
		calc_el_width = calc_el_width,
		get = get,
		apply = apply,
		set_property = set_property,
		get_property = get_property,
	}
end

local merge = function(rss_1, rss_2)
	local merged = std.tbl.copy(rss_1)
	merged = std.tbl.merge(merged, rss_2)
	return new(merged)
end

return { new = new, merge = merge }
