-- SPDX-FileCopyrightText: © 2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: OWL-1.0 or later
-- Licensed under the Open Weights License v1.0. See LICENSE for details.

--[[
Streaming terminal renderer for markdown.

Outputs text immediately as parser events arrive, with special cursor-based
re-rendering for code blocks. Suitable for LLM streaming output.

Unlike the static renderer which buffers all content, this renderer:
- Emits paragraph/heading text immediately with inline styles
- Buffers code blocks, then re-renders with borders at block_end
- Uses cursor movement to overwrite previously output code block content

Requires a terminal with cursor movement support (Kitty, foot, alacritty, etc.).

Usage:
    local streaming = require("markdown.renderer.streaming")
    local renderer = streaming.new({ width = 80 })

    -- Feed events from parser
    renderer:render_event({ type = "block_start", tag = "para" })
    renderer:render_event({ type = "text", text = "Hello" })
    renderer:render_event({ type = "block_end", tag = "para" })

    -- Finalize
    renderer:finish()
]]

local std = require("std")
local buffer = require("string.buffer")
local tss_mod = require("term.tss")
local term = require("term")
local theme = require("markdown.renderer.theme")

-- Synchronized output escape sequences (prevents tearing during re-render)
local SYNC_START = "\027[?2026h"
local SYNC_END = "\027[?2026l"

local DEFAULT_BORDERS = theme.DEFAULT_BORDERS
local DEFAULT_RSS = theme.DEFAULT_RSS

-- Get current position in heading content buffer
local get_heading_pos = function(self)
	return std.utf.len(self._heading_content.plain)
end

