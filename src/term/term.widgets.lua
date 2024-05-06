-- SPDX-FileCopyrightText: © 2023 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: GPL-3.0-or-later
local std = require("std")
local term = require("term")
local tinp = require("term.legacy_input")
local input = require("shell.input")
local tss_gen = require("term.tss")

local default_borders = {
	align = "none",
	top_line = { before = "╭", content = "─", after = "╮", fill = true },
	bottom_line = { before = "╰", content = "─", after = "╯", fill = true },
	subtitle_line = { before = "⎜", content = "┈", after = "⎜", fill = true },
	v = { content = "⎜", w = 1 },
}

local default_switcher_tss = {
	align = "center",
	fg = 253,
	title = { s = "bold" },
	option = { selected = { s = "inverted" } },
	border = default_borders,
}
--[[ 
    Switcher provides functionality similar to dmenu/rofi.
    Switcher needs terminal to be in raw mode to work correctly,
    so call `term.set_raw_mode()` before calling switcher,
    and `term.set_sane_mode()` after it returns.   
    
     Expected `content` format:
        content = {
            title = "Choose a region",
            options = {
                "us-east-1",
                "us-west-2",
                "ap-northeast-1",
            }
        }
]]
local switcher = function(content, tss, l, c)
	local tss = tss_gen.merge(default_switcher_tss, tss)
	term.clear()
	local content = content or {}

	local title = content.title or ""
	local max = std.utf.len(title)
	local max = std.longest(content.options)
	if std.utf.len(title) > max then
		max = std.utf.len(title)
	end
	local w = max + 4 + 2 -- indents plus borders
	local h = #content.options + 2
	if content.title then
		h = h + 3
	end

	local w_y, w_x = term.window_size()
	local x = math.floor((w_x - w) / 2)
	local y = math.floor((w_y - h) / 2)
	if l then
		y = l
	end
	if c then
		x = c
	end

	term.go(y, x)
	tss.__style.border.w = w - 2
	tss.__style.w = w - 2

	term.write(tss:apply("border.top_line"))
	local offset = 1
	if title ~= "" then
		term.go(y + 1, x)
		term.write(tss:apply("border.v") .. tss:apply("title", title) .. tss:apply("border.v"))
		term.go(y + 2, x)
		term.write(tss:apply("border.subtitle_line"))
		offset = 2
	end

	local render_option = function(idx, el)
		local option = content.options[idx]
		term.go(y + offset + idx, x + 1)
		term.write(tss:apply(el, option))
	end

	content.selected = content.selected or 1

	for i, option in ipairs(content.options) do
		term.go(y + offset + i, x)
		term.write(tss:apply("border.v"))
		if i == content.selected then
			render_option(i, "option.selected")
		else
			render_option(i, "option")
		end
		term.go(y + offset + i, x + w - 1)
		term.write(tss:apply("border.v"))
	end
	term.go(y + h - 2, x)
	term.write(tss:apply("border.bottom_line"))

	local idx = content.selected
	local buf = ""

	while true do
		local key = tinp.get()
		if key == "Esc" then
			if buf ~= "" then
				buf = ""
			else
				return ""
			end
		elseif key == "Enter" then
			return content.options[content.selected]
		elseif key == "Up" then
			if idx > 1 then
				render_option(idx, "option")
				idx = idx - 1
				content.selected = idx
				render_option(idx, "option.selected")
			end
		elseif key == "Down" then
			if idx < #content.options then
				render_option(idx, "option")
				idx = idx + 1
				content.selected = idx
				render_option(idx, "option.selected")
			end
		elseif key and key ~= "" then
			buf = buf .. key
			for i, option in ipairs(content.options) do
				if option:match(buf) then
					if idx ~= i then
						render_option(idx, "option")
						idx = i
						content.selected = idx
						render_option(idx, "option.selected")
						break
					end
				end
			end
		end
	end
end

local default_settings_tss = {
	clip = -1,
	align = "center",
	fg = 252,
	title = {
		s = "bold",
	},
	category = {
		selected = { s = "inverted" },
	},
	option = {
		selected = { s = "inverted" },
		value = {
			align = "left",
			s = "bold",
			indent = 2,
			boolean = { fg = 146 },
			number = { fg = 145 },
			string = { fg = 144 },
			table = { fg = 143, s = "italic" },
		},
	},
}
--[[ Auxiliary functions for settings widget ]]

