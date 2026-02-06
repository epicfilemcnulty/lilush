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

     Runtime note:
     `ts` application is capability-gated. If TSS instance is created with
     `supports_ts = false`, `ts` properties are ignored in apply/apply_sized.
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
		or {
			fg = "reset",
			bg = "reset",
			s = {},
			align = "none",
			clip = 0,
			text_indent = 0,
			block_indent = 0,
			w = 0,
			ts = nil,
		}

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

	-- Resolve text sizing configuration only when terminal support is enabled.
	local ts = nil
	if self.__supports_ts ~= false then
		ts = resolve_ts(props.ts)
	end
	local scale = ts and ts.s or 1

	local text = tostring(content) or ""
	if obj.content then
		text = tostring(obj.content)
	end
	local text_indent = 0
	if type(props.text_indent) == "number" then
		text_indent = math.max(0, math.floor(props.text_indent))
	end
	if text_indent > 0 then
		text = string.rep(" ", text_indent) .. text
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
		-- Only clip based on window width if window width is known (> 0)
		-- When running outside a TTY, window_size() returns 0,0
		if self.__window.w > 0 then
			local available = math.floor((self.__window.w - position) / scale)
			if ulen > available and props.clip >= 0 then
				text = std.txt.limit(text, available, available)
			end
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

	-- Apply text sizing to plain text BEFORE adding ANSI codes.
	-- This ensures the OSC 66 sequence wraps only visible text, not ANSI codes.
	if ts and text ~= "" then
		text = term.text_size(text, ts)
	end

	-- Calculate final display dimensions after text sizing wrapping.
	-- Width/height are terminal cell dimensions (OSC 66 aware).
	local final_width = std.utf.cell_len(text)
	local final_height = std.utf.cell_height(text)

	-- Build the styled text (ANSI codes wrapping the possibly-scaled text)
	local styled_text
	if props.fg == props.bg and props.bg == "reset" and std.tbl.empty(props.s) then
		styled_text = term.style("reset") .. text
	else
		if std.tbl.empty(props.s) then
			props.s = { "reset" }
		end
		styled_text = term.style(unpack(props.s)) .. term.color(props.fg, props.bg) .. text .. term.style("reset")
	end

	return {
		text = styled_text,
		height = final_height,
		width = final_width,
	}
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

