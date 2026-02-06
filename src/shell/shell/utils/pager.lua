-- SPDX-FileCopyrightText: © 2022—2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: GPL-3.0-or-later

local std = require("std")
local json = require("cjson.safe")
local markdown = require("markdown")
local md_theme = require("markdown.renderer.theme")
local crypto = require("crypto")
local term = require("term")
local theme = require("shell.theme")
local style = require("term.tss")
local input = require("term.input")
local history = require("term.input.history")

local pager_next_render_mode = function(self)
	local modes = { "raw", "markdown" }
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

	if mode == "markdown" then
		-- Align OSC66 width accounting with terminal behavior.
		-- Some terminals treat s+w as combined width (s*w), others as w-only.
		local supports_ts = true
		if std.utf and std.utf.set_ts_width_mode and term.raw_mode and term.raw_mode() then
			local ts_mode = "combined"
			local ts_support = term.has_ts and term.has_ts() or false
			supports_ts = (ts_support ~= false)
			if ts_support == "width" then
				ts_mode = "w_only"
			elseif ts_support == true and term.has_ts_combined and not term.has_ts_combined() then
				ts_mode = "w_only"
			end
			std.utf.set_ts_width_mode(ts_mode)
		end

		-- Calculate content width with priority:
		-- 1. Pager config wrap override
		-- 2. TSS wrap value
		-- 3. Dynamic (85% of terminal width)
		local terminal_width = self.__window.x
		local tss_wrap = md_theme.DEFAULT_RSS.wrap
		local content_width

		if self.__config.wrap and self.__config.wrap > 0 then
			-- Priority 1: Pager override
			content_width = math.min(self.__config.wrap, terminal_width - 4)
		elseif tss_wrap and tss_wrap > 0 then
			-- Priority 2: TSS wrap
			content_width = math.min(tss_wrap, terminal_width - 4)
		else
			-- Priority 3: Dynamic (85% of terminal, ~7.5% margin each side)
			content_width = math.floor(terminal_width * 0.85)
			content_width = math.max(40, content_width)
		end

		-- Use markdown renderer with default TSS
		-- TODO: Add user theme support to markdown module
		local result = markdown.render(self.content.raw, {
			width = content_width,
			return_metadata = true,
			hide_link_urls = true,
			supports_ts = supports_ts,
		})

		self.content.rendered = result.rendered
		self.content.elements = result.elements
		self.__config.content_width = content_width

		-- Build focusable elements list for navigation
		self:build_focusable_elements()
	else
		-- Raw mode: plain text with optional wrapping
		local raw = self.content.raw or ""
		if self.__config.wrap_in_raw and self.__config.wrap > 0 then
			local wrapped_lines = std.txt.lines_of(raw, self.__config.wrap)
			self.content.rendered = table.concat(wrapped_lines, "\n")
		else
			self.content.rendered = raw
		end
		self.content.elements = nil
		self.__navigation.elements = {}
		self.__navigation.focused_idx = 0
	end

	self.content.lines = std.txt.lines(self.content.rendered)
end

