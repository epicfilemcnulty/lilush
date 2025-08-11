-- SPDX-FileCopyrightText: © 2023 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: GPL-3.0-or-later
local std = require("std")
local term = require("term")
local style = require("term.tss")

local default_rss = {
	align = "center",
	fg = 253,
	title = { s = "bold" },
	option = {
		selected = { s = "inverted" },
		marked = { content = "", s = "bold", w = 1 },
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
	form = {
		label = { indent = 1, align = "left", after = ": ", s = "bold" },
		input = { s = "italic", line = { content = "_", fill = true }, blank = { w = 1 } },
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

local draw_top_border = function(self)
	term.go(self.l, self.c)
	term.write(self.tss:apply("borders.top_line", nil, self.c))
	if self.label then
		term.go(self.l, self.c + 1)
		term.write(self.tss:apply("borders.label", self.label, self.c + 1))
	end
end

local draw_borders = function(self)
	local height = self.h + 2
	self.tss.__style.w = self.w
	self.tss.__style.borders.w = self.w + 2

	self:draw_top_border()
	local offset = 1
	if self.title ~= "" then
		height = height + 2
		term.go(self.l + 1, self.c)
		term.write(
			self.tss:apply("borders.v", nil, self.c)
				.. self.tss:apply("title", self.title, self.c + 1)
				.. self.tss:apply("borders.v", nil, self.c + std.utf.len(self.title) + 1)
		)
		term.go(self.l + 2, self.c)
		term.write(self.tss:apply("borders.subtitle_line", nil, self.c))
		offset = 2
	end
	for i = 1, height - offset - 2 do
		term.go(self.l + offset + i, self.c)
		term.write(self.tss:apply("borders.v", nil, self.c))
		term.go(self.l + offset + i, self.c + self.w + 1)
		term.write(self.tss:apply("borders.v", nil, self.c + self.w))
	end
	term.go(self.l + height - 1, self.c)
	term.write(self.tss:apply("borders.bottom_line", nil, self.c))
end

local init = function(self)
	self.state = term.alt_screen()
	term.clear()
	return self
end

local cleanup = function(self)
	if self.state then
		self.state:done()
	end
end

local render_chooser_option = function(self, idx)
	local option = self.content[idx]
	term.go(self.l + (self.title ~= "" and 3 or 1) + idx - 1, self.c + 1)

	if self.kind == "chooser_multi" then
		term.move("left", 1)
		if self.selected[option] then
			term.write(self.tss:apply("option.marked"))
		else
			term.write(self.tss:apply("borders.v", nil, self.c))
		end
	end
	if idx == self.idx then
		term.write(self.tss:apply("option.selected", option))
	else
		term.write(self.tss:apply("option", option))
	end
end

local goto_field = function(self, idx, to_input)
	local label = self.tss:apply("form.label", self.content[idx])
	local c = self.c + 1
	if to_input then
		c = c + std.utf.len(label)
	end
	term.go(self.l + (self.title ~= "" and 3 or 1) + idx - 1, c)
end

local render_form_field = function(self, idx)
	local label = self.content[idx]
	local display_label = self.tss:apply("form.label", label)
	self:goto_field(idx)
	term.write(display_label)
	term.write(self.tss:apply("form.input.line"))
	if self.results[label] then
		self:goto_field(idx, true)
		local value = self.results[label]
		if self.meta[label] and self.meta[label].secret then
			value = string.rep("*", std.utf.len(value))
		end
		term.write(self.tss:apply("form.input", value))
	end
end

local new_widget = function(opts)
	local opts = opts or {}
	local widget = {
		l = opts.l or 1,
		c = opts.c or 1,
		w = opts.w or 0,
		h = opts.h or 0,
		title = opts.title or "",
		tss = style.merge(default_rss, opts.rss),
		kind = opts.kind or "widget",
	}
	local win_y, win_x = term.window_size()
	if not opts.l or not opts.c then
		widget.l = opts.l or math.floor((win_y - widget.h) / 2) - math.floor(win_y * 0.05)
		widget.c = opts.c or math.floor((win_x - widget.w) / 2) - math.floor(win_x * 0.01)
	end
	widget.init = init
	widget.cleanup = cleanup
	widget.draw_borders = draw_borders
	widget.draw_top_border = draw_top_border
	widget.render_chooser_option = render_chooser_option
	widget.render_form_field = render_form_field
	widget.goto_field = goto_field
	return widget
end

local chooser = function(content, opts)
	local opts = opts or {}
	local content = content or {}
	if #content == 0 then
		return ""
	end
	local title = opts.title or ""
	local max = std.tbl.longest(content)
	if std.utf.len(title) > max then
		max = std.utf.len(title)
	end
	opts.w = max + 4 -- Add some space for indentation
	opts.h = #content
	local w = new_widget(opts)
	w.content = content
	w.kind = "chooser"
	if opts.multiple_choice then
		w.kind = "chooser_multi"
		w.selected = {}
	end
	w.idx = 1
	w:init()
	w:draw_borders()
	for i, _ in ipairs(content) do
		w:render_chooser_option(i)
	end
	w.label = ""
	while true do
		local key = term.simple_get()
		if key == "ESC" then
			if w.label ~= "" then
				w.label = ""
				w:draw_top_border()
			else
				w:cleanup()
				return w.kind == "chooser_multi" and {} or ""
			end
		elseif key == "ENTER" then
			if w.kind == "chooser_multi" then
				local result = {}
				for option, selected in pairs(w.selected) do
					if selected then
						table.insert(result, option)
					end
				end
				w:cleanup()
				return result
			else
				w:cleanup()
				return w.content[w.idx]
			end
		elseif key == " " and w.kind == "chooser_multi" then
			local option = w.content[w.idx]
			w.selected[option] = not w.selected[option]
			w:render_chooser_option(w.idx)
		elseif key == "UP" then
			if w.idx > 1 then
				w.idx = w.idx - 1
				w:render_chooser_option(w.idx)
				w:render_chooser_option(w.idx + 1)
			end
		elseif key == "DOWN" then
			if w.idx < #w.content then
				w.idx = w.idx + 1
				w:render_chooser_option(w.idx)
				w:render_chooser_option(w.idx - 1)
			end
		elseif key and key ~= "" and std.utf.len(key) < 2 then
			w.label = w.label .. key
			w:draw_top_border()
			for i, option in ipairs(w.content) do
				if option:match(w.label) then
					if w.idx ~= i then
						local prev_idx = w.idx
						w.idx = i
						w:render_chooser_option(w.idx)
						w:render_chooser_option(prev_idx)
						break
					end
				end
			end
		end
	end
end

local simple_confirm = function(text, rss)
	local tss = style.merge(default_rss, rss)
	term.write(tss:apply("confirm", text))
	local confirmed = io.read(1)
	if confirmed and (confirmed == "y" or confirmed == "Y") then
		return true
	end
	return false
end

local form = function(content, opts)
	if not content or type(content) ~= "table" then
		return false
	end

	local opts = opts or {}
	if not opts.meta then
		opts.meta = {}
	end
	local title = opts.title or ""
	local title_len = std.utf.len(title)
	local max_label = std.tbl.longest(content)
	local max_input = 0
	for i, label in ipairs(content) do
		local field_input = 10
		if opts.meta[label] then
			field_input = opts.meta[label].w or 10
		end
		if field_input > max_input then
			max_input = field_input
		end
	end
	local total_len = max_label + max_input
	if title_len > total_len then
		total_len = title_len
	end
	opts.w = total_len + 5
	opts.h = #content

	local w = new_widget(opts)
	w.content = content
	w.idx = 1
	w.results = {}
	w.meta = opts.meta
	w:init()
	w:draw_borders()
	w.tss.__style.form.input.w = max_input + 2
	w.tss.__style.form.label.w = max_label + 1

	for i, field in ipairs(w.content) do
		w:render_form_field(i)
	end

	local done = function(ww)
		for _, label in ipairs(ww.content) do
			if not ww.results[label] or ww.results[label] == "" then
				return false
			end
		end
		return true
	end

	repeat
		local key = term.simple_get()
		if key == "ESC" then
			w:cleanup()
			return w.results
		end
		if key == "ENTER" then
			local label = w.content[w.idx]
			local display_label = w.tss:apply("form.label", label)
			local y = w.l + (w.title ~= "" and 3 or 1) + w.idx - 1
			local x = w.c + 1 + std.utf.len(display_label)
			if w.meta[label] and w.meta[label].secret then
				w.tss.__style.form.input.content = "*"
			else
				w.tss.__style.form.input.content = nil
			end
			local buf =
				input.new({ l = y, c = x, width = w.w - std.utf.len(display_label) - 1, rss = w.tss.__style.form })
			w:goto_field(w.idx, true)
			term.show_cursor()
			buf:display()
			while true do
				local event = buf:run({ execute = true, exit = true })
				if event == "execute" then
					w.results[label] = buf:render()
					break
				elseif event == "exit" then
					break
				end
			end
			term.hide_cursor()
		end
		if key == "DOWN" or key == "RIGHT" or key == "TAB" then
			w.idx = w.idx + 1
			if w.idx > #w.content then
				w.idx = 1
			end
		end
		if key == "UP" or key == "LEFT" then
			if w.idx > 1 then
				w.idx = w.idx - 1
			else
				w.idx = #w.content
			end
		end
	until done(w)
	return w.results
end

--[==[
local file_chooser = function(title, start_dir, rss, patterns)
	local state = term.alt_screen()
	local invoke_dir = std.fs.cwd()
	local title = title or "Select a file/dir"
	local patterns = patterns or { mode = "[fdl]", select = "[fdl]" }
	local tss = style.merge(default_widgets_rss, rss)
	local start_dir = start_dir or invoke_dir
	local last_dir = os.getenv("LILUSH_FC_LASTDIR") or start_dir
	local cur_dir
	if last_dir:match("^" .. start_dir) then
		cur_dir = last_dir
	else
		cur_dir = start_dir
	end
	local w_y, w_x = term.window_size()

	local get_dir_files = function(dir)
		local files = std.fs.list_files(dir, "^[^.]", patterns.mode)
		local file_names = std.tbl.sort_keys(files)
		local max_width = std.tbl.longest(file_names)
		return file_names, files, max_width
	end
	local choice
	repeat
		term.clear()
		std.fs.chdir(cur_dir)
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
			key = term.simple_get()
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
					cur_dir = std.fs.cwd() .. "/" .. file_names[idx]
					key = "change_dir"
				end
				if key == "LEFT" then
					-- hacky way to restrict going upper than the start_dir
					if std.utf.len(cur_dir) > std.utf.len(start_dir) and std.fs.chdir("..") then
						cur_dir = std.fs.cwd()
						key = "change_dir"
					end
				end
				if key == "ENTER" and files[file_names[idx]].mode:match(patterns.select) then
					key = "chosen"
					choice = std.fs.cwd() .. "/" .. file_names[idx]
					break
				end
				if key == "ESC" then
					break
				end
			end
		until key == "change_dir"
	until key == "chosen" or key == "ESC"
	std.ps.setenv("LILUSH_FC_LASTDIR", std.fs.cwd())
	std.fs.chdir(invoke_dir)
	state:done()
	return choice
end
--]==]

local _M = {
	chooser = chooser,
	simple_confirm = simple_confirm,
	form = form,
}

return _M
