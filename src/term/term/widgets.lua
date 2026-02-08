-- SPDX-FileCopyrightText: © 2022—2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: LicenseRef-OWL-1.0-or-later OR GPL-3.0-or-later
-- Dual-licensed under OWL v1.0+ and GPLv3+. See LICENSE and LICENSE-GPL3.

local std = require("std")
local term = require("term")
local style = require("term.tss")
local input = require("term.input")

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

local draw_top_border = function(self, tss_ctx)
	local tss_ctx = tss_ctx or self.tss
	term.go(self.l, self.c)
	term.write(tss_ctx:apply("borders.top_line", nil, self.c).text)
	if self.label then
		term.go(self.l, self.c + 1)
		term.write(tss_ctx:apply("borders.label", self.label, self.c + 1).text)
	end
end

local draw_borders = function(self)
	local height = self.h + 2
	local border_tss = self.tss:scope({
		w = self.w,
		borders = { w = self.w + 2 },
	})

	self:draw_top_border(border_tss)
	local offset = 1
	if self.title ~= "" then
		height = height + 2
		term.go(self.l + 1, self.c)
		term.write(
			border_tss:apply("borders.v", nil, self.c).text
				.. border_tss:apply("title", self.title, self.c + 1).text
				.. border_tss:apply("borders.v", nil, self.c + std.utf.len(self.title) + 1).text
		)
		term.go(self.l + 2, self.c)
		term.write(border_tss:apply("borders.subtitle_line", nil, self.c).text)
		offset = 2
	end
	for i = 1, height - offset - 2 do
		term.go(self.l + offset + i, self.c)
		term.write(border_tss:apply("borders.v", nil, self.c).text)
		term.go(self.l + offset + i, self.c + self.w + 1)
		term.write(border_tss:apply("borders.v", nil, self.c + self.w).text)
	end
	term.go(self.l + height - 1, self.c)
	term.write(border_tss:apply("borders.bottom_line", nil, self.c).text)
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
	local content_col = self.kind == "chooser_multi" and self.c or (self.c + 1)
	term.go(self.l + self.content_start + idx - 1, content_col)

	if self.kind == "chooser_multi" then
		if self.selected[option] then
			term.write(self.tss:apply("option.marked").text)
		else
			term.write(self.tss:apply("borders.v", nil, self.c).text)
		end
	end
	if idx == self.idx then
		term.write(self.tss:apply("option.selected", option).text)
	else
		term.write(self.tss:apply("option", option).text)
	end
end

local goto_field = function(self, idx, to_input)
	local label = self.tss:apply("form.label", self.content[idx])
	local c = self.c + 1
	if to_input then
		c = c + label.width
	end
	term.go(self.l + self.content_start + idx - 1, c)
end

local render_form_field = function(self, idx)
	local label = self.content[idx]
	local display_label = self.tss:apply("form.label", label)
	self:goto_field(idx)
	term.write(display_label.text)
	term.write(self.tss:apply("form.input.line").text)
	if self.results[label] then
		self:goto_field(idx, true)
		local value = self.results[label]
		if self.meta[label] and self.meta[label].secret then
			value = string.rep("*", std.utf.len(value))
		end
		term.write(self.tss:apply("form.input", value).text)
	end
end

local new_widget = function(opts)
	opts = opts or {}
	local widget = {
		l = opts.l or 1,
		c = opts.c or 1,
		w = opts.w or 0,
		h = opts.h or 0,
		title = opts.title or "",
		tss = style.merge(default_rss, opts.rss),
		kind = opts.kind or "widget",
	}
	widget.content_start = widget.title ~= "" and 3 or 1
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
	opts = opts or {}
	content = content or {}
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
		w.selected = opts.selected or {}
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
				for _, option in ipairs(w.content) do
					if w.selected[option] then
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
				if option:find(w.label, 1, true) then
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
	term.write(tss:apply("confirm", text).text)
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

	opts = opts or {}
	if not opts.meta then
		opts.meta = {}
	end
	local title = opts.title or ""
	local title_len = std.utf.len(title)
	local max_label = std.tbl.longest(content)
	local max_input = 0
	for _, label in ipairs(content) do
		local field_input = 10
		if opts.meta[label] then
			field_input = opts.meta[label].w or 10
		end
		max_input = math.max(max_input, field_input)
	end
	local total_len = math.max(title_len, max_label + max_input)
	opts.w = total_len + 5
	opts.h = #content

	local w = new_widget(opts)
	w.content = content
	w.idx = 1
	w.results = {}
	w.meta = opts.meta
	w:init()
	w:draw_borders()
	w.tss:set_property("form.input", "w", max_input + 2)
	w.tss:set_property("form.label", "w", max_label + 1)

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
			local y = w.l + w.content_start + w.idx - 1
			local x = w.c + 1 + display_label.width
			local tss_snapshot = w.tss.style_snapshot and w.tss:style_snapshot() or { form = {} }
			local form_rss = std.tbl.copy(tss_snapshot.form or {})
			form_rss.input = form_rss.input or {}
			if w.meta[label] and w.meta[label].secret then
				form_rss.input.content = "*"
			else
				form_rss.input.content = nil
			end
			local buf = input.new({ l = y, c = x, width = w.w - display_label.width - 1, rss = form_rss })
			w:goto_field(w.idx, true)
			term.show_cursor()
			buf:display()
			while true do
				local event = buf:run({ execute = true, exit = true })
				if event == "execute" then
					w.results[label] = buf:get_content()
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

return {
	chooser = chooser,
	simple_confirm = simple_confirm,
	form = form,
}