-- Build list of focusable elements from markdown metadata
local pager_build_focusable_elements = function(self)
	self.__navigation.elements = {}
	self.__navigation.focused_idx = 0

	if not self.content.elements then
		return
	end

	local el = self.content.elements
	local list = {}

	-- Add code blocks
	for _, cb in ipairs(el.code_blocks or {}) do
		list[#list + 1] = {
			type = "code_block",
			start_line = cb.start_line,
			end_line = cb.end_line,
			raw = cb.raw,
			lang = cb.lang,
			_order = #list + 1,
		}
	end

	-- Add links
	for _, link in ipairs(el.links or {}) do
		local item = {
			type = "link",
			line = link.line,
			url = link.url,
			title = link.title,
			_order = #list + 1,
		}
		-- If inside a bordered container, use container's line range for highlighting
		if link.container then
			item.start_line = link.container.start_line
			item.end_line = link.container.end_line
		end
		list[#list + 1] = item
	end

	-- Add footnote refs
	for _, fn in ipairs(el.footnote_refs or {}) do
		local item = {
			type = "footnote_ref",
			line = fn.line,
			label = fn.label,
			_order = #list + 1,
		}
		-- If inside a bordered container, use container's line range for highlighting
		if fn.container then
			item.start_line = fn.container.start_line
			item.end_line = fn.container.end_line
		end
		list[#list + 1] = item
	end

	-- Add headers
	for _, hdr in ipairs(el.headers or {}) do
		list[#list + 1] = {
			type = "header",
			line = hdr.line,
			level = hdr.level,
			text = hdr.text,
			_order = #list + 1,
		}
	end

	-- Sort by position (use _order as tiebreaker for elements on same line)
	table.sort(list, function(a, b)
		local line_a = a.start_line or a.line
		local line_b = b.start_line or b.line
		if line_a ~= line_b then
			return line_a < line_b
		end
		return (a._order or 0) < (b._order or 0)
	end)

	self.__navigation.elements = list
end

-- Extract code block positions and raw content for OSC52 clipboard copy
local pager_extract_code_blocks = function(self)
	self.content.code_blocks = {}
	local raw = self.content.raw or ""

	-- Parse markdown to find code blocks
	local in_code_block = false
	local code_fence = nil
	local current_block = nil
	local raw_line_num = 0
	local rendered_line_num = 0

	-- Track rendered line positions by parsing the rendered output for code blocks
	-- Since we can't easily correlate raw and rendered lines, we parse the raw
	-- and estimate rendered positions based on the structure

	for line in (raw .. "\n"):gmatch("([^\n]*)\n") do
		raw_line_num = raw_line_num + 1

		if not in_code_block then
			-- Check for code fence start
			local fence = line:match("^(`{3,})%s*")
			if fence then
				in_code_block = true
				code_fence = fence
				current_block = {
					start_raw = raw_line_num,
					content = {},
				}
			end
		else
			-- Check for code fence end
			if line:match("^" .. code_fence:gsub("`", "%%`") .. "%s*$") then
				in_code_block = false
				current_block.end_raw = raw_line_num
				current_block.raw = table.concat(current_block.content, "\n")
				self.content.code_blocks[#self.content.code_blocks + 1] = current_block
				current_block = nil
				code_fence = nil
			else
				current_block.content[#current_block.content + 1] = line
			end
		end
	end
end

-- Copy code block to clipboard using OSC52
local pager_copy_code_block = function(self)
	if not self.content.code_blocks or #self.content.code_blocks == 0 then
		return false, "No code blocks found"
	end

	-- Find the code block closest to current view position
	-- Use raw line position estimation based on top_line
	local target_raw_line = self.__state.top_line

	local closest_block = nil
	local closest_distance = math.huge

	for _, block in ipairs(self.content.code_blocks) do
		-- Check if current view overlaps with this block
		local block_start = block.start_raw
		local block_end = block.end_raw
		local view_end = target_raw_line + self.__window.capacity

		-- Block is visible or closest to view
		if target_raw_line <= block_end and view_end >= block_start then
			-- Block overlaps with view - prefer this one
			closest_block = block
			break
		else
			-- Calculate distance to block
			local dist = math.min(math.abs(target_raw_line - block_start), math.abs(target_raw_line - block_end))
			if dist < closest_distance then
				closest_distance = dist
				closest_block = block
			end
		end
	end

	if not closest_block or not closest_block.raw then
		return false, "No code block at current position"
	end

	-- OSC52 clipboard copy
	local encoded = crypto.b64_encode(closest_block.raw)
	io.write("\027]52;c;" .. encoded .. "\027\\")
	io.flush()

	return true
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
			term.write(tss:apply("line_num.selected", line_num).text)
		else
			term.write(tss:apply("line_num", line_num).text)
		end
	end
end

local pager_display = function(self)
	term.clear()
	local count = 0

	-- Calculate centering margin
	local margin = 0
	if self.__config.render_mode == "markdown" and self.__config.content_width then
		margin = math.floor((self.__window.x - self.__config.content_width) / 2)
		if margin < 0 then
			margin = 0
		end
	end

	local indent = self.__config.indent + 1 + margin
	if self.__config.line_nums then
		indent = indent + 6
	end

	-- Get focused element for highlighting
	local focused = nil
	if self.__navigation.focused_idx > 0 then
		focused = self.__navigation.elements[self.__navigation.focused_idx]
	end

	while count < self.__window.capacity do
		term.go(2 + count, indent)
		local idx = self.__state.top_line + count
		local line = self.content.lines[idx]

		-- Apply search highlighting
		if idx == self.__state.cursor_line and self.__search.pattern ~= "" and line then
			local tss = style.new(theme.builtins.pager)
			line = line:gsub(self.__search.pattern, tss:apply("search_match", "%1").text)
		end

		-- Apply focus highlighting (skip headers)
		if focused and focused.type ~= "header" and line then
			local el_start = focused.start_line or focused.line
			local el_end = focused.end_line or focused.line
			if idx >= el_start and idx <= el_end then
				-- Mark focused element with a left indicator
				local tss = style.new(theme.builtins.pager)
				local marker = tss:apply("element.focused", "▌").text
				line = marker .. line
			end
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

	-- Top bar: file info + focused element hints + notifications
	local top_status = tss:apply("status_line.filename", file)
		.. tss:apply("status_line.total_lines", total_lines .. " lines")
		.. tss:apply("status_line.size", kb_size)

	-- Add notification or focused element hints to top bar (mutually exclusive)
	if self.__notification then
		top_status = top_status .. tss:apply("status_line.hint", self.__notification)
	else
		local focused = nil
		if self.__navigation.focused_idx > 0 then
			focused = self.__navigation.elements[self.__navigation.focused_idx]
		end

		if focused then
			local hint = "'y' to copy"
			if focused.type == "code_block" then
				top_status = top_status .. tss:apply("status_line.codeblock", "codeblock")
				if focused.lang then
					top_status = top_status .. tss:apply("status_line.codeblock.lang", focused.lang)
				end
				top_status = top_status .. tss:apply("status_line.hint", hint)
			elseif focused.type == "link" then
				top_status = top_status .. tss:apply("status_line.url", focused.url)
				top_status = top_status .. tss:apply("status_line.hint", hint)
			elseif focused.type == "footnote_ref" then
				top_status = top_status .. tss:apply("status_line.hint", "'Enter' to jump to [" .. focused.label .. "]")
			end
		end
	end

	-- Bottom bar: position, render mode, search
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
		self.__navigation.focused_idx = 0
		self:display()
	end
end

local pager_line_down = function(self)
	if self.__state.top_line + self.__window.capacity < #self.content.lines then
		self.__state.top_line = self.__state.top_line + 1
		self.__navigation.focused_idx = 0
		self:display()
	end
end

local pager_page_up = function(self)
	self.__state.top_line = self.__state.top_line - self.__window.capacity
	if self.__state.top_line < 1 then
		self.__state.top_line = 1
	end
	self.__navigation.focused_idx = 0
	self:display()
end

local pager_page_down = function(self)
	self.__state.top_line = self.__state.top_line + self.__window.capacity
	if self.__state.top_line > #self.content.lines - self.__window.capacity then
		self.__state.top_line = #self.content.lines - self.__window.capacity
	end
	self.__navigation.focused_idx = 0
	self:display()
end

local pager_top_line = function(self)
	self.__state.top_line = 1
	self.__navigation.focused_idx = 0
	self:display()
end

local pager_bottom_line = function(self)
	local position = 1
	if #self.content.lines > self.__window.capacity then
		position = #self.content.lines - self.__window.capacity
	end
	self.__state.top_line = position
	self.__navigation.focused_idx = 0
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
			width = self.__window.x - 9,
			rss = theme.builtins.pager.status_line.search,
		})
		term.go(self.__window.y, 1)
		local tss = style.new(theme.builtins.pager)
		term.write(tss:apply("status_line.search", "SEARCH: ").text)
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

-- Ensure a line is visible in the viewport
local pager_ensure_visible = function(self, line)
	if line < self.__state.top_line then
		self.__state.top_line = math.max(1, line - 2)
	elseif line > self.__state.top_line + self.__window.capacity - 1 then
		self.__state.top_line = line - 2
		if self.__state.top_line < 1 then
			self.__state.top_line = 1
		end
	end
end

-- Focus next element (Tab) - skips headers
local pager_focus_next = function(self)
	local elements = self.__navigation.elements
	if #elements == 0 then
		return
	end

	local start_idx = self.__navigation.focused_idx

	-- When unfocused, find first non-header element at or after current viewport
	if start_idx == 0 then
		local top = self.__state.top_line
		for i, el in ipairs(elements) do
			if el.type ~= "header" then
				local el_line = el.start_line or el.line
				if el_line >= top then
					self.__navigation.focused_idx = i
					self:ensure_visible(el_line)
					self:display()
					return
				end
			end
		end
		-- No element found after viewport, wrap to first non-header
		for i, el in ipairs(elements) do
			if el.type ~= "header" then
				self.__navigation.focused_idx = i
				local line = el.start_line or el.line
				self:ensure_visible(line)
				self:display()
				return
			end
		end
		return
	end

	local idx = start_idx
	repeat
		idx = idx + 1
		if idx > #elements then
			idx = 1
		end
	until elements[idx].type ~= "header" or idx == start_idx

	if elements[idx].type == "header" then
		return -- no non-header elements found
	end

	self.__navigation.focused_idx = idx
	local el = elements[idx]
	local line = el.start_line or el.line
	self:ensure_visible(line)
	self:display()
end

-- Focus previous element (Shift+Tab) - skips headers
local pager_focus_prev = function(self)
	local elements = self.__navigation.elements
	if #elements == 0 then
		return
	end

	local start_idx = self.__navigation.focused_idx

	-- When unfocused, find last non-header element at or before viewport bottom
	if start_idx == 0 then
		local bottom = self.__state.top_line + self.__window.capacity
		local last_before = nil
		for i, el in ipairs(elements) do
			if el.type ~= "header" then
				local el_line = el.start_line or el.line
				if el_line <= bottom then
					last_before = i
				end
			end
		end
		if last_before then
			self.__navigation.focused_idx = last_before
			local el = elements[last_before]
			local line = el.start_line or el.line
			self:ensure_visible(line)
			self:display()
			return
		end
		-- No element found before viewport, wrap to last non-header
		for i = #elements, 1, -1 do
			if elements[i].type ~= "header" then
				self.__navigation.focused_idx = i
				local line = elements[i].start_line or elements[i].line
				self:ensure_visible(line)
				self:display()
				return
			end
		end
		return
	end

	local idx = start_idx
	repeat
		idx = idx - 1
		if idx < 1 then
			idx = #elements
		end
	until elements[idx].type ~= "header" or idx == start_idx

	if elements[idx].type == "header" then
		return -- no non-header elements found
	end

	self.__navigation.focused_idx = idx
	local el = elements[idx]
	local line = el.start_line or el.line
	self:ensure_visible(line)
	self:display()
end

-- Jump to next header
local pager_header_next = function(self)
	local elements = self.__navigation.elements
	if #elements == 0 then
		return
	end

	-- Use top_line + 3 to skip past any header we're currently viewing
	local current_line = self.__state.top_line + 3
	for _, el in ipairs(elements) do
		if el.type == "header" and el.line > current_line then
			self.__state.top_line = math.max(1, el.line - 2)
			self.__navigation.focused_idx = 0
			self:display()
			return
		end
	end
end

-- Jump to previous header
local pager_header_prev = function(self)
	local elements = self.__navigation.elements
	if #elements == 0 then
		return
	end

	-- Find the last header before the current top_line
	local current_line = self.__state.top_line
	local prev_header = nil
	for _, el in ipairs(elements) do
		if el.type == "header" and el.line < current_line then
			prev_header = el
		end
	end

	if prev_header then
		self.__state.top_line = math.max(1, prev_header.line - 2)
		self.__navigation.focused_idx = 0
		self:display()
	end
end

-- Copy focused element (code block content or link URL)
local pager_copy_element = function(self)
	local focused = self.__navigation.focused_idx > 0 and self.__navigation.elements[self.__navigation.focused_idx]

	if not focused then
		return false, "No element focused"
	end

	local content_to_copy = nil

	if focused.type == "code_block" then
		if focused.raw and focused.raw ~= "" then
			content_to_copy = focused.raw
		else
			return false, "Code block is empty"
		end
	elseif focused.type == "link" then
		if focused.url and focused.url ~= "" then
			content_to_copy = focused.url
		else
			return false, "Link has no URL"
		end
	else
		return false, "Element type not copyable"
	end

	if content_to_copy then
		local encoded = crypto.b64_encode(content_to_copy)
		-- Disable KKBP and bracketed paste temporarily for OSC52
		--term.disable_kkbp()
		--term.disable_bracketed_paste()
		io.write("\027]52;c;" .. encoded .. "\007")
		io.flush()
		--term.enable_kkbp()
		--term.enable_bracketed_paste()
		return true
	end

	return false, "Nothing to copy"
end

-- Jump to footnote definition
local pager_jump_to_footnote = function(self)
	local focused = self.__navigation.focused_idx > 0 and self.__navigation.elements[self.__navigation.focused_idx]

	if not focused or focused.type ~= "footnote_ref" then
		return false
	end

	local defs = self.content.elements and self.content.elements.footnote_defs or {}
	for _, def in ipairs(defs) do
		if def.label == focused.label then
			self.__navigation.return_position = self.__state.top_line
			self.__state.top_line = math.max(1, def.start_line - 2)
			self:display()
			return true
		end
	end
	return false
end

-- Return from footnote jump
local pager_return_from_footnote = function(self)
	if self.__navigation.return_position then
		self.__state.top_line = self.__navigation.return_position
		self.__navigation.return_position = nil
		self:display()
		return true
	end
	return false
end

-- Activate focused element (Enter key)
local pager_activate_element = function(self)
	local focused = self.__navigation.focused_idx > 0 and self.__navigation.elements[self.__navigation.focused_idx]

	if focused and focused.type == "footnote_ref" then
		return self:jump_to_footnote()
	end

	return false
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
			self.__notification = nil
			if cp == "q" then
				cp = "exit"
			end
			if self.__ctrls[cp] then
				if cp == "y" then
					local ok, err = self:copy_element()
					if ok then
						self.__notification = "Copied!"
					else
						self.__notification = err or "Copy failed"
					end
					self:display()
				else
					self[self.__ctrls[cp]](self, cp)
				end
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

	local default_config = {
		render_mode = "raw",
		exit_on_one_page = true,
		line_nums = false,
		status_line = true,
		indent = 0,
		wrap = 0,
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
		__navigation = {
			elements = {},
			focused_idx = 0,
			return_position = nil,
		},
		__notification = nil,
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
			["y"] = "copy_element",
			["TAB"] = "focus_next",
			["SHIFT+TAB"] = "focus_prev",
			["["] = "header_prev",
			["]"] = "header_next",
			["ENTER"] = "activate_element",
			["BACKSPACE"] = "return_from_footnote",
		},
		-- METHODS
		display = pager_display,
		display_line_nums = pager_display_line_nums,
		display_status_line = pager_display_status_line,
		load_content = pager_load_content,
		set_content = pager_set_content,
		next_render_mode = pager_next_render_mode,
		set_render_mode = pager_set_render_mode,
		build_focusable_elements = pager_build_focusable_elements,
		extract_code_blocks = pager_extract_code_blocks,
		copy_code_block = pager_copy_code_block,
		copy_element = pager_copy_element,
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
		ensure_visible = pager_ensure_visible,
		focus_next = pager_focus_next,
		focus_prev = pager_focus_prev,
		header_next = pager_header_next,
		header_prev = pager_header_prev,
		jump_to_footnote = pager_jump_to_footnote,
		return_from_footnote = pager_return_from_footnote,
		activate_element = pager_activate_element,
		page = pager_page,
		exit = pager_exit,
	}
	return pager
end

return {
	new = pager_new,
}
