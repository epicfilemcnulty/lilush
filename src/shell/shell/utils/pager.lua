-- SPDX-FileCopyrightText: © 2022—2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: GPL-3.0-or-later

local std = require("std")
local json = require("cjson.safe")
local text = require("text")
local term = require("term")
local theme = require("shell.theme")
local style = require("term.tss")
local input = require("term.input")
local history = require("term.input.history")

local pager_next_render_mode = function(self)
	local modes = { "raw", "djot" }
	local idx = 0
	for i, mode in ipairs(modes) do
		if mode == self.__config.render_mode then
			idx = i + 1
			break
		end
	end
	if idx > #modes or idx == 0 then
		idx = 1
	end
	self:set_render_mode(modes[idx])
	self:display()
end

local pager_set_render_mode = function(self, mode)
	local mode = mode or self.__config.render_mode
	self.__config.render_mode = mode
	local rss = theme.renderer.kat
	local conf = { global_indent = 0, wrap = self.__config.wrap, mode = mode, hide_links = self.__config.hide_links }
	if mode == "raw" then
		if not self.__config.wrap_in_raw then
			conf.wrap = 0
		end
		rss = {}
	end
	self.content.rendered = text.render(self.content.raw, rss, conf)
	self.content.lines = std.txt.lines(self.content.rendered)
end

local pager_display_line_nums = function(self)
	local total_lines = #self.content.lines
	local lines_to_display = total_lines - self.__state.top_line + 1
	if lines_to_display > self.__window.capacity then
		lines_to_display = self.__window.capacity
	end
	for i = 1, lines_to_display do
		term.go(2 + i - 1, 1)
		local line_num = self.__state.top_line + i - 1
		local tss = style.new(theme.builtins.pager)
		if line_num == self.__state.cursor_line then
			term.write(tss:apply("line_num.selected", line_num))
		else
			term.write(tss:apply("line_num", line_num))
		end
	end
end

local pager_display = function(self)
	term.clear()
	local count = 0
	local indent = self.__config.indent + 1
	if self.__config.line_nums then
		indent = indent + 6
	end
	while count < self.__window.capacity do
		term.go(2 + count, indent)
		local idx = self.__state.top_line + count
		local line = self.content.lines[idx]
		if idx == self.__state.cursor_line and self.__search.pattern ~= "" and line then
			local tss = style.new(theme.builtins.pager)
			line = line:gsub(self.__search.pattern, tss:apply("search_match", "%1"))
		end
		if line then
			term.write(line)
		end
		count = count + 1
	end
	if self.__config.line_nums then
		self:display_line_nums()
	end
	if self.__config.status_line then
		self:display_status_line()
	end
end

