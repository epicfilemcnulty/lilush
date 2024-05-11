-- SPDX-FileCopyrightText: © 2023 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: GPL-3.0-or-later
local std = require("std")
local term = require("term")
local tinp = require("term.legacy_input")
local input = require("shell.input")
local style = require("term.tss")
local new_input = require("term.input")

local default_widgets_rss = {
	align = "center",
	fg = 253,
	title = { s = bold },
	option = {
		selected = { s = "inverted" },
		value = {
			clip = -1,
			align = "left",
			s = "bold",
			indent = 2,
			boolean = { fg = 146 },
			number = { fg = 145 },
			string = { fg = 144 },
			table = { fg = 143, s = "italic" },
		},
	},
	file = {
		align = "left",
		indent = 2,
		selected = { s = "inverted" },
		directory = { s = "bold" },
	},
	category = {
		selected = { s = "inverted" },
	},
	borders = {
		align = "none",
		label = { w = 0.8, clip = 7 },
		top_line = { before = "╭", content = "─", after = "╮", fill = true },
		bottom_line = { before = "╰", content = "─", after = "╯", fill = true },
		subtitle_line = { before = "⎜", content = "┈", after = "⎜", fill = true },
		v = { content = "⎜", w = 1 },
	},
}

local draw_borders = function(title, rss, w, h, l, c, label)
	local tss = style.merge(default_widgets_rss, rss)
	local title = title or ""
	local height = h + 2
	tss.__style.w = w
	tss.__style.borders.w = w + 2

	term.go(l, c)
	term.write(tss:apply("borders.top_line", nil, c))
	if label then
		term.go(l, c + 1)
		term.write(tss:apply("borders.label", label, c + 1))
	end
	local offset = 1
	if title ~= "" then
		height = height + 2
		term.go(l + 1, c)
		term.write(
			tss:apply("borders.v", nil, c)
				.. tss:apply("title", title, c + 1)
				.. tss:apply("borders.v", nil, c + std.utf.len(title) + 1)
		)
		term.go(l + 2, c)
		term.write(tss:apply("borders.subtitle_line", nil, c))
		offset = 2
	end
	for i = 1, height - offset - 2 do
		term.go(l + offset + i, c)
		term.write(tss:apply("borders.v", nil, c))
		term.go(l + offset + i, c + w + 1)
		term.write(tss:apply("borders.v", nil, c + w))
	end
	term.go(l + height - 1, c)
	term.write(tss:apply("borders.bottom_line", nil, c))
end

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
local switcher = function(content, rss, l, c)
	local tss = style.merge(default_widgets_rss, rss)
	term.clear()
	local content = content or {}

	local title = content.title or ""
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
	tss.__style.borders.w = w - 2
	tss.__style.w = w - 2

	term.write(tss:apply("borders.top_line"))
	local offset = 1
	if title ~= "" then
		term.go(y + 1, x)
		term.write(tss:apply("borders.v") .. tss:apply("title", title) .. tss:apply("borders.v"))
		term.go(y + 2, x)
		term.write(tss:apply("borders.subtitle_line"))
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
		term.write(tss:apply("borders.v"))
		if i == content.selected then
			render_option(i, "option.selected")
		else
			render_option(i, "option")
		end
		term.go(y + offset + i, x + w - 1)
		term.write(tss:apply("borders.v"))
	end
	term.go(y + h - 2, x)
	term.write(tss:apply("borders.bottom_line"))

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

local settings = function(config, title, rss, l, c)
	local tss = style.merge(default_widgets_rss, rss)
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
					local choice = switcher({ title = "Choose an option", options = options }, rss, l + 2, c)
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
						switcher({ title = "Choose an option", options = objs[chosen].options }, rss, l + 2, c)
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

local file_chooser = function(title, start_dir, rss, patterns)
	local title = title or "Select a file/dir"
	local patterns = patterns or { mode = "[fdl]", select = "[fdl]" }
	local tss = style.merge(default_widgets_rss, rss)
	local start_dir = start_dir or std.cwd()
	local last_dir = os.getenv("LILUSH_FC_LASTDIR") or start_dir
	local cur_dir
	if last_dir:match("^" .. start_dir) then
		cur_dir = last_dir
	else
		cur_dir = start_dir
	end
	local w_y, w_x = term.window_size()
	if new_input.has_kkbp() then
		new_input.enable_kkbp()
	end

	local get_dir_files = function(dir)
		local files = std.list_files(dir, "^[^.]", patterns.mode)
		local file_names = std.sort_keys(files)
		local max_width = std.longest(file_names)
		return file_names, files, max_width
	end
	local choice
	repeat
		term.clear()
		std.chdir(cur_dir)
		local file_names, files, max_width = get_dir_files(".")
		if #title > max_width then
			max_width = #title
		end
		local w = max_width + 4
		tss.__style.w = w
		local h = #file_names
		local idx = 1
		local c = math.floor((w_x - w) / 2)
		local l = math.floor((w_y - h) / 2 / 2)
		draw_borders(title, rss, w, h, l, c, cur_dir)
		local render_files = function()
			for i, file in ipairs(file_names) do
				term.go(l + 2 + i, c + 1)
				local elements = {}
				if i == idx then
					elements = { "file.selected" }
				else
					elements = { "file" }
				end
				if files[file].mode == "d" then
					elements[2] = "file.directory"
				end
				term.write(tss:apply(elements, file, c + 1))
			end
		end
		render_files()
		local key
		repeat
			key = new_input.simple_get()
			if key then
				if key == "UP" and idx > 1 then
					idx = idx - 1
					render_files()
				end
				if key == "DOWN" and idx < #file_names then
					idx = idx + 1
					render_files()
				end
				if key == "RIGHT" and files[file_names[idx]].mode == "d" then
					cur_dir = std.cwd() .. "/" .. file_names[idx]
					key = "change_dir"
				end
				if key == "LEFT" then
					-- hacky way to restrict going upper than the start_dir
					if std.utf.len(cur_dir) > std.utf.len(start_dir) and std.chdir("..") then
						cur_dir = std.cwd()
						key = "change_dir"
					end
				end
				if key == "ENTER" and files[file_names[idx]].mode:match(patterns.select) then
					key = "chosen"
					choice = std.cwd() .. "/" .. file_names[idx]
					break
				end
				if key == "ESC" then
					break
				end
			end
		until key == "change_dir"
	until key == "chosen" or key == "ESC"
	new_input.disable_kkbp()
	std.setenv("LILUSH_FC_LASTDIR", std.cwd())
	return choice
end

local _M = {
	switcher = switcher,
	settings = settings,
	file_chooser = file_chooser,
	draw_borders = draw_borders,
}

return _M