-- Apply current inline style stack to text (for paragraphs only - headings are buffered)
local apply_current_styles = function(self, text)
	if #self._inline_stack == 0 then
		-- Apply base paragraph style
		if self._in_paragraph then
			return self._tss:apply("para", text).text
		end
		return text
	end

	-- Build list of style elements from stack
	local elements = {}

	-- Add base style first
	if self._in_paragraph then
		elements[#elements + 1] = "para"
	end

	-- Add inline styles
	for _, style_info in ipairs(self._inline_stack) do
		local tag = style_info.tag
		if tag == "strong" or tag == "emph" or tag == "strikethrough" then
			elements[#elements + 1] = tag
		elseif tag == "code" then
			elements[#elements + 1] = "code" -- Base style first
			if style_info.attrs and style_info.attrs.class then
				-- Support multiple space-separated classes
				for class in style_info.attrs.class:gmatch("%S+") do
					elements[#elements + 1] = "code." .. class
				end
			end
		elseif tag == "link" then
			elements[#elements + 1] = "link.title"
		elseif tag == "image" then
			elements[#elements + 1] = "image.alt"
		end
	end

	if #elements == 0 then
		return text
	end

	return self._tss:apply(elements, text).text
end

-- Render buffered heading with text-sizing
local render_heading = function(self)
	local content = self._heading_content
	local level = self._heading_level

	if content.plain == "" then
		self._output("\n")
		return
	end

	-- Apply level-specific style using apply_sized (handles text-sizing and inline ranges)
	local level_key = "h" .. tostring(level)
	local result = self._tss:apply_sized({ "heading", "heading." .. level_key }, content)

	-- Output the styled heading
	-- Text-sizing may occupy multiple terminal rows
	local extra_lines = result.height - 1
	self._output(result.text)
	self._output("\n")
	if extra_lines > 0 then
		self._output(string.rep("\n", extra_lines))
	end
	self._output("\n")
end

-- Output list marker for current list item
local output_list_marker = function(self)
	local depth = self._list_item_depth
	local list = self._list_stack[depth]
	if not list then
		return
	end

	local item_count = self._list_item_count[depth] or 1
	local item_num = list.ordered and (list.start + item_count - 1) or item_count

	-- Build base indent for nesting (4 spaces per level, starting at level 2)
	local base_indent = string.rep("    ", depth - 1)

	local marker_text
	local marker_width

	if list.ordered then
		local num_str = string.format("%d. ", item_num)
		local styled = self._tss:apply("list_item.ol", num_str)
		marker_text = base_indent .. styled.text
		marker_width = #base_indent + std.utf.display_len(num_str)
	elseif self._list_item_task then
		-- Task list: render checkbox
		local checkbox_style = self._list_item_task.checked and "task_list.checked" or "task_list.unchecked"
		local styled = self._tss:apply(checkbox_style)
		marker_text = base_indent .. styled.text
		local _, obj = self._tss:get(checkbox_style)
		local checkbox_content = obj.content or (self._list_item_task.checked and "☑ " or "☐ ")
		marker_width = #base_indent + std.utf.display_len(checkbox_content)
	else
		local styled = self._tss:apply("list_item.ul")
		marker_text = base_indent .. styled.text
		local _, obj = self._tss:get("list_item.ul")
		local marker_content = obj.content or "- "
		marker_width = #base_indent + std.utf.display_len(marker_content)
	end

	self._output(marker_text)
	self._list_item_first_block = false
	self._list_continuation_indent = string.rep(" ", marker_width)
	self._line_has_content = true
end

-- Render thematic break
local render_thematic_break = function(self)
	-- Get thematic break style properties
	local props, obj = self._tss:get("thematic_break")

	-- Calculate element width (respects w = 0.5 for 50% width)
	local el_width = self._tss:calc_el_width(obj.w or 1, self._width)
	if el_width == 0 then
		el_width = self._width
	end

	-- Generate the content (fill with the character)
	local fill_char = obj.fill_char or "─"
	local filled = string.rep(fill_char, math.ceil(el_width / std.utf.display_len(fill_char)))
	filled = std.utf.sub(filled, 1, el_width)

	-- Apply styling (TSS won't add alignment padding since tss.__window.w = content width,
	-- making effective_w = el_width, so there's no room for TSS to add padding)
	local styled = self._tss:apply("thematic_break", filled).text

	-- Manual alignment to center element within the content area
	local align = props.align or "none"
	local left_pad = ""
	if align == "center" then
		left_pad = string.rep(" ", math.floor((self._width - el_width) / 2))
	elseif align == "right" then
		left_pad = string.rep(" ", self._width - el_width)
	end

	self._output(left_pad .. styled .. "\n\n")
end

-- Render a bordered block (code blocks)
local render_bordered_block = function(self, lines, label)
	local out = buffer.new()
	local style_base = "code_block"
	local width = self._width

	-- Get border definition and padding
	local border_def = self._tss.__style[style_base] and self._tss.__style[style_base].border or DEFAULT_BORDERS
	local _, code_obj = self._tss:get(style_base)
	local pad = (code_obj and code_obj.pad) or 0
	local pad_str = string.rep(" ", pad)

	-- Store original values to restore later
	local orig_w = self._tss.__style[style_base] and self._tss.__style[style_base].w
	local orig_align = self._tss.__style[style_base] and self._tss.__style[style_base].align
	local orig_border_w = self._tss.__style[style_base]
		and self._tss.__style[style_base].border
		and self._tss.__style[style_base].border.w

	-- Set border width
	if self._tss.__style[style_base] and self._tss.__style[style_base].border then
		self._tss.__style[style_base].border.w = width
	end

	-- Build top line
	local top_line
	if label and label ~= "" then
		local styled_label = self._tss:apply(style_base .. ".lang", label)
		local label_len = styled_label.width

		local st =
			self._tss:apply(style_base .. ".border", border_def.top_line.before .. border_def.top_line.content).text
		st = st
			.. styled_label.text
			.. self._tss:apply(
				style_base .. ".border",
				string.rep(border_def.top_line.content, math.max(width - label_len - 1, 0)) .. border_def.top_line.after
			).text
		top_line = st
	else
		top_line = self._tss:apply(style_base .. ".border.top_line").text
	end

	-- Set content width for padding alignment (minus padding)
	local inner_width = width - pad
	if self._tss.__style[style_base] then
		self._tss.__style[style_base].w = inner_width
		if not orig_align or orig_align == "none" then
			self._tss.__style[style_base].align = "left"
		end
	end

	-- Output top border
	out:put(top_line, "\n")

	-- Output content lines with vertical borders
	for i, l in ipairs(lines) do
		local is_last = (i == #lines)
		local is_empty = (l == "" or l:match("^%s*$"))
		if not (is_last and is_empty) then
			out:put(
				self._tss:apply(style_base .. ".border.v").text,
				pad_str,
				self._tss:apply(style_base, l).text,
				self._tss:apply(style_base .. ".border.v").text,
				"\n"
			)
		end
	end

	-- Restore width for bottom border (must be full width, not inner_width)
	if self._tss.__style[style_base] then
		self._tss.__style[style_base].w = width
	end

	-- Output bottom border
	out:put(self._tss:apply(style_base .. ".border.bottom_line").text, "\n")

	-- Restore original values
	if self._tss.__style[style_base] then
		self._tss.__style[style_base].w = orig_w
		self._tss.__style[style_base].align = orig_align
		if self._tss.__style[style_base].border then
			self._tss.__style[style_base].border.w = orig_border_w
		end
	end

	return out:get()
end

-- Finalize code block with re-rendering
local finalize_code_block = function(self)
	local lang = self._code_block_lang
	local lines = self._code_lines

	-- Ensure we have at least one line
	if #lines == 0 then
		lines = { "" }
	end

	-- Calculate how many lines we wrote (need to move cursor back)
	local lines_to_clear = self._code_lines_written

	-- Start synchronized output to prevent tearing
	self._output(SYNC_START)

	-- Move cursor back to start of code block
	if lines_to_clear > 0 then
		term.move("up", lines_to_clear)
	end
	term.move("column", 1)

	-- Clear all the lines we previously wrote
	for _ = 1, lines_to_clear do
		term.clear_line(2)
		term.move("down", 1)
	end

	-- Move back up to render
	if lines_to_clear > 0 then
		term.move("up", lines_to_clear)
	end

	-- Render bordered code block
	local rendered = render_bordered_block(self, lines, lang)
	self._output(rendered)
	-- Add spacing newline after code block
	self._output("\n")

	-- End synchronized output
	self._output(SYNC_END)
	io.flush()
end

-- Render a complete table
local render_table = function(self)
	local tbl = self._table_data
	if not tbl or not tbl.rows or #tbl.rows == 0 then
		return
	end

	-- Calculate column widths
	local col_widths = {}
	for _, row in ipairs(tbl.rows) do
		for i, cell in ipairs(row.cells) do
			local width = std.utf.display_len(cell)
			col_widths[i] = math.max(col_widths[i] or 0, width)
		end
	end

	-- Ensure minimum column width
	for i = 1, #col_widths do
		col_widths[i] = math.max(col_widths[i], 3)
	end

	-- Get border characters from TSS
	local border = self._tss.__style.table and self._tss.__style.table.border or {}
	local b = {
		top_left = border.top_left or "┌",
		top = border.top or "─",
		top_mid = border.top_mid or "┬",
		top_right = border.top_right or "┐",
		left = border.left or "│",
		mid = border.mid or "│",
		right = border.right or "│",
		mid_left = border.mid_left or "├",
		mid_mid = border.mid_mid or "┼",
		mid_right = border.mid_right or "┤",
		bottom_left = border.bottom_left or "└",
		bottom = border.bottom or "─",
		bottom_mid = border.bottom_mid or "┴",
		bottom_right = border.bottom_right or "┘",
	}

	local function styled_border(char)
		return self._tss:apply({ "table.border" }, char).text
	end

	-- Build and output top border
	local top_line = styled_border(b.top_left)
	for i, w in ipairs(col_widths) do
		top_line = top_line .. styled_border(string.rep(b.top, w + 2))
		if i < #col_widths then
			top_line = top_line .. styled_border(b.top_mid)
		end
	end
	top_line = top_line .. styled_border(b.top_right)
	self._output(top_line .. "\n")

	-- Render rows
	for row_idx, row in ipairs(tbl.rows) do
		local row_line = styled_border(b.left)
		for i, cell in ipairs(row.cells) do
			local w = col_widths[i]
			-- TSS alignment takes precedence over markdown column alignment when defined
			local style_key = row.header and "table.header" or "table.cell"
			local cell_props, _ = self._tss:get(style_key)
			local align = cell_props.align or tbl.alignments[i] or "left"

			-- Apply alignment
			local cell_width = std.utf.display_len(cell)
			local padded
			if align == "right" then
				padded = string.rep(" ", w - cell_width) .. cell
			elseif align == "center" then
				local total_pad = w - cell_width
				local left_pad = math.floor(total_pad / 2)
				local right_pad = total_pad - left_pad
				padded = string.rep(" ", left_pad) .. cell .. string.rep(" ", right_pad)
			else -- left
				padded = cell .. string.rep(" ", w - cell_width)
			end

			-- Apply cell style
			local styled_content
			if row.header then
				styled_content = self._tss:apply({ "table.header" }, padded).text
			else
				styled_content = self._tss:apply({ "table.cell" }, padded).text
			end

			row_line = row_line .. " " .. styled_content .. " "
			if i < #col_widths then
				row_line = row_line .. styled_border(b.mid)
			end
		end
		row_line = row_line .. styled_border(b.right)
		self._output(row_line .. "\n")

		-- After header row, add separator
		if row.header and row_idx < #tbl.rows then
			local sep_line = styled_border(b.mid_left)
			for i, w in ipairs(col_widths) do
				sep_line = sep_line .. styled_border(string.rep(b.bottom, w + 2))
				if i < #col_widths then
					sep_line = sep_line .. styled_border(b.mid_mid)
				end
			end
			sep_line = sep_line .. styled_border(b.mid_right)
			self._output(sep_line .. "\n")
		end
	end

	-- Build and output bottom border
	local bottom_line = styled_border(b.bottom_left)
	for i, w in ipairs(col_widths) do
		bottom_line = bottom_line .. styled_border(string.rep(b.bottom, w + 2))
		if i < #col_widths then
			bottom_line = bottom_line .. styled_border(b.bottom_mid)
		end
	end
	bottom_line = bottom_line .. styled_border(b.bottom_right)
	self._output(bottom_line .. "\n\n")
end

-- Handle block start event
local handle_block_start = function(self, tag, attrs)
	attrs = attrs or {}

	if tag == "para" then
		self._in_paragraph = true
		self._inline_stack = {}
		-- Output list marker if this is first block in list item
		if self._in_list_item and self._list_item_first_block then
			output_list_marker(self)
		end
	elseif tag == "heading" then
		self._in_heading = true
		self._heading_level = attrs.level or 1
		self._heading_content = { plain = "", ranges = {} }
		self._inline_stack = {}
	elseif tag == "code_block" then
		self._in_code_block = true
		self._code_block_lang = attrs.lang
		self._code_lines = {}
		self._code_lines_written = 0
	elseif tag == "thematic_break" then
		render_thematic_break(self)
	elseif tag == "list" then
		local list_info = {
			ordered = attrs.ordered,
			start = attrs.start or 1,
			tight = attrs.tight,
			depth = #self._list_stack + 1,
		}
		table.insert(self._list_stack, list_info)
		self._list_item_count[list_info.depth] = 0
	elseif tag == "list_item" then
		local depth = #self._list_stack
		self._list_item_count[depth] = (self._list_item_count[depth] or 0) + 1
		self._in_list_item = true
		self._list_item_depth = depth
		self._list_item_first_block = true
		-- Store task list info
		if attrs.task then
			self._list_item_task = { checked = attrs.checked }
		else
			self._list_item_task = nil
		end
	elseif tag == "table" then
		self._in_table = true
		self._table_data = {
			columns = attrs.columns or 0,
			alignments = {},
			rows = {},
		}
	elseif tag == "table_head" then
		self._in_table_head = true
	elseif tag == "table_body" then
		self._in_table_body = true
	elseif tag == "table_row" then
		self._in_table_row = true
		self._table_row_cells = {}
		self._table_row_header = attrs.header or false
	elseif tag == "table_cell" then
		self._in_table_cell = true
		self._table_cell_content = ""
		-- Record alignment
		if self._table_data and #self._table_row_cells < #self._table_data.alignments + 1 then
			self._table_data.alignments[#self._table_row_cells + 1] = attrs.align or "left"
		end
	elseif tag == "div" then
		-- Fenced div - capture output for re-rendering with borders
		local class = attrs.class or "default"

		-- Determine style base for width calculation
		local style_base = "div." .. class
		if not (self._tss.__style.div and self._tss.__style.div[class] and self._tss.__style.div[class].border) then
			style_base = "div.default"
		end

		-- Get div style properties for width and padding calculation
		local _, div_obj = self._tss:get(style_base)
		local _, default_obj = self._tss:get("div.default")
		local w_value = (div_obj and div_obj.w) or (default_obj and default_obj.w) or 1
		local pad_value = (div_obj and div_obj.pad) or (default_obj and default_obj.pad) or 0

		-- Calculate content width (accounting for borders)
		local available_width = self._width - 2 -- Account for border characters
		local el_width = self._tss:calc_el_width(w_value, available_width)
		if el_width == 0 then
			el_width = available_width
		end

		local captured = buffer.new()
		local div_info = {
			class = class,
			depth = #self._div_stack + 1,
			saved_output = self._output, -- Save current output function
			saved_width = self._width, -- Save original width
			captured = captured, -- Captured content buffer
			lines_written = 0, -- Lines output for re-rendering
			el_width = el_width, -- Store calculated width
			pad = pad_value, -- Store padding for block_end
		}
		table.insert(self._div_stack, div_info)
		-- Replace output function to capture content
		self._output = function(text)
			captured:put(text)
			-- Also output for visual feedback
			div_info.saved_output(text)
			-- Count newlines for cursor movement
			local _, count = text:gsub("\n", "")
			div_info.lines_written = div_info.lines_written + count
		end
		-- Set narrower width for content inside the div (minus padding)
		self._width = el_width - pad_value
		self._in_div = true
	elseif tag == "blockquote" then
		-- Blockquote - capture output for re-rendering with left bar
		local captured = buffer.new()
		local bq_info = {
			depth = #self._blockquote_stack + 1,
			saved_output = self._output, -- Save current output function
			captured = captured, -- Captured content buffer
			lines_written = 0, -- Lines output for re-rendering
		}
		table.insert(self._blockquote_stack, bq_info)
		-- Replace output function to capture content
		self._output = function(text)
			captured:put(text)
			-- Also output for visual feedback
			bq_info.saved_output(text)
			-- Count newlines for cursor movement
			local _, count = text:gsub("\n", "")
			bq_info.lines_written = bq_info.lines_written + count
		end
		self._in_blockquote = true
	end
end

-- Handle block end event
local handle_block_end = function(self, tag)
	if tag == "para" then
		-- End paragraph with newline
		self._output("\n")
		self._in_paragraph = false
		self._inline_stack = {}
		-- Add extra newline after paragraph (but not in tight lists)
		if not self._in_list_item then
			self._output("\n")
			self._previous_block = "para"
		end
		self._line_has_content = false
		io.flush() -- Ensure paragraph is displayed before next block
	elseif tag == "heading" then
		-- Render buffered heading with text-sizing
		render_heading(self)
		self._in_heading = false
		self._heading_level = 0
		self._heading_content = { plain = "", ranges = {} }
		self._inline_stack = {}
		self._line_has_content = false
		self._previous_block = "heading"
		io.flush() -- Ensure heading is displayed before next block
	elseif tag == "code_block" then
		finalize_code_block(self)
		self._in_code_block = false
		self._code_block_lang = nil
		self._code_lines = {}
		self._code_lines_written = 0
		self._line_has_content = false
		self._previous_block = "code_block"
	elseif tag == "list" then
		local depth = #self._list_stack
		self._list_item_count[depth] = nil
		table.remove(self._list_stack)
		-- Update _in_list_item based on remaining stack
		self._in_list_item = (#self._list_stack > 0)
		-- Add newline after list if we're at top level
		if #self._list_stack == 0 then
			self._output("\n")
			self._previous_block = "list"
		end
	elseif tag == "list_item" then
		self._in_list_item = (#self._list_stack > 0)
		self._list_item_depth = #self._list_stack
		self._list_item_first_block = false
		self._list_continuation_indent = ""
		self._list_item_task = nil
	elseif tag == "thematic_break" then
		self._previous_block = "thematic_break"
	elseif tag == "table" then
		render_table(self)
		self._in_table = false
		self._table_data = nil
		self._previous_block = "table"
	elseif tag == "table_head" then
		self._in_table_head = false
	elseif tag == "table_body" then
		self._in_table_body = false
	elseif tag == "table_row" then
		if self._table_data then
			self._table_data.rows[#self._table_data.rows + 1] = {
				cells = self._table_row_cells,
				header = self._table_row_header,
			}
		end
		self._in_table_row = false
		self._table_row_cells = {}
	elseif tag == "table_cell" then
		if self._table_row_cells then
			self._table_row_cells[#self._table_row_cells + 1] = self._table_cell_content
		end
		self._in_table_cell = false
		self._table_cell_content = ""
	elseif tag == "div" then
		-- Finalize div with bordered re-rendering
		if #self._div_stack > 0 then
			local div_info = table.remove(self._div_stack)
			local class = div_info.class or "default"
			local content = div_info.captured:get():gsub("%s+$", "")
			local lines_written = div_info.lines_written

			-- Restore original output function and width
			self._output = div_info.saved_output
			self._width = div_info.saved_width

			-- Split captured content into lines
			local lines = {}
			for line in (content .. "\n"):gmatch("([^\n]*)\n") do
				lines[#lines + 1] = line
			end
			-- Remove trailing empty line if content ended with newline
			if #lines > 0 and lines[#lines] == "" then
				lines[#lines] = nil
			end
			if #lines == 0 then
				lines = { "" }
			end

			-- Start synchronized output
			self._output(SYNC_START)

			-- Move cursor back to start of div
			if lines_written > 0 then
				term.move("up", lines_written)
			end
			term.move("column", 1)

			-- Clear previously written lines
			for _ = 1, lines_written do
				term.clear_line(2)
				term.move("down", 1)
			end
			if lines_written > 0 then
				term.move("up", lines_written)
			end

			-- Render bordered div
			local style_base = "div." .. class
			if not (self._tss.__style.div and self._tss.__style.div[class] and self._tss.__style.div[class].border) then
				style_base = "div.default"
			end

			local div_style = self._tss.__style.div and self._tss.__style.div[class]
			if not div_style then
				div_style = self._tss.__style.div and self._tss.__style.div.default
			end
			local actual_border = (div_style and div_style.border) or DEFAULT_BORDERS

			-- Use pre-calculated width from block_start
			local el_width = div_info.el_width
			local available_width = self._width - 2 -- For alignment calculation

			-- Get alignment from style
			local _, div_obj = self._tss:get(style_base)
			local _, default_obj = self._tss:get("div.default")
			local align_value = (div_obj and div_obj.align) or (default_obj and default_obj.align) or "none"

			-- Calculate alignment padding
			local align = align_value
			local align_pad = ""
			if el_width < available_width then
				if align == "center" then
					align_pad = string.rep(" ", math.floor((available_width - el_width) / 2))
				elseif align == "right" then
					align_pad = string.rep(" ", available_width - el_width)
				end
			end

			-- Build top line with label
			local label = class ~= "default" and class or nil
			local top_line
			if label then
				local styled_label = self._tss:apply(style_base .. ".label", label)
				local label_len = styled_label.width
				local st = self._tss:apply(
					style_base .. ".border",
					actual_border.top_line.before .. actual_border.top_line.content
				).text
				st = st .. styled_label.text
				st = st
					.. self._tss:apply(
						style_base .. ".border",
						string.rep(actual_border.top_line.content, math.max(el_width - label_len - 1, 0))
							.. actual_border.top_line.after
					).text
				top_line = st
			else
				local line_content = actual_border.top_line.before
					.. string.rep(actual_border.top_line.content, el_width)
					.. actual_border.top_line.after
				top_line = self._tss:apply(style_base .. ".border", line_content).text
			end

			self._output(align_pad .. top_line .. "\n")

			-- Output content with borders
			local left_border = self._tss:apply(style_base .. ".border.v").text
			local right_border = self._tss:apply(style_base .. ".border.v").text
			local content_pad = div_info.pad or 0
			local pad_str = string.rep(" ", content_pad)
			local inner_width = el_width - content_pad

			for i, line in ipairs(lines) do
				local is_last = (i == #lines)
				local is_empty = (line == "" or line:match("^%s*$"))
				if not (is_last and is_empty) then
					local visual_len = std.utf.display_len(line)
					local padding = math.max(0, inner_width - visual_len)
					local padded = line .. string.rep(" ", padding)
					self._output(align_pad .. left_border .. pad_str .. padded .. right_border .. "\n")
				end
			end

			-- Output bottom border
			local bottom_line = actual_border.bottom_line.before
				.. string.rep(actual_border.bottom_line.content, el_width)
				.. actual_border.bottom_line.after
			self._output(align_pad .. self._tss:apply(style_base .. ".border", bottom_line).text .. "\n\n")

			self._output(SYNC_END)
			io.flush()

			self._in_div = (#self._div_stack > 0)
			self._previous_block = "div"
		end
	elseif tag == "blockquote" then
		-- Finalize blockquote with left bar re-rendering
		if #self._blockquote_stack > 0 then
			local bq_info = table.remove(self._blockquote_stack)
			local content = bq_info.captured:get()
			local lines_written = bq_info.lines_written

			-- Restore original output function
			self._output = bq_info.saved_output

			-- Split captured content into lines
			local lines = {}
			for line in (content .. "\n"):gmatch("([^\n]*)\n") do
				lines[#lines + 1] = line
			end
			-- Remove trailing empty line
			if #lines > 0 and lines[#lines] == "" then
				lines[#lines] = nil
			end

			-- Start synchronized output
			self._output(SYNC_START)

			-- Move cursor back
			if lines_written > 0 then
				term.move("up", lines_written)
			end
			term.move("column", 1)

			-- Clear previously written lines
			for _ = 1, lines_written do
				term.clear_line(2)
				term.move("down", 1)
			end
			if lines_written > 0 then
				term.move("up", lines_written)
			end

			-- Render with left bar
			local bar_style = self._tss.__style.blockquote and self._tss.__style.blockquote.bar
			local bar_char = bar_style and bar_style.content or "┃ "
			local styled_bar = self._tss:apply({ "blockquote.bar" }, bar_char).text

			for _, line in ipairs(lines) do
				self._output(styled_bar .. line .. "\n")
			end
			self._output("\n")

			self._output(SYNC_END)
			io.flush()

			self._in_blockquote = (#self._blockquote_stack > 0)
			self._previous_block = "blockquote"
		end
	end
end

-- Handle inline start event
local handle_inline_start = function(self, tag, attrs)
	attrs = attrs or {}

	-- For headings, record start position for range tracking
	local start_pos = nil
	if self._in_heading then
		start_pos = get_heading_pos(self) + 1
	end

	-- Push style context onto stack
	local style_info = {
		tag = tag,
		attrs = attrs,
		start_pos = start_pos, -- Only set for headings
	}
	self._inline_stack[#self._inline_stack + 1] = style_info
end

-- Handle inline end event
local handle_inline_end = function(self, tag)
	-- Pop from stack
	local style_info = nil
	for i = #self._inline_stack, 1, -1 do
		if self._inline_stack[i].tag == tag then
			style_info = self._inline_stack[i]
			table.remove(self._inline_stack, i)
			break
		end
	end

	if not style_info then
		return
	end

	if self._in_heading then
		-- For headings: record style range (rendered at block_end)
		local content = self._heading_content
		local stop_pos = get_heading_pos(self)

		if stop_pos >= (style_info.start_pos or 0) then
			local elements = {}
			if tag == "strong" or tag == "emph" or tag == "strikethrough" then
				elements = { tag }
			elseif tag == "code" then
				elements = { "code" } -- Base style first
				if style_info.attrs and style_info.attrs.class then
					-- Support multiple space-separated classes
					for class in style_info.attrs.class:gmatch("%S+") do
						elements[#elements + 1] = "code." .. class
					end
				end
			elseif tag == "link" then
				elements = { "link.title" }
			elseif tag == "image" then
				elements = { "image.alt" }
			end

			if #elements > 0 then
				table.insert(content.ranges, {
					start = style_info.start_pos,
					stop = stop_pos,
					elements = elements,
				})
			end
		end

		-- For links/images in headings, append URL to buffer
		if tag == "link" or tag == "image" then
			local url = style_info.attrs and style_info.attrs.href
			if url then
				local url_start = std.utf.len(content.plain) + 1
				content.plain = content.plain .. url
				local url_stop = std.utf.len(content.plain)
				table.insert(content.ranges, {
					start = url_start,
					stop = url_stop,
					elements = { tag .. ".url" },
				})
			end
		end
	else
		-- For paragraphs: output URL immediately
		if tag == "link" or tag == "image" then
			local url = style_info.attrs and style_info.attrs.href
			if url then
				local url_style = tag .. ".url"
				local styled_url = self._tss:apply(url_style, url).text
				self._output(styled_url)
			end
		end
	end
end

-- Handle text event
local handle_text = function(self, text)
	if not text or text == "" then
		return
	end

	if self._in_code_block then
		-- Buffer code block text
		for line in (text .. "\n"):gmatch("([^\n]*)\n") do
			self._code_lines[#self._code_lines + 1] = line
		end
		if #self._code_lines > 0 and self._code_lines[#self._code_lines] == "" then
			self._code_lines[#self._code_lines] = nil
		end

		-- Output raw text immediately for visual feedback
		self._output(text)
		local _, count = text:gsub("\n", "")
		self._code_lines_written = self._code_lines_written + count
	elseif self._in_table_cell then
		-- Buffer table cell text (rendered when table is complete)
		self._table_cell_content = self._table_cell_content .. text
	elseif self._in_heading then
		-- Buffer heading text (rendered at block_end with text-sizing)
		self._heading_content.plain = self._heading_content.plain .. text
	else
		-- Paragraph: apply inline styles and output immediately
		local styled_text = apply_current_styles(self, text)
		self._output(styled_text)
		self._line_has_content = true
	end
end

-- Handle softbreak event
local handle_softbreak = function(self)
	if self._in_heading then
		-- Buffer space for heading
		self._heading_content.plain = self._heading_content.plain .. " "
	else
		-- Output space for paragraph
		self._output(" ")
	end
end

-- Process a single event
local render_event = function(self, event)
	local t = event.type

	if t == "block_start" then
		handle_block_start(self, event.tag, event.attrs)
	elseif t == "block_end" then
		handle_block_end(self, event.tag)
	elseif t == "inline_start" then
		handle_inline_start(self, event.tag, event.attrs)
	elseif t == "inline_end" then
		handle_inline_end(self, event.tag)
	elseif t == "text" then
		handle_text(self, event.text)
	elseif t == "softbreak" then
		handle_softbreak(self)
	end
end

-- Finalize and flush any pending output
local finish = function(self)
	io.flush()
end

-- Reset renderer state for reuse
local reset = function(self)
	self._inline_stack = {}
	self._in_code_block = false
	self._code_block_lang = nil
	self._code_lines = {}
	self._code_lines_written = 0
	self._in_paragraph = false
	self._in_heading = false
	self._heading_level = 0
	self._heading_content = { plain = "", ranges = {} }
	self._list_stack = {}
	self._list_item_count = {}
	self._in_list_item = false
	self._list_item_depth = 0
	self._list_item_first_block = false
	self._list_continuation_indent = ""
	self._list_item_task = nil
	self._in_table = false
	self._table_data = nil
	self._in_table_head = false
	self._in_table_body = false
	self._in_table_row = false
	self._table_row_cells = {}
	self._table_row_header = false
	self._in_table_cell = false
	self._table_cell_content = ""
	self._line_has_content = false
	self._previous_block = nil
	-- Div and blockquote state
	self._div_stack = {}
	self._in_div = false
	self._blockquote_stack = {}
	self._in_blockquote = false
end

-- Create a new streaming renderer instance
local new = function(options)
	options = options or {}

	-- Create TSS instance
	local rss = options.tss or DEFAULT_RSS
	local tss = tss_mod.merge(DEFAULT_RSS, rss)
	-- Override TSS window width to match content width so all width/alignment
	-- calculations (especially in apply()) use content width, not terminal width
	tss.__window.w = options.width or 80

	local renderer = {
		-- Configuration
		_width = options.width or 80,
		_output = options.output_fn or io.write,

		-- TSS instance
		_tss = tss,

		-- Inline state - stack of active styles
		-- Each entry: { tag, attrs }
		_inline_stack = {},

		-- Code block state
		_in_code_block = false,
		_code_block_lang = nil,
		_code_lines = {},
		_code_lines_written = 0,

		-- Block tracking
		_in_paragraph = false,
		_in_heading = false,
		_heading_level = 0,
		-- Heading content buffer (for text-sizing at block_end)
		_heading_content = { plain = "", ranges = {} },

		-- List state
		_list_stack = {},
		_list_item_count = {},
		_in_list_item = false,
		_list_item_depth = 0,
		_list_item_first_block = false,
		_list_continuation_indent = "",
		_list_item_task = nil,

		-- Table state (GFM)
		_in_table = false,
		_table_data = nil,
		_in_table_head = false,
		_in_table_body = false,
		_in_table_row = false,
		_table_row_cells = {},
		_table_row_header = false,
		_in_table_cell = false,
		_table_cell_content = "",

		-- Track if we've output anything on current line
		_line_has_content = false,

		-- Block spacing state (tracks last completed block for newline insertion)
		_previous_block = nil,

		-- Div state
		_div_stack = {},
		_in_div = false,

		-- Blockquote state
		_blockquote_stack = {},
		_in_blockquote = false,

		-- Methods
		render_event = render_event,
		finish = finish,
		reset = reset,
	}

	return renderer
end

-- Module export
return {
	new = new,
}