local render_options = function(options, idx, tss, l, c)
	local l = l or 1
	local c = c or 1
	local option_keys = std.exclude_keys(std.sort_keys(options), "selected")
	local max_opt_len = std.longest(option_keys)
	tss.__style.w = max_opt_len + 4

	for i, opt in ipairs(option_keys) do
		term.go(l + i - 1, c)
		local val_type = type(options[opt])
		local option_val = options[opt]
		if val_type == "table" then
			option_val = options[opt].selected
		end
		if val_type == "string" then
			option_val = option_val:gsub("\n", "\\n")
		end
		if i ~= idx then
			if val_type == "table" and not option_val then
				if options[opt][1] then
					term.write(
						tss:apply("option", opt)
							.. tss:apply("option.value." .. val_type, table.concat(options[opt], ","))
					)
				else
					term.write(tss:apply("category", opt))
				end
			else
				term.write(tss:apply("option", opt) .. tss:apply("option.value." .. val_type, option_val))
			end
		else
			if val_type == "table" and not option_val then
				term.write(tss:apply("category.selected", opt))
			else
				term.write(tss:apply("option.selected", opt) .. tss:apply("option.value." .. val_type, option_val))
			end
		end
	end
end

local render_title = function(title, tss, l, c)
	local l = l or 1
	local c = c or 1
	term.go(l, c)
	term.clear_line()
	term.write(tss:apply("title", title))
end

local settings = function(config, title, tss, switcher_tss, l, c)
	local tss = tss_gen.merge(default_settings_tss, tss)
	local l = l or 1
	local c = c or 1
	local idx = 1
	local title = title or "settings"
	local target = ""
	term.clear()
	render_title(title, tss, l, c)
	render_options(config, idx, tss, l + 2, c)

	while true do
		local key = tinp.get()
		if key == "Esc" then
			return true
		end
		if key == "Up" then
			if idx > 1 then
				idx = idx - 1
				render_options(std.get_nested_value(config, target), idx, tss, l + 2, c)
			end
		end
		if key == "Down" then
			local options = std.exclude_keys(std.sort_keys(std.get_nested_value(config, target)), "selected")
			if idx < #options then
				idx = idx + 1
				render_options(std.get_nested_value(config, target), idx, tss, l + 2, c)
			end
		end
		if key == "Right" or key == "Enter" then
			local objs = std.get_nested_value(config, target)
			local keys = std.exclude_keys(std.sort_keys(objs), "selected")
			local chosen = keys[idx]

			if type(objs[chosen]) == "table" and not objs[chosen].options then
				if key == "Right" or not objs[chosen].selected then
					target = target .. "." .. keys[idx]
					term.clear()
					idx = 1
					local subcat = target:gsub("%.", " -> ")
					render_title(title .. subcat, tss, l, c)
					render_options(std.get_nested_value(config, target), idx, tss, l + 2, c)
				elseif objs[chosen].selected then
					local options = {}
					for k, v in pairs(objs[chosen]) do
						if k ~= "selected" then
							table.insert(options, k)
						end
					end
					options = std.alphanumsort(options)
					local choice = switcher({ title = "Choose an option", options = options }, switcher_tss, l + 2, c)
					if choice ~= "" then
						objs[chosen].selected = choice
					end
					term.clear()
					local subcat = target:gsub("%.", " -> ")
					render_title(title .. subcat, tss, l, c)
					render_options(std.get_nested_value(config, target), idx, tss, l + 2, c)
				end
			else
				if type(objs[chosen]) == "boolean" then
					objs[chosen] = not objs[chosen]
					render_options(std.get_nested_value(config, target), idx, tss, l + 2, c)
				elseif type(objs[chosen]) == "table" then
					local choice =
						switcher({ title = "Choose an option", options = objs[chosen].options }, switcher_tss, l + 2, c)
					if choice ~= "" then
						objs[chosen].selected = choice
					end
					term.clear()
					local subcat = target:gsub("%.", " -> ")
					render_title(title .. subcat, tss, l, c)
					render_options(std.get_nested_value(config, target), idx, tss, l + 2, c)
				elseif type(objs[chosen]) == "string" or type(objs[chosen]) == "number" then
					local buf = input.new("raw")
					local m = std.longest(keys)
					local val_indent = tss.__style.option.value.indent or 0
					term.go(l + 1 + idx, c + m + 4 + val_indent)
					term.clear_line()
					term.show_cursor()
					while true do
						local event, combo = buf:event()
						if event == "execute" then
							local choice = buf:render()
							if choice ~= "" then
								if type(objs[chosen]) == "string" then
									objs[chosen] = choice:gsub("\\n", "\n")
								else
									if tonumber(choice) then
										objs[chosen] = tonumber(choice)
									end
								end
								break
							end
						end
					end
					term.hide_cursor()
					term.clear()
					local subcat = target:gsub("%.", " -> ")
					render_title(title .. subcat, tss, l, c)
					render_options(std.get_nested_value(config, target), idx, tss, l + 2, c)
				end
			end
		end
		if key == "Left" then
			if target ~= "" then
				target = target:gsub("%.?[^.]+$", "")
				term.clear()
				idx = 1
				local subcat = target:gsub("%.", " -> ")
				render_title(title .. subcat, tss, l, c)
				render_options(std.get_nested_value(config, target), idx, tss, l + 2, c)
			end
		end
	end
end

local _M = {
	switcher = switcher,
	settings = settings,
}

return _M