--[[
  Apply styling and text-sizing to content with inline style ranges.

  This function handles the case where content has inline formatting (bold, italic,
  links, etc.) that needs to be combined with text-sizing (scaled text). The key
  challenge is that text-sizing chunks text by display width, and we need to apply
  inline styles correctly within each chunk.

  Parameters:
    self: TSS object
    base_elements: base style elements (e.g., {"heading", "heading.h1"})
    content: styled content buffer {
      plain = "Hello world",   -- plain text without ANSI codes
      ranges = {               -- inline style ranges
        { start = 7, stop = 11, elements = {"strong"} },
        ...
      }
    }
    position: cursor position for width calculations (optional)

  Returns:
    result table with .text, .height, .width (same as apply())
]]
local apply_sized = function(self, base_elements, content, position)
	local position = position or 0
	local plain = content.plain or ""
	local ranges = content.ranges or {}

	-- Get base style properties
	local all = {}
	if type(base_elements) == "string" then
		all = { base_elements }
	elseif type(base_elements) == "table" then
		all = base_elements
	end

	local props, obj
	for _, el in ipairs(all) do
		props, obj = self:get(el, props)
	end

	-- Resolve text sizing configuration from base style only when terminal
	-- capability supports text sizing.
	local ts = nil
	if self.__supports_ts ~= false then
		ts = resolve_ts(props.ts)
	end
	local scale = ts and ts.s or 1

	-- Add decorators to plain text (adjusting ranges accordingly)
	local before_len = 0
	if obj.before then
		before_len = std.utf.len(obj.before)
		plain = obj.before .. plain
		-- Shift all ranges by before_len
		for _, r in ipairs(ranges) do
			r.start = r.start + before_len
			r.stop = r.stop + before_len
		end
	end
	if obj.after then
		plain = plain .. obj.after
	end

	-- Height follows terminal cell occupancy, not only ts.s.
	local final_height = 1

	-- Helper function to build ANSI style codes for given elements
	local function build_style_codes(elements)
		if not elements or #elements == 0 then
			return "", ""
		end
		-- Get combined props for these elements
		local inline_props = { fg = "reset", bg = "reset", s = {} }
		for _, el in ipairs(elements) do
			inline_props, _ = self:get(el, inline_props)
		end
		-- Build opening codes
		local open_codes = ""
		if not std.tbl.empty(inline_props.s) then
			open_codes = open_codes .. term.style(unpack(inline_props.s))
		end
		if inline_props.fg ~= "reset" or inline_props.bg ~= "reset" then
			open_codes = open_codes .. term.color(inline_props.fg, inline_props.bg)
		end
		-- Close is always reset (we'll re-apply base style after)
		return open_codes, term.style("reset")
	end

	-- Build base style codes
	local base_open = ""
	local base_close = term.style("reset")
	if props.fg ~= "reset" or props.bg ~= "reset" or not std.tbl.empty(props.s) then
		if std.tbl.empty(props.s) then
			props.s = { "reset" }
		end
		base_open = term.style(unpack(props.s)) .. term.color(props.fg, props.bg)
	else
		base_open = term.style("reset")
	end

	-- Sort ranges by start position
	table.sort(ranges, function(a, b)
		return a.start < b.start
	end)

	-- Helper to get elements active at a specific position
	local function get_elements_at(pos)
		local elements = {}
		for _, r in ipairs(ranges) do
			if pos >= r.start and pos <= r.stop then
				for _, el in ipairs(r.elements) do
					table.insert(elements, el)
				end
			end
		end
		return elements
	end

	-- Find all style transition positions (where styles change)
	local function get_style_boundaries()
		local boundaries = { 1 } -- Always start at position 1
		local plain_len = std.utf.len(plain)

		if plain_len == 0 then
			return boundaries
		end

		local current_elements = get_elements_at(1)
		local current_key = table.concat(current_elements, ",")

		for pos = 2, plain_len do
			local new_elements = get_elements_at(pos)
			local new_key = table.concat(new_elements, ",")
			if new_key ~= current_key then
				table.insert(boundaries, pos)
				current_elements = new_elements
				current_key = new_key
			end
		end

		return boundaries
	end

	-- Helper to wrap plain text in OSC 66 sequence
	local function wrap_osc66(text, meta)
		if meta then
			return "\027]66;" .. meta .. ";" .. text .. "\027\\"
		else
			return text
		end
	end

	-- Build metadata string for a segment with specific width
	local function build_meta_str(segment_width)
		if not ts then
			return nil
		end

		local metadata = {}
		if ts.s and ts.s >= 1 and ts.s <= 7 then
			table.insert(metadata, "s=" .. math.floor(ts.s))
		end
		if ts.n and ts.d and ts.n >= 0 and ts.n <= 15 and ts.d >= 0 and ts.d <= 15 and ts.d > ts.n then
			table.insert(metadata, "n=" .. math.floor(ts.n))
			table.insert(metadata, "d=" .. math.floor(ts.d))
		end
		if ts.v and ts.v >= 0 and ts.v <= 2 then
			table.insert(metadata, "v=" .. math.floor(ts.v))
		end
		if ts.h and ts.h >= 0 and ts.h <= 2 then
			table.insert(metadata, "h=" .. math.floor(ts.h))
		end
		if segment_width and segment_width >= 0 and segment_width <= 7 then
			table.insert(metadata, "w=" .. segment_width)
		end

		if #metadata == 0 then
			return nil
		end
		return table.concat(metadata, ":")
	end

	-- Calculate cell width for a segment based on its display width and scaling params
	local function calc_segment_cell_width(display_width)
		if not ts or not ts.n or not ts.d or ts.d <= ts.n or not ts.w then
			return nil -- No fractional scaling with w, no need to calculate
		end
		-- With fractional scaling: n/d is the scale factor
		-- w cells can hold (w * d / n) display columns
		-- So for display_width columns, we need ceil(display_width * n / d) cells
		local cells = math.ceil(display_width * ts.n / ts.d)
		if cells > 7 then
			cells = 7 -- Max allowed by protocol
		end
		return cells
	end

	-- Check if fractional chunking is needed
	local needs_chunking = ts and ts.n and ts.d and ts.w and ts.w > 0 and ts.n > 0 and ts.d > ts.n

	local plain_len = std.utf.len(plain)
	local final_text

	if needs_chunking then
		-- Fractional scaling with w parameter - need to chunk text
		-- Strategy: split by both width boundaries AND style boundaries
		-- Each resulting segment gets its own OSC 66 with appropriate w value

		local style_boundaries = get_style_boundaries()
		local target_width = math.floor(ts.w * ts.d / ts.n) -- display columns per chunk

		-- Build unified segments that respect both chunk width and style boundaries
		local segments = {}
		local seg_start = 1
		local seg_width = 0
		local style_idx = 1

		-- Move style_idx to point to the next boundary after seg_start
		while style_idx <= #style_boundaries and style_boundaries[style_idx] <= seg_start do
			style_idx = style_idx + 1
		end

		local i = 1
		while i <= plain_len do
			local char = std.utf.sub(plain, i, i)
			local char_width = std.utf.display_len(char)

			-- Check if we hit a style boundary
			local hit_style_boundary = (style_idx <= #style_boundaries and i == style_boundaries[style_idx])

			-- Check if adding this char would exceed target width
			local would_exceed = (seg_width + char_width > target_width) and seg_width > 0

			if hit_style_boundary or would_exceed then
				-- Close current segment (if it has content)
				if i > seg_start then
					local seg_text = std.utf.sub(plain, seg_start, i - 1)
					local seg_display_width = std.utf.display_len(seg_text)
					local seg_cell_width = calc_segment_cell_width(seg_display_width)
					table.insert(segments, {
						start = seg_start,
						stop = i - 1,
						text = seg_text,
						cell_width = seg_cell_width,
						elements = get_elements_at(seg_start),
					})
				end
				seg_start = i
				seg_width = 0

				-- Advance style index if we hit a style boundary
				if hit_style_boundary then
					style_idx = style_idx + 1
				end
			end

			seg_width = seg_width + char_width

			-- If we've reached target width exactly, close segment
			if seg_width >= target_width then
				local seg_text = std.utf.sub(plain, seg_start, i)
				local seg_display_width = std.utf.display_len(seg_text)
				local seg_cell_width = calc_segment_cell_width(seg_display_width)
				table.insert(segments, {
					start = seg_start,
					stop = i,
					text = seg_text,
					cell_width = seg_cell_width,
					elements = get_elements_at(seg_start),
				})
				seg_start = i + 1
				seg_width = 0

				-- Advance style index past this position
				while style_idx <= #style_boundaries and style_boundaries[style_idx] <= seg_start do
					style_idx = style_idx + 1
				end
			end

			i = i + 1
		end

		-- Handle remaining text
		if seg_start <= plain_len then
			local seg_text = std.utf.sub(plain, seg_start, plain_len)
			local seg_display_width = std.utf.display_len(seg_text)
			local seg_cell_width = calc_segment_cell_width(seg_display_width)
			table.insert(segments, {
				start = seg_start,
				stop = plain_len,
				text = seg_text,
				cell_width = seg_cell_width,
				elements = get_elements_at(seg_start),
			})
		end

		-- Render all segments
		local result = {}
		for _, seg in ipairs(segments) do
			local style_open
			if seg.elements and #seg.elements > 0 then
				local inline_open, _ = build_style_codes(seg.elements)
				style_open = base_open .. inline_open
			else
				style_open = base_open
			end

			local meta = build_meta_str(seg.cell_width)
			table.insert(result, style_open .. wrap_osc66(seg.text, meta) .. base_close)
		end
		final_text = table.concat(result)
	elseif ts then
		-- Text sizing without fractional chunking (e.g., just s=2 or s=3)
		-- Split by style boundaries only, use same meta for all

		local style_boundaries = get_style_boundaries()
		local meta = build_meta_str(ts.w) -- Use original w if specified

		local result = {}
		for idx = 1, #style_boundaries do
			local seg_start = style_boundaries[idx]
			local seg_stop = (style_boundaries[idx + 1] or (plain_len + 1)) - 1

			if seg_stop >= seg_start then
				local seg_text = std.utf.sub(plain, seg_start, seg_stop)
				local elements = get_elements_at(seg_start)

				local style_open
				if elements and #elements > 0 then
					local inline_open, _ = build_style_codes(elements)
					style_open = base_open .. inline_open
				else
					style_open = base_open
				end

				table.insert(result, style_open .. wrap_osc66(seg_text, meta) .. base_close)
			end
		end
		final_text = table.concat(result)
	else
		-- No text sizing - just apply styles with ANSI codes only
		local style_boundaries = get_style_boundaries()

		local result = {}
		for idx = 1, #style_boundaries do
			local seg_start = style_boundaries[idx]
			local seg_stop = (style_boundaries[idx + 1] or (plain_len + 1)) - 1

			if seg_stop >= seg_start then
				local seg_text = std.utf.sub(plain, seg_start, seg_stop)
				local elements = get_elements_at(seg_start)

				local style_open
				if elements and #elements > 0 then
					local inline_open, _ = build_style_codes(elements)
					style_open = base_open .. inline_open
				else
					style_open = base_open
				end

				table.insert(result, style_open .. seg_text .. base_close)
			end
		end
		final_text = table.concat(result)
	end

	local final_width = std.utf.cell_len(final_text)
	final_height = std.utf.cell_height(final_text)

	return {
		text = final_text,
		height = final_height,
		width = final_width,
	}
end

local new

local scope = function(self, overrides)
	local scoped_rss = std.tbl.copy(self.__style or {})
	if type(overrides) == "table" then
		scoped_rss = std.tbl.merge(scoped_rss, overrides)
	end

	local child = new(scoped_rss, { supports_ts = self.__supports_ts })
	child.__window.w = self.__window.w
	child.__window.h = self.__window.h
	return child
end

new = function(rss, opts)
	opts = opts or {}
	local win_l, win_c = term.window_size()
	return {
		__window = { h = win_l, w = win_c },
		__style = rss or {},
		-- TSS-level protocol gate: when false, ts properties are ignored.
		__supports_ts = opts.supports_ts ~= false,
		calc_el_width = calc_el_width,
		get = get,
		apply = apply,
		apply_sized = apply_sized,
		scope = scope,
		set_property = set_property,
		get_property = get_property,
	}
end

local merge = function(rss_1, rss_2, opts)
	local merged = std.tbl.copy(rss_1)
	merged = std.tbl.merge(merged, rss_2)
	return new(merged, opts)
end

return { new = new, merge = merge }
