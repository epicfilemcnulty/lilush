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

local calc_el_width = function(self, w, max)
	if not max then
		max = self.__window.w
	end
	local w = w or 0
	if w <= 0 then
		return 0
	end
	if w < 1 then
		return math.max(1, math.floor(max * w))
	end
	return math.min(w, max)
end

local get = function(self, el, base_props)
	local props = base_props or { fg = "reset", bg = "reset", s = {}, align = "none", clip = 0, indent = 0, w = 0 }

	local add_style = function(tbl, s)
		for opt in s:gmatch("([^,]+)") do
			if opt == "reset" then
				tbl = {}
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
	local text = tostring(content) or ""
	if obj.content then
		text = tostring(obj.content)
	end
	if props.indent > 0 then
		text = string.rep(" ", props.indent) .. text
	end
	local ulen = std.utf.len(text)
	if props.w ~= 0 then
		if obj.fill then
			text = string.rep(text, math.ceil(props.w / ulen))
			text = std.utf.sub(text, 1, props.w)
			ulen = std.utf.len(text)
		end
		if props.clip == 0 then
			props.clip = props.w
		end
		if ulen <= props.w and ulen <= self.__window.w - position then
			if props.align == "center" then
				local indent = math.floor((props.w - ulen) / 2)
				local postfix = props.w - ulen - indent
				text = string.rep(" ", indent) .. text .. string.rep(" ", postfix)
			elseif props.align == "left" then
				local postfix = props.w - ulen
				text = text .. string.rep(" ", postfix)
			elseif props.align == "right" then
				local indent = props.w - ulen
				text = string.rep(" ", indent) .. text
			end
		elseif props.clip > 0 then
			text = std.txt.limit(text, props.w, props.clip)
		end
	else
		if ulen > self.__window.w - position and props.clip >= 0 then
			text = std.txt.limit(text, self.__window.w - position, self.__window.w - position)
		end
	end
	if obj.before then
		text = obj.before .. text
	end
	if obj.after then
		text = text .. obj.after
	end
	if props.fg == props.bg and props.bg == "reset" and std.tbl.empty(props.s) then
		return term.style("reset") .. text
	end
	if std.tbl.empty(props.s) then
		props.s = { "reset" }
	end
	return term.style(unpack(props.s)) .. term.color(props.fg, props.bg) .. text .. term.style("reset")
end

local new = function(rss)
	local win_l, win_c = term.window_size()
	return {
		__window = { h = win_l, w = win_c },
		__style = rss or {},
		calc_el_width = calc_el_width,
		get = get,
		apply = apply,
	}
end

local merge = function(rss_1, rss_2)
	local merged = std.tbl.copy(rss_1)
	merged = std.tbl.merge(merged, rss_2)
	return new(merged)
end

return { new = new, merge = merge }