local pager_display_status_line = function(self)
	local file = self.__state.history[#self.__state.history]
	local total_lines = #self.content.lines
	local kb_size = string.format("%.2f KB", #self.content.raw / 1024)
	local position_pct = ((self.__state.top_line + self.__window.capacity) / total_lines) * 100
	if position_pct > 100 then
		position_pct = 100.00
	end
	local tss = style.new(theme.builtins.pager)
	local position = string.format("%.2f", position_pct) .. "%"
	local top_status = tss:apply("status_line.filename", file)
		.. tss:apply("status_line.total_lines", total_lines .. " lines")
		.. tss:apply("status_line.size", kb_size)

	local bottom_status = tss:apply("status_line.position", position)
		.. tss:apply("status_line.render_mode", self.__config.render_mode)
	if self.__search.pattern ~= "" then
		bottom_status = bottom_status .. tss:apply("status_line.search.pattern", self.__search.pattern)
	end
	local y, _ = term.window_size()
	term.go(1, 1)
	term.clear_line()
	term.write(top_status)
	term.go(y, 1)
	term.clear_line()
	term.write(bottom_status)
end

local pager_load_content = function(self, filename)
	if filename then
		local content, err = std.fs.read_file(filename)
		if err then
			return nil, err
		end
		self.content = { raw = content }
		table.insert(self.__state.history, filename)
		return true
	end
	return nil
end

local pager_set_content = function(self, content, name)
	local name = name or "stdin"
	if content then
		self.content = { raw = content }
		table.insert(self.__state.history, name)
		return true
	end
	return nil
end

local pager_exit = function(self)
	self.__config.status_line = false
	if self.__screen then
		self.__screen:done()
	end
	term.go(self.__window.l, 1)
	local till = self.__window.capacity
	if self.__state.top_line > 1 then
		till = self.__state.top_line + self.__window.capacity
	end
	if till > #self.content.lines then
		till = #self.content.lines
	end
	-- Probably should add safety guardrails,
	-- if total_lines > 100kb or something...
	for i = 1, till do
		term.write(self.content.lines[i] .. "\r\n")
	end
end

local pager_toggle_line_nums = function(self)
	self.__config.line_nums = not self.__config.line_nums
	self:display()
end

local pager_toggle_status_line = function(self)
	self.__config.status_line = not self.__config.status_line
	self:display()
end

local pager_line_up = function(self)
	if self.__state.top_line > 1 then
		self.__state.top_line = self.__state.top_line - 1
		self:display()
	end
end

local pager_line_down = function(self)
	if self.__state.top_line + self.__window.capacity < #self.content.lines then
		self.__state.top_line = self.__state.top_line + 1
		self:display()
	end
end

local pager_page_up = function(self)
	self.__state.top_line = self.__state.top_line - self.__window.capacity
	if self.__state.top_line < 1 then
		self.__state.top_line = 1
	end
	self:display()
end

local pager_page_down = function(self)
	self.__state.top_line = self.__state.top_line + self.__window.capacity
	if self.__state.top_line > #self.content.lines - self.__window.capacity then
		self.__state.top_line = #self.content.lines - self.__window.capacity
	end
	self:display()
end

local pager_top_line = function(self)
	self.__state.top_line = 1
	self:display()
end

local pager_bottom_line = function(self)
	local position = 1
	if #self.content.lines > self.__window.capacity then
		position = #self.content.lines - self.__window.capacity
	end
	self.__state.top_line = position
	self:display()
end

local pager_change_indent = function(self, combo)
	if combo == "CTRL+RIGHT" then
		self.__config.indent = self.__config.indent + 1
		self:display()
	end
	if combo == "CTRL+LEFT" then
		if self.__config.indent > 0 then
			self.__config.indent = self.__config.indent - 1
			self:display()
		end
	end
end

local pager_change_wrap = function(self, combo)
	if combo == "ALT+RIGHT" then
		self.__config.wrap = self.__config.wrap + 5
		if self.__config.wrap > self.__window.x - 10 then
			self.__config.wrap = self.__window.x - 10
		end
		self:set_render_mode(self.__config.render_mode)
		self:display()
	end
	if combo == "ALT+LEFT" then
		self.__config.wrap = self.__config.wrap - 5
		if self.__config.wrap <= 40 then
			self.__config.wrap = 40
		end
		self:set_render_mode(self.__config.render_mode)
		self:display()
	end
end

local pager_goto_line = function(self, line_num)
	local line_num = line_num or 0
	if line_num > 0 and line_num <= #self.content.lines then
		self.__state.top_line = line_num - 2
		self.__state.cursor_line = line_num
		if self.__state.top_line < 1 then
			self.__state.top_line = 1
		end
		self:display()
	end
end

local pager_search = function(self, combo)
	local pattern = ""
	if combo == "/" then
		local buf = input.new({
			history = self.__search.history,
			l = self.__window.y,
			c = 9,
			rss = theme.builtins.pager.status_line.search,
		})
		term.go(self.__window.y, 1)
		local tss = style.new(theme.builtins.pager)
		term.write(tss:apply("status_line.search", "SEARCH: "))
		buf:display()
		term.show_cursor()
		event = buf:run()
		term.hide_cursor()
		pattern = buf:get_content()
		if pattern == "" then
			self.__search.idx = 0
			self.__state.cursor_line = 0
			self.__search.pattern = ""
			return true
		end
		self.__search.history:add(pattern)
	elseif combo:match("[nb]") then
		if self.__search.pattern == "" then
			return true
		end
		pattern = self.__search.pattern
	end
	self.__search.pattern = pattern
	if combo == "n" or combo == "/" then
		local start = self.__state.top_line
		if combo == "n" then
			start = self.__search.idx + 1
		end
		for idx = start, #self.content.lines do
			if self.content.lines[idx]:match(pattern) then
				self.__search.idx = idx
				self.__state.cursor_line = idx
				break
			end
		end
	elseif combo == "b" then
		for idx = self.__search.idx - 1, 1, -1 do
			if self.content.lines[idx]:match(pattern) then
				self.__search.idx = idx
				self.__state.cursor_line = idx
				break
			end
		end
	end
	if self.__search.idx > 0 then
		self.__state.top_line = self.__search.idx
		if self.__state.top_line > 2 then
			self.__state.top_line = self.__state.top_line - 2
		end
		self:display()
		return true
	end
	self.__search.idx = 0
end

local pager_page = function(self)
	if #self.content.lines < self.__window.capacity and self.__config.exit_on_one_page then
		return self:exit()
	end
	self.__screen = term.alt_screen()
	local buf = ""
	self:display()
	repeat
		local cp = term.simple_get()
		if cp then
			if cp == "q" then
				cp = "exit"
			end
			if self.__ctrls[cp] then
				self[self.__ctrls[cp]](self, cp)
			else
				if cp:match("[0-9]") then
					buf = buf .. cp
				elseif cp == "ENTER" and tonumber(buf) then
					self:goto_line(tonumber(buf))
					buf = ""
				else
					buf = ""
				end
			end
		end
	until cp == "exit"
	self:exit()
end

local pager_new = function(config)
	local y, x = term.window_size()
	local l, c = term.cursor_position()
	local wrap = 120
	if x < 130 then
		wrap = x - 10 -- reserved for line numbers
	end
	local default_config = {
		render_mode = "raw",
		exit_on_one_page = true,
		line_nums = false,
		status_line = true,
		indent = 0,
		wrap = wrap,
		wrap_in_raw = false,
		hide_links = false,
	}
	std.tbl.merge(default_config, config)
	local pager = {
		__window = { x = x, y = y, capacity = y - 2, l = l, c = c },
		__config = default_config,
		__state = {
			top_line = 1,
			cursor_line = 0,
			history = {},
		},
		__search = {
			idx = 0,
			pattern = "",
			history = history.new(),
		},
		content = {},
		__ctrls = {
			["PAGE_UP"] = "page_up",
			["K"] = "page_up",
			["PAGE_DOWN"] = "page_down",
			["J"] = "page_down",
			["UP"] = "line_up",
			["k"] = "line_up",
			["DOWN"] = "line_down",
			["j"] = "line_down",
			[" "] = "line_down",
			["CTRL+RIGHT"] = "change_indent",
			["CTRL+LEFT"] = "change_indent",
			["ALT+RIGHT"] = "change_wrap",
			["ALT+LEFT"] = "change_wrap",
			["CTRL+r"] = "next_render_mode",
			["HOME"] = "top_line",
			["g"] = "top_line",
			["END"] = "bottom_line",
			["G"] = "bottom_line",
			["s"] = "toggle_status_line",
			["l"] = "toggle_line_nums",
			["/"] = "search",
			["n"] = "search",
			["b"] = "search",
		},
		-- METHODS
		display = pager_display,
		display_line_nums = pager_display_line_nums,
		display_status_line = pager_display_status_line,
		load_content = pager_load_content,
		set_content = pager_set_content,
		next_render_mode = pager_next_render_mode,
		set_render_mode = pager_set_render_mode,
		line_up = pager_line_up,
		line_down = pager_line_down,
		top_line = pager_top_line,
		bottom_line = pager_bottom_line,
		page_up = pager_page_up,
		page_down = pager_page_down,
		goto_line = pager_goto_line,
		toggle_line_nums = pager_toggle_line_nums,
		toggle_status_line = pager_toggle_status_line,
		change_indent = pager_change_indent,
		change_wrap = pager_change_wrap,
		search = pager_search,
		page = pager_page,
		exit = pager_exit,
	}
	return pager
end

return {
	new = pager_new,
}
