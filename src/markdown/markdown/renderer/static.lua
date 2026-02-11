-- SPDX-FileCopyrightText: © 2022—2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: LicenseRef-OWL-1.0-or-later OR GPL-3.0-or-later
-- Dual-licensed under OWL v1.0+ and GPLv3+. See LICENSE and LICENSE-GPL3.

--[[
Static terminal renderer for markdown.

Consumes parser events and produces styled terminal output using TSS.
This renderer buffers all content and renders complete documents,
suitable for pager display and non-streaming use cases.

Usage:
    local static = require("markdown.renderer.static")
    local renderer = static.new({ width = 80, rss = custom_rss })

    -- Feed events from parser
    renderer:render_event({ type = "block_start", tag = "para" })
    renderer:render_event({ type = "text", text = "Hello" })
    renderer:render_event({ type = "block_end", tag = "para" })

    -- Get final output
    local output = renderer:finish()
]]

local std = require("std")
local buffer = require("string.buffer")
local tss_mod = require("term.tss")
local theme_mod = require("theme")
local theme = require("markdown.renderer.theme")
local table_layout = require("markdown.renderer.table_layout")

local DEFAULT_BORDERS = theme.DEFAULT_BORDERS
local DEFAULT_RSS = theme.DEFAULT_RSS
local PARAGRAPH_NO_CLIP_RSS = theme.PARAGRAPH_NO_CLIP_RSS

-- Count newlines in text for line tracking
local count_newlines = function(text)
	local count = 0
	for _ in text:gmatch("\n") do
		count = count + 1
	end
	return count
end

local get_block_indent = function(tss, style_key)
	if not style_key then
		return 0
	end
	local props = tss:get(style_key)
	local block_indent = props and props.block_indent or 0
	if type(block_indent) ~= "number" then
		return 0
	end
	return math.max(0, math.floor(block_indent))
end

local get_list_indent_per_level = function(tss)
	local _, list_obj = tss:get("list")
	local indent_per_level = list_obj and list_obj.indent_per_level or 4
	if type(indent_per_level) ~= "number" then
		return 4
	end
	return math.max(0, math.floor(indent_per_level))
end

local expand_tabs = function(line, tabstop)
	line = line or ""
	tabstop = tabstop or 4
	return (line:gsub("\t", string.rep(" ", tabstop)))
end

local clamp_display_width = function(text, width)
	if width <= 0 then
		return ""
	end
	if std.utf.display_len(text) <= width then
		return text
	end
	return std.txt.limit(text, width, width)
end

-- Helper: render pre-styled content with borders (for divs)
-- Unlike render_bordered_block, this takes already-rendered content with ANSI codes
local render_bordered_content = function(tss, style_base, content, width, label, indent, pad)
	indent = indent or 0
	pad = pad or 0
	local out = buffer.new()
	local indent_str = string.rep(" ", indent)
	local pad_str = string.rep(" ", pad)

	-- Get border definition
	local border_def = tss:get_property(style_base, "border") or DEFAULT_BORDERS

	-- Split content into logical lines.
	local lines = {}
	for line in (content .. "\n"):gmatch("([^\n]*)\n") do
		lines[#lines + 1] = line
	end

	-- Keep configured width fixed for bordered elements.
	local width = math.max(1, math.floor(width or 1))

	-- Build top line with optional label
	local top_line
	if label and label ~= "" then
		-- Style the label first
		local label_style = style_base .. ".label"
		local styled_label = tss:apply(label_style, label)
		local label_len = styled_label.width

		-- Calculate fill width: total = before(1) + content(1) + label + fill + after(1) = width + 2
		-- So fill = width - label_len - 1 (we add 1 content char before label)
		local fill_count = math.max(width - label_len - 1, 0)

		-- Build complete top line: ╭─ label ────╮
		-- Style border chars separately from label to preserve label styling
		local before_label =
			tss:apply(style_base .. ".border", border_def.top_line.before .. border_def.top_line.content).text
		local after_label = tss:apply(
			style_base .. ".border",
			string.rep(border_def.top_line.content, fill_count) .. border_def.top_line.after
		).text
		top_line = before_label .. styled_label.text .. after_label
	else
		-- Build top line without label
		local line_content = border_def.top_line.before
			.. string.rep(border_def.top_line.content, width)
			.. border_def.top_line.after
		top_line = tss:apply(style_base .. ".border", line_content).text
	end

	-- Output top border
	out:put(indent_str, top_line, "\n")

	-- Get border characters
	local left_border = tss:apply(style_base .. ".border.v").text
	local right_border = tss:apply(style_base .. ".border.v").text

	-- Calculate inner width (width minus padding)
	local inner_width = math.max(0, width - pad)
	local blank_inner = string.rep(" ", inner_width)

	for i, line in ipairs(lines) do
		-- Skip trailing empty line produced by content capture.
		local is_last = (i == #lines)
		local is_empty = (line == "" or line:match("^%s*$"))
		if not (is_last and is_empty) then
			if is_empty then
				out:put(indent_str, left_border, pad_str, blank_inner, right_border, "\n")
			else
				local clipped_line = clamp_display_width(line, inner_width)
				local visual_len = std.utf.cell_len(clipped_line)
				local padding = math.max(0, inner_width - visual_len)
				local padded = clipped_line .. string.rep(" ", padding)

				out:put(indent_str, left_border, pad_str, padded, right_border, "\n")
			end
		end
	end

	-- Output bottom border
	local bottom_line = border_def.bottom_line.before
		.. string.rep(border_def.bottom_line.content, width)
		.. border_def.bottom_line.after
	out:put(indent_str, tss:apply(style_base .. ".border", bottom_line).text, "\n")

	return out:get()
end

-- Helper: render a bordered block (code blocks)
-- Adapted from text.lua render_bordered_block pattern
local render_bordered_block = function(tss, style_base, lines, width, label, indent, pad)
	indent = indent or 0
	pad = pad or 0
	local out = buffer.new()
	local indent_str = string.rep(" ", indent)
	local pad_str = string.rep(" ", pad)
	local inner_width = width - pad
	local style_props, _ = tss:get(style_base)
	local content_align = style_props and style_props.align or "none"
	if content_align == "none" then
		content_align = "left"
	end

	local border_tss = tss:scope({
		[style_base] = {
			w = width,
			border = { w = width },
		},
	})
	local content_tss = tss:scope({
		[style_base] = {
			w = inner_width,
			align = content_align,
			border = { w = width },
		},
	})

	-- Build top line
	local border_def = border_tss:get_property(style_base, "border") or DEFAULT_BORDERS
	local top_line

	if label and label ~= "" then
		-- Build top line with label
		local styled_label = border_tss:apply(style_base .. ".lang", label)
		local label_len = styled_label.width

		local st =
			border_tss:apply(style_base .. ".border", border_def.top_line.before .. border_def.top_line.content).text
		st = st
			.. styled_label.text
			.. border_tss:apply(
				style_base .. ".border",
				string.rep(border_def.top_line.content, math.max(width - label_len - 1, 0)) .. border_def.top_line.after
			).text
		top_line = st
	else
		top_line = border_tss:apply(style_base .. ".border.top_line").text
	end

	-- Output top border
	out:put(indent_str, top_line, "\n")

	-- Output content lines with vertical borders
	for i, l in ipairs(lines) do
		-- Skip empty trailing lines
		local is_last = (i == #lines)
		local is_empty = (l == "" or l:match("^%s*$"))
		if not (is_last and is_empty) then
			out:put(
				indent_str,
				content_tss:apply(style_base .. ".border.v").text,
				pad_str,
				content_tss:apply(style_base, l).text,
				content_tss:apply(style_base .. ".border.v").text,
				"\n"
			)
		end
	end

	-- Output bottom border
	out:put(indent_str, border_tss:apply(style_base .. ".border.bottom_line").text, "\n")

	return out:get()
end

-- Get the current content buffer based on block type
local get_current_content = function(self)
	if self.__state.in_table_cell then
		return self.__state.table_cell_content
	elseif self.__state.in_heading then
		return self.__state.heading_content
	elseif self.__state.in_footnote then
		return self.__state.footnote_content
	elseif self.__state.in_paragraph then
		return self.__state.paragraph_content
	end
	return nil
end

-- Get current position in the plain text buffer
local get_current_pos = function(self)
	local content = get_current_content(self)
	if content then
		return std.utf.len(content.plain)
	end
	return 0
end

-- Apply current inline style stack to text (used for non-sized content like paragraphs)
local apply_inline_styles = function(self, text)
	if #self.__state.inline_stack == 0 then
		return text
	end

	-- Build list of style elements from stack
	local elements = {}
	for _, style_info in ipairs(self.__state.inline_stack) do
		local tag = style_info.tag
		if tag == "strong" or tag == "emph" or tag == "code" or tag == "strikethrough" then
			elements[#elements + 1] = tag
		elseif tag == "link" then
			elements[#elements + 1] = "link.title"
		elseif tag == "image" then
			elements[#elements + 1] = "image.alt"
		end
	end

	if #elements == 0 then
		return text
	end

	return self.__state.tss:apply(elements, text).text
end

-- Build styled text from content buffer (for non-text-sized blocks)
local build_styled_text = function(self, content, base_elements)
	local plain = content.plain
	local ranges = content.ranges
	local plain_len = std.utf.len(plain)

	if plain_len == 0 then
		return ""
	end

	-- Sort ranges by start position
	table.sort(ranges, function(a, b)
		return a.start < b.start
	end)

	-- Get base style
	local base_props, _ = self.__state.tss:get(base_elements[1])
	for i = 2, #base_elements do
		base_props, _ = self.__state.tss:get(base_elements[i], base_props)
	end

	-- Build styled text
	local result = {}
	local pos = 1

	-- Helper to apply style to text
	local style_tss = self.__state.paragraph_tss or self.__state.tss
	local function apply_style(text, elements)
		if not elements or #elements == 0 then
			return text
		end
		return style_tss:apply(elements, text).text
	end

	-- Process character by character, tracking active ranges
	while pos <= plain_len do
		-- Find ranges active at this position
		local active_elements = {}
		for _, r in ipairs(ranges) do
			if pos >= r.start and pos <= r.stop then
				for _, el in ipairs(r.elements) do
					table.insert(active_elements, el)
				end
			end
		end

		-- Find how far we can go with the same active elements
		local end_pos = plain_len
		for _, r in ipairs(ranges) do
			if r.start > pos and r.start <= end_pos then
				end_pos = r.start - 1
			end
			if r.stop >= pos and r.stop < end_pos then
				end_pos = r.stop
			end
		end

		-- Extract substring and apply styles
		local substr = std.utf.sub(plain, pos, end_pos)
		if #active_elements > 0 then
			table.insert(result, apply_style(substr, active_elements))
		else
			table.insert(result, substr)
		end

		pos = end_pos + 1
	end

	return table.concat(result)
end

-- Render paragraph
local render_paragraph = function(self)
	local content = self.__state.paragraph_content
	if content.plain == "" then
		return
	end

	-- Record start line for pending element resolution
	local para_start_line = self.__state.current_line

	-- Handle list item markers
	local marker_text = ""
	local marker_width = 0
	local continuation_indent = ""

	if self.__state.in_list_item and #self.__state.list_stack > 0 then
		local depth = self.__state.list_item_depth
		local list = self.__state.list_stack[depth]
		if list then
			local item_count = self.__state.list_item_count[depth] or 1
			-- For ordered lists, add start offset to get actual number (e.g., start=5, count=1 -> num=5)
			local item_num = list.ordered and (list.start + item_count - 1) or item_count

			-- Build base indent for nesting (configured spaces per level, starting at level 2)
			local list_block_indent = get_block_indent(self.__state.tss, "list_item")
			local indent_per_level = get_list_indent_per_level(self.__state.tss)
			local raw_base_indent = string.rep(" ", indent_per_level * (depth - 1))
			local base_indent = string.rep(" ", list_block_indent) .. raw_base_indent

			if self.__state.list_item_first_block then
				-- First block gets the marker
				if list.ordered then
					-- Ordered: format number, apply style
					local num_str = string.format("%d. ", item_num)
					local styled = self.__state.tss:apply("list_item.ol", num_str)
					marker_text = base_indent .. styled.text
					marker_width = list_block_indent + #raw_base_indent + std.utf.display_len(num_str)
				elseif self.__state.list_item_task then
					-- Task list: render checkbox
					local checkbox_style = self.__state.list_item_task.checked and "task_list.checked"
						or "task_list.unchecked"
					local styled = self.__state.tss:apply(checkbox_style)
					marker_text = base_indent .. styled.text
					-- Get display width of the checkbox content
					local _, obj = self.__state.tss:get(checkbox_style)
					local checkbox_content = obj.content or (self.__state.list_item_task.checked and "☑ " or "☐ ")
					marker_width = list_block_indent + #raw_base_indent + std.utf.display_len(checkbox_content)
				else
					-- Unordered: get marker from TSS (uses content property)
					local styled = self.__state.tss:apply("list_item.ul")
					marker_text = base_indent .. styled.text
					-- Get display width of the content (bullet + space)
					local _, obj = self.__state.tss:get("list_item.ul")
					local marker_content = obj.content or "- "
					marker_width = list_block_indent + #raw_base_indent + std.utf.display_len(marker_content)
				end

				self.__state.list_item_first_block = false
				-- Store continuation indent for subsequent blocks and wrapped lines
				continuation_indent = string.rep(" ", marker_width)
				self.__state.list_continuation_indent = continuation_indent
			else
				-- Subsequent blocks in same item get continuation indent
				continuation_indent = self.__state.list_continuation_indent
				marker_text = continuation_indent
				marker_width = #continuation_indent
			end
		end
	end

	-- Check if base paragraph style has text-sizing
	local para_props, _ = self.__state.tss:get("para")
	local has_ts = para_props and para_props.ts
	local lines_output = 0

	if has_ts then
		-- Use apply_sized for proper text-sizing with inline styles
		local result = self.__state.tss:apply_sized({ "para" }, content)
		local extra_lines = result.height - 1
		self.__state.output:put(marker_text, result.text, "\n", string.rep("\n", extra_lines), "\n")
		lines_output = 1 + extra_lines + 1 -- text line + extra + trailing newline
	else
		-- No text-sizing - use traditional approach with pre-styled content
		-- Apply styles to each range and build final text
		local styled_text = build_styled_text(self, content, { "para" })

		-- Calculate available width for content (account for marker/indent)
		local available_width = self.__state.width - marker_width
		if available_width < 20 then
			available_width = 20 -- Minimum reasonable width
		end

		-- Wrap text at available width
		local wrapped = std.txt.lines_of(styled_text, available_width, false, true)

		-- Output first line with marker, rest with continuation indent
		if #wrapped > 0 then
			self.__state.output:put(marker_text, wrapped[1], "\n")
			for i = 2, #wrapped do
				self.__state.output:put(continuation_indent, wrapped[i], "\n")
			end
			lines_output = #wrapped
		end

		-- Add extra newline after paragraph (but not for tight lists)
		-- For now, always add it - tight/loose handling can be refined later
		if not self.__state.in_list_item then
			self.__state.output:put("\n")
			lines_output = lines_output + 1
		end
	end

	-- Resolve pending links - associate them with the paragraph start line
	-- (Since tracking exact positions within wrapped text is complex,
	-- we just track the line where the link appears)
	if self.__state.pending_links then
		for _, link_info in ipairs(self.__state.pending_links) do
			self.__state.elements.links[#self.__state.elements.links + 1] = {
				line = para_start_line, -- Simplified: all links in para on start line
				url = link_info.url,
				title = link_info.title,
			}
		end
		self.__state.pending_links = nil
	end

	-- Resolve pending footnote refs
	if self.__state.pending_footnote_refs then
		for _, fn_info in ipairs(self.__state.pending_footnote_refs) do
			self.__state.elements.footnote_refs[#self.__state.elements.footnote_refs + 1] = {
				line = para_start_line,
				label = fn_info.label,
			}
		end
		self.__state.pending_footnote_refs = nil
	end

	-- Update current line
	self.__state.current_line = self.__state.current_line + lines_output
end

-- Render heading
local render_heading = function(self)
	local content = self.__state.heading_content
	local level = self.__state.heading_level

	if content.plain == "" then
		return
	end

	-- Track header for pager navigation
	self.__state.elements.headers[#self.__state.elements.headers + 1] = {
		line = self.__state.current_line,
		level = level,
		text = content.plain,
	}

	-- Apply level-specific style to content using apply_sized
	-- This properly handles inline styles within text-sized headings
	local level_key = "h" .. tostring(level)
	local result = self.__state.tss:apply_sized({ "heading", "heading." .. level_key }, content)

	-- When text-sizing is used with scale > 1, the scaled text occupies multiple
	-- terminal rows, but the cursor remains on the original row. We need to add
	-- extra newlines to move past the full height of the scaled content.
	local extra_lines = result.height - 1
	self.__state.output:put(result.text, "\n", string.rep("\n", extra_lines), "\n")

	-- Update current line (text + extra + 1 trailing newline)
	self.__state.current_line = self.__state.current_line + 1 + extra_lines + 1
end

-- Render code block
local render_code_block = function(self)
	local lang = self.__state.code_block_lang
	local lines = self.__state.code_block_lines
	local raw_content = table.concat(lines, "\n")

	-- Record start line BEFORE rendering
	local start_line = self.__state.current_line

	-- Ensure we have at least one line
	if #lines == 0 then
		lines = { "" }
	end

	-- Handle list item indentation
	local indent = 0
	if self.__state.in_list_item and #self.__state.list_stack > 0 then
		local depth = self.__state.list_item_depth
		local list = self.__state.list_stack[depth]
		if list then
			if self.__state.list_item_first_block then
				-- First block: calculate continuation indent like paragraphs do
				local item_count = self.__state.list_item_count[depth] or 1
				local item_num = list.ordered and (list.start + item_count - 1) or item_count
				local list_block_indent = get_block_indent(self.__state.tss, "list_item")
				local indent_per_level = get_list_indent_per_level(self.__state.tss)
				local raw_base_indent = string.rep(" ", indent_per_level * (depth - 1))
				local marker_width
				if list.ordered then
					marker_width = list_block_indent + #raw_base_indent + #string.format("%d. ", item_num)
				elseif self.__state.list_item_task then
					local _, obj = self.__state.tss:get(
						self.__state.list_item_task.checked and "task_list.checked" or "task_list.unchecked"
					)
					local checkbox_content = obj.content or (self.__state.list_item_task.checked and "☑ " or "☐ ")
					marker_width = list_block_indent + #raw_base_indent + std.utf.display_len(checkbox_content)
				else
					local _, obj = self.__state.tss:get("list_item.ul")
					local marker_content = obj.content or "- "
					marker_width = list_block_indent + #raw_base_indent + std.utf.display_len(marker_content)
				end
				indent = marker_width
				self.__state.list_continuation_indent = string.rep(" ", marker_width)
				self.__state.list_item_first_block = false
			else
				-- Subsequent blocks use stored continuation indent
				indent = #self.__state.list_continuation_indent
			end
		end
	end
	indent = indent + get_block_indent(self.__state.tss, "code_block")

	-- Calculate inner block width (without left/right border glyphs)
	local block_width = self.__state.width - indent - 2
	if #self.__state.div_stack > 0 then
		block_width = block_width - 2
	end
	block_width = math.max(1, block_width)

	-- Get padding from TSS
	local _, code_obj = self.__state.tss:get("code_block")
	local pad_value = (code_obj and code_obj.pad) or 0

	-- Normalize tabs for stable terminal cell width accounting in bordered blocks
	local render_lines = {}
	for i, line in ipairs(lines) do
		render_lines[i] = expand_tabs(line, 4)
	end

	-- Render bordered block
	local rendered =
		render_bordered_block(self.__state.tss, "code_block", render_lines, block_width, lang, indent, pad_value)

	-- Track element position
	local lines_in_block = count_newlines(rendered)
	-- Add extra newline for spacing (but not inside lists, matching paragraph behavior)
	if not self.__state.in_list_item then
		lines_in_block = lines_in_block + 1
	end
	local end_line = start_line + lines_in_block - 1
	self.__state.elements.code_blocks[#self.__state.elements.code_blocks + 1] = {
		start_line = start_line,
		end_line = end_line,
		raw = raw_content,
		lang = lang,
	}

	self.__state.output:put(rendered)
	if not self.__state.in_list_item then
		self.__state.output:put("\n")
	end

	-- Update current line
	self.__state.current_line = self.__state.current_line + lines_in_block
end

-- Render thematic break
local render_thematic_break = function(self)
	-- Get thematic break style properties
	local props, obj = self.__state.tss:get("thematic_break")

	-- Calculate element width (respects w = 0.5 for 50% width)
	local el_width = self.__state.tss:calc_el_width(obj.w or 1, self.__state.width)
	if el_width == 0 then
		el_width = self.__state.width
	end

	-- Thematic break pattern comes from thematic_break.content.
	-- Width expansion is handled by core TSS fill semantics (fill = true).
	local base_content = obj.content or "─"

	-- Apply styling (TSS won't add alignment padding since layout width equals content width,
	-- making effective_w = el_width, so there's no room for TSS to add padding)
	local styled = self.__state.tss:apply("thematic_break", base_content).text

	-- Manual alignment to center element within the content area
	local align = props.align or "none"
	local left_pad = ""
	if align == "center" then
		left_pad = string.rep(" ", math.floor((self.__state.width - el_width) / 2))
	elseif align == "right" then
		left_pad = string.rep(" ", self.__state.width - el_width)
	end

	self.__state.output:put(left_pad, styled, "\n\n")

	-- Update current line (1 content line + 1 empty line)
	self.__state.current_line = self.__state.current_line + 2
end

-- Render a complete table
local render_table = function(self)
	local tbl = self.__state.table_data
	if not tbl or not tbl.rows or #tbl.rows == 0 then
		return
	end
	local table_start_line = tbl.start_line or self.__state.current_line
	local table_block_indent = get_block_indent(self.__state.tss, "table")
	local table_indent_str = string.rep(" ", table_block_indent)
	local table_available_width = math.max(1, self.__state.width - table_block_indent)
	local overflow_mode = table_layout.normalize_overflow(self.__state.tss:get_property("table", "overflow"))

	-- Pre-calculate styled content for width fitting.
	local styled_rows = {}
	for row_idx, row in ipairs(tbl.rows) do
		local base_style = row.header and { "table.header" } or { "table.cell" }
		local styled_cells = {}
		for i, cell in ipairs(row.cells) do
			local styled_text
			if cell.ranges and #cell.ranges > 0 then
				-- Has inline styles - use build_styled_text
				styled_text = build_styled_text(self, cell, base_style)
			else
				-- No inline styles - just apply base style
				styled_text = self.__state.tss:apply(base_style, cell.plain).text
			end
			styled_cells[i] = {
				text = styled_text,
				width = std.utf.cell_len(styled_text), -- Handles ANSI + OSC 66
			}
		end
		styled_rows[row_idx] = {
			cells = styled_cells,
			header = row.header,
		}
	end

	-- Calculate column widths from styled content
	local col_widths = {}
	for _, row in ipairs(styled_rows) do
		for i, cell in ipairs(row.cells) do
			col_widths[i] = math.max(col_widths[i] or 0, cell.width)
		end
	end

	col_widths = table_layout.fit_table_width(col_widths, table_available_width)

	-- Get border characters from TSS
	local border = self.__state.tss:get_property("table", "border") or {}
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
		return self.__state.tss:apply({ "table.border" }, char).text
	end

	-- Build top border: ┌───┬───┬───┐
	local top_line = styled_border(b.top_left)
	for i, w in ipairs(col_widths) do
		top_line = top_line .. styled_border(string.rep(b.top, w + 2))
		if i < #col_widths then
			top_line = top_line .. styled_border(b.top_mid)
		end
	end
	top_line = top_line .. styled_border(b.top_right)
	top_line = clamp_display_width(top_line, table_available_width)
	self.__state.output:put(table_indent_str, top_line, "\n")

	local lines_count = 1 -- top border

	if overflow_mode == "clip" then
		for row_idx, row in ipairs(styled_rows) do
			local base_style = row.header and { "table.header" } or { "table.cell" }
			local row_line = styled_border(b.left)
			for i, cell in ipairs(row.cells) do
				local w = col_widths[i]
				local style_key = row.header and "table.header" or "table.cell"
				local cell_props, _ = self.__state.tss:get(style_key)
				local align = cell_props.align or tbl.alignments[i] or "left"

				local cell_text = cell.text
				local cell_width = cell.width
				if cell_width > w then
					cell_text = clamp_display_width(cell_text, w)
					cell_width = std.utf.cell_len(cell_text)
				end

				local pad_left, pad_right = table_layout.compute_padding(align, w, cell_width)
				local left_pad = pad_left > 0 and self.__state.tss:apply(base_style, string.rep(" ", pad_left)).text
					or ""
				local right_pad = pad_right > 0 and self.__state.tss:apply(base_style, string.rep(" ", pad_right)).text
					or ""

				row_line = row_line .. " " .. left_pad .. cell_text .. right_pad .. " "
				if i < #col_widths then
					row_line = row_line .. styled_border(b.mid)
				end
			end
			row_line = row_line .. styled_border(b.right)
			row_line = clamp_display_width(row_line, table_available_width)
			self.__state.output:put(table_indent_str, row_line, "\n")
			lines_count = lines_count + 1

			if row.header and row_idx < #styled_rows then
				local sep_line = styled_border(b.mid_left)
				for i, w in ipairs(col_widths) do
					sep_line = sep_line .. styled_border(string.rep(b.bottom, w + 2))
					if i < #col_widths then
						sep_line = sep_line .. styled_border(b.mid_mid)
					end
				end
				sep_line = sep_line .. styled_border(b.mid_right)
				sep_line = clamp_display_width(sep_line, table_available_width)
				self.__state.output:put(table_indent_str, sep_line, "\n")
				lines_count = lines_count + 1
			end
		end
	else
		local function style_wrapped_cell_line(content, parts, base_style)
			if not parts or #parts == 0 then
				return "", 0
			end

			local line_content = { plain = "", ranges = {} }
			local plain_parts = {}
			for i, part in ipairs(parts) do
				plain_parts[i] = part.text
			end
			line_content.plain = table.concat(plain_parts)

			if content.ranges and #content.ranges > 0 then
				local line_pos = 1
				for _, part in ipairs(parts) do
					local part_len = std.utf.len(part.text)
					if part_len > 0 then
						for _, r in ipairs(content.ranges) do
							local overlap_start = math.max(part.start, r.start)
							local overlap_stop = math.min(part.stop, r.stop)
							if overlap_stop >= overlap_start then
								line_content.ranges[#line_content.ranges + 1] = {
									start = line_pos + (overlap_start - part.start),
									stop = line_pos + (overlap_stop - part.start),
									elements = r.elements,
								}
							end
						end
						line_pos = line_pos + part_len
					end
				end
			end

			local styled_text
			if #line_content.ranges > 0 then
				styled_text = build_styled_text(self, line_content, base_style)
			else
				styled_text = self.__state.tss:apply(base_style, line_content.plain).text
			end
			return styled_text, std.utf.cell_len(styled_text)
		end

		for row_idx, row in ipairs(tbl.rows) do
			local style_key = row.header and "table.header" or "table.cell"
			local base_style = { style_key }
			local cell_props, _ = self.__state.tss:get(style_key)

			local wrapped_cells = {}
			local row_height = 1
			for i = 1, #col_widths do
				local cell_content = row.cells[i] or { plain = "", ranges = {} }
				local lines = table_layout.wrap_text_with_spans(cell_content.plain, col_widths[i])
				wrapped_cells[i] = lines
				if #lines > row_height then
					row_height = #lines
				end
			end

			for line_idx = 1, row_height do
				local row_line = styled_border(b.left)
				for col_idx = 1, #col_widths do
					local w = col_widths[col_idx]
					local align = cell_props.align or tbl.alignments[col_idx] or "left"
					local line_info = wrapped_cells[col_idx][line_idx]
					local cell_text = ""
					local cell_width = 0
					if line_info then
						cell_text, cell_width = style_wrapped_cell_line(
							row.cells[col_idx] or { plain = "", ranges = {} },
							line_info.parts,
							base_style
						)
					end

					local pad_left, pad_right = table_layout.compute_padding(align, w, cell_width)
					local left_pad = pad_left > 0 and self.__state.tss:apply(base_style, string.rep(" ", pad_left)).text
						or ""
					local right_pad = pad_right > 0
							and self.__state.tss:apply(base_style, string.rep(" ", pad_right)).text
						or ""

					row_line = row_line .. " " .. left_pad .. cell_text .. right_pad .. " "
					if col_idx < #col_widths then
						row_line = row_line .. styled_border(b.mid)
					end
				end
				row_line = row_line .. styled_border(b.right)
				row_line = clamp_display_width(row_line, table_available_width)
				self.__state.output:put(table_indent_str, row_line, "\n")
				lines_count = lines_count + 1
			end

			if row.header and row_idx < #tbl.rows then
				local sep_line = styled_border(b.mid_left)
				for i, w in ipairs(col_widths) do
					sep_line = sep_line .. styled_border(string.rep(b.bottom, w + 2))
					if i < #col_widths then
						sep_line = sep_line .. styled_border(b.mid_mid)
					end
				end
				sep_line = sep_line .. styled_border(b.mid_right)
				sep_line = clamp_display_width(sep_line, table_available_width)
				self.__state.output:put(table_indent_str, sep_line, "\n")
				lines_count = lines_count + 1
			end
		end
	end

	-- Build bottom border: └───┴───┴───┘
	local bottom_line = styled_border(b.bottom_left)
	for i, w in ipairs(col_widths) do
		bottom_line = bottom_line .. styled_border(string.rep(b.bottom, w + 2))
		if i < #col_widths then
			bottom_line = bottom_line .. styled_border(b.bottom_mid)
		end
	end
	bottom_line = bottom_line .. styled_border(b.bottom_right)
	bottom_line = clamp_display_width(bottom_line, table_available_width)
	self.__state.output:put(table_indent_str, bottom_line, "\n\n")
	lines_count = lines_count + 1 -- bottom border
	lines_count = lines_count + 1 -- trailing empty line

	local table_end_line = table_start_line + lines_count - 1

	if self.__state.pending_links then
		for _, link_info in ipairs(self.__state.pending_links) do
			self.__state.elements.links[#self.__state.elements.links + 1] = {
				line = table_start_line,
				url = link_info.url,
				title = link_info.title,
				container = { start_line = table_start_line, end_line = table_end_line },
			}
		end
		self.__state.pending_links = nil
	end

	if self.__state.pending_footnote_refs then
		for _, fn_info in ipairs(self.__state.pending_footnote_refs) do
			self.__state.elements.footnote_refs[#self.__state.elements.footnote_refs + 1] = {
				line = table_start_line,
				label = fn_info.label,
				container = { start_line = table_start_line, end_line = table_end_line },
			}
		end
		self.__state.pending_footnote_refs = nil
	end

	self.__state.current_line = self.__state.current_line + lines_count
end

-- Handle block start event
local handle_block_start = function(self, tag, attrs)
	attrs = attrs or {}

	if tag == "para" then
		self.__state.in_paragraph = true
		self.__state.paragraph_content = { plain = "", ranges = {} }
		self.__state.paragraph_tss = self.__state.tss:scope(PARAGRAPH_NO_CLIP_RSS)
	elseif tag == "heading" then
		self.__state.in_heading = true
		self.__state.heading_level = attrs.level or 1
		self.__state.heading_content = { plain = "", ranges = {} }
	elseif tag == "code_block" then
		self.__state.in_code_block = true
		self.__state.code_block_lang = attrs.lang
		self.__state.code_block_lines = {}
	elseif tag == "thematic_break" then
		-- Thematic break is self-closing, render immediately
		render_thematic_break(self)
	elseif tag == "list" then
		local list_info = {
			ordered = attrs.ordered,
			start = attrs.start or 1,
			tight = attrs.tight,
			depth = #self.__state.list_stack + 1,
		}
		table.insert(self.__state.list_stack, list_info)
		self.__state.list_item_count[list_info.depth] = 0
	elseif tag == "list_item" then
		local depth = #self.__state.list_stack
		self.__state.list_item_count[depth] = (self.__state.list_item_count[depth] or 0) + 1
		self.__state.in_list_item = true
		self.__state.list_item_depth = depth
		self.__state.list_item_first_block = true
		-- Store task list info
		if attrs.task then
			self.__state.list_item_task = { checked = attrs.checked }
		else
			self.__state.list_item_task = nil
		end
	elseif tag == "table" then
		self.__state.in_table = true
		self.__state.table_data = {
			columns = attrs.columns or 0,
			alignments = {},
			rows = {},
			start_line = self.__state.current_line,
		}
	elseif tag == "table_head" then
		self.__state.in_table_head = true
	elseif tag == "table_body" then
		self.__state.in_table_body = true
	elseif tag == "table_row" then
		self.__state.in_table_row = true
		self.__state.table_row_cells = {}
		self.__state.table_row_header = attrs.header or false
	elseif tag == "table_cell" then
		self.__state.in_table_cell = true
		self.__state.table_cell_content = { plain = "", ranges = {} }
		self.__state.table_cell_align = attrs.align or "left"
		-- Record alignment
		if self.__state.table_data and #self.__state.table_row_cells < #self.__state.table_data.alignments + 1 then
			self.__state.table_data.alignments[#self.__state.table_row_cells + 1] = attrs.align or "left"
		end
	elseif tag == "div" then
		-- Fenced div - track nesting level, class, and capture output
		local class = attrs.class or "default"

		-- Determine style base for width calculation
		local style_base = "div." .. class
		if not self.__state.tss:get_property(style_base, "border") then
			style_base = "div.default"
		end

		-- Get div style properties for width and padding calculation
		local _, div_obj = self.__state.tss:get(style_base)
		local _, default_obj = self.__state.tss:get("div.default")
		local w_value = (div_obj and div_obj.w) or (default_obj and default_obj.w) or 1
		local pad_value = (div_obj and div_obj.pad) or (default_obj and default_obj.pad) or 0

		-- Calculate content width (accounting for borders)
		local available_width = self.__state.width - 2 -- Account for border characters
		local el_width = self.__state.tss:calc_el_width(w_value, available_width)
		if el_width == 0 then
			el_width = available_width
		end

		local div_info = {
			class = class,
			depth = #self.__state.div_stack + 1,
			saved_output = self.__state.output, -- Save current output buffer
			saved_width = self.__state.width, -- Save original width
			saved_tss_window_w = self.__state.tss:get_window_width(), -- Save TSS layout width
			saved_supports_ts = self.__state.tss:get_supports_ts(), -- Save ts capability gate
			start_line = self.__state.current_line,
			el_width = el_width, -- Store calculated width for block_end
			pad = pad_value, -- Store padding for block_end
		}
		table.insert(self.__state.div_stack, div_info)
		-- Create new buffer to capture div content
		self.__state.output = buffer.new()
		-- Set narrower width for content inside the div (minus padding)
		self.__state.width = el_width - pad_value
		self.__state.tss:set_window_width(math.max(1, self.__state.width))
		-- Intentionally disable text sizing in bordered div content.
		-- Kitty/foot diverge on scaled multicell cursor behavior around box glyphs,
		-- which causes persistent right-border misalignment artifacts.
		self.__state.tss:set_supports_ts(false)
	elseif tag == "blockquote" then
		-- Blockquote - track nesting and capture output
		local bq_info = {
			depth = #self.__state.blockquote_stack + 1,
			saved_output = self.__state.output, -- Save current output buffer
			start_line = self.__state.current_line,
		}
		table.insert(self.__state.blockquote_stack, bq_info)
		-- Create new buffer to capture blockquote content
		self.__state.output = buffer.new()
	elseif tag == "footnotes" then
		-- Footnotes section
		self.__state.in_footnotes = true
		-- Render separator line before footnotes
		local sep = string.rep("─", math.floor(self.__state.width * 0.3))
		local styled_sep = self.__state.tss:apply({ "footnotes.separator" }, sep).text
		self.__state.output:put("\n", styled_sep, "\n")
		-- Update current line (empty line + separator)
		self.__state.current_line = self.__state.current_line + 2
	elseif tag == "footnote" then
		-- Individual footnote
		self.__state.in_footnote = true
		self.__state.footnote_label = attrs.label
		self.__state.footnote_index = attrs.index
		self.__state.footnote_content = { plain = "", ranges = {} }
		-- Track footnote definition start line for pager navigation
		self.__state.footnote_start_line = self.__state.current_line
	end
end

-- Handle block end event
local handle_block_end = function(self, tag)
	if tag == "para" then
		render_paragraph(self)
		self.__state.in_paragraph = false
		self.__state.paragraph_content = { plain = "", ranges = {} }
		self.__state.paragraph_tss = nil
		-- Track previous block only for top-level paragraphs (not inside lists)
		if not self.__state.in_list_item then
			self.__state.previous_block = "para"
		end
	elseif tag == "heading" then
		render_heading(self)
		self.__state.in_heading = false
		self.__state.heading_level = 0
		self.__state.heading_content = { plain = "", ranges = {} }
		self.__state.previous_block = "heading"
	elseif tag == "code_block" then
		render_code_block(self)
		self.__state.in_code_block = false
		self.__state.code_block_lang = nil
		self.__state.code_block_lines = {}
		self.__state.previous_block = "code_block"
	elseif tag == "list" then
		local depth = #self.__state.list_stack
		self.__state.list_item_count[depth] = nil
		table.remove(self.__state.list_stack)
		-- Update _in_list_item based on remaining stack
		self.__state.in_list_item = (#self.__state.list_stack > 0)
		-- Track previous block and add trailing newline only for top-level lists
		if #self.__state.list_stack == 0 then
			self.__state.output:put("\n")
			self.__state.current_line = self.__state.current_line + 1
			self.__state.previous_block = "list"
		end
	elseif tag == "list_item" then
		self.__state.in_list_item = (#self.__state.list_stack > 0)
		self.__state.list_item_depth = #self.__state.list_stack
		self.__state.list_item_first_block = false
		self.__state.list_continuation_indent = ""
		self.__state.list_item_task = nil
	elseif tag == "thematic_break" then
		self.__state.previous_block = "thematic_break"
	elseif tag == "table" then
		render_table(self)
		self.__state.in_table = false
		self.__state.table_data = nil
		self.__state.previous_block = "table"
	elseif tag == "table_head" then
		self.__state.in_table_head = false
	elseif tag == "table_body" then
		self.__state.in_table_body = false
	elseif tag == "table_row" then
		-- Add row to table data
		if self.__state.table_data then
			self.__state.table_data.rows[#self.__state.table_data.rows + 1] = {
				cells = self.__state.table_row_cells,
				header = self.__state.table_row_header,
			}
		end
		self.__state.in_table_row = false
		self.__state.table_row_cells = {}
	elseif tag == "table_cell" then
		-- Add cell to current row
		if self.__state.table_row_cells then
			self.__state.table_row_cells[#self.__state.table_row_cells + 1] = self.__state.table_cell_content
		end
		self.__state.in_table_cell = false
		self.__state.table_cell_content = { plain = "", ranges = {} }
	elseif tag == "div" then
		-- Close fenced div and render with borders
		if #self.__state.div_stack > 0 then
			local div_info = table.remove(self.__state.div_stack)
			local class = div_info.class or "default"

			-- Get captured content and trim trailing whitespace
			local content = self.__state.output:get():gsub("%s+$", "")
			-- Restore original output buffer and width
			self.__state.output = div_info.saved_output
			self.__state.width = div_info.saved_width
			self.__state.tss:set_window_width(div_info.saved_tss_window_w)
			self.__state.tss:set_supports_ts(div_info.saved_supports_ts)

			-- Determine style base for this div class
			local style_base = "div." .. class
			-- Fall back to div.default if class-specific style doesn't have border
			if not self.__state.tss:get_property(style_base, "border") then
				style_base = "div.default"
			end
			local div_block_indent = get_block_indent(self.__state.tss, style_base)

			-- Use pre-calculated width from block_start
			local el_width = div_info.el_width
			local available_width = self.__state.width - 2 -- For alignment calculation

			-- Get alignment from style
			local _, div_obj = self.__state.tss:get(style_base)
			local _, default_obj = self.__state.tss:get("div.default")
			local align_value = (div_obj and div_obj.align) or (default_obj and default_obj.align) or "none"

			-- Render div content with borders at calculated width
			local label = class ~= "default" and class or nil
			local rendered =
				render_bordered_content(self.__state.tss, style_base, content, el_width, label, 0, div_info.pad)

			-- Handle alignment for narrower divs
			local align = align_value
			if el_width < available_width and (align == "center" or align == "right") then
				local lines = {}
				for line in rendered:gmatch("[^\n]+") do
					local padded = line
					if align == "center" then
						padded = string.rep(" ", math.floor((available_width - el_width) / 2)) .. line
					elseif align == "right" then
						padded = string.rep(" ", available_width - el_width) .. line
					end
					lines[#lines + 1] = padded
				end
				rendered = table.concat(lines, "\n")
			end
			if div_block_indent > 0 then
				rendered = std.txt.indent(rendered, div_block_indent)
			end

			-- Track start line
			local start_line = div_info.start_line

			self.__state.output:put(rendered, "\n")

			-- Update current line count
			local lines_in_block = count_newlines(rendered) + 1
			self.__state.current_line = start_line + lines_in_block

			-- Mark elements inside this div with the div's line range for focus highlighting
			local end_line = start_line + lines_in_block - 1
			for _, link in ipairs(self.__state.elements.links) do
				if link.line >= start_line and link.line <= end_line and not link.container then
					link.container = { start_line = start_line, end_line = end_line }
				end
			end
			for _, fn in ipairs(self.__state.elements.footnote_refs) do
				if fn.line >= start_line and fn.line <= end_line and not fn.container then
					fn.container = { start_line = start_line, end_line = end_line }
				end
			end

			self.__state.previous_block = "div"
		end
	elseif tag == "blockquote" then
		-- Close blockquote and render with left bar
		if #self.__state.blockquote_stack > 0 then
			local bq_info = table.remove(self.__state.blockquote_stack)

			-- Get captured content
			local content = self.__state.output:get()
			-- Restore original output buffer
			self.__state.output = bq_info.saved_output

			-- Trim trailing whitespace/newlines from content
			content = content:gsub("%s+$", "")

			-- Get blockquote bar style
			local bar_char = self.__state.tss:get_property("blockquote.bar", "content") or "┃ "
			local styled_bar = self.__state.tss:apply({ "blockquote.bar" }, bar_char).text
			local bq_block_indent = get_block_indent(self.__state.tss, "blockquote")
			local bq_indent_str = string.rep(" ", bq_block_indent)

			-- Split content into lines and add bar prefix to non-empty lines
			local out = buffer.new()
			local lines = {}
			for line in (content .. "\n"):gmatch("([^\n]*)\n") do
				lines[#lines + 1] = line
			end

			for i, line in ipairs(lines) do
				-- Add bar to all lines (empty lines get just the bar for visual continuity)
				if line == "" or line:match("^%s*$") then
					-- Empty line - add bar only if not last line
					if i < #lines then
						out:put(bq_indent_str, styled_bar, "\n")
					end
				else
					out:put(bq_indent_str, styled_bar, line, "\n")
				end
			end

			local rendered = out:get()
			-- Remove trailing newline if present
			if rendered:sub(-1) == "\n" then
				rendered = rendered:sub(1, -2)
			end

			-- Track start line
			local start_line = bq_info.start_line

			self.__state.output:put(rendered, "\n\n")

			-- Update current line count
			local lines_in_block = count_newlines(rendered) + 2 -- +2 for trailing newlines
			self.__state.current_line = start_line + lines_in_block

			self.__state.previous_block = "blockquote"
		end
	elseif tag == "footnotes" then
		self.__state.in_footnotes = false
		self.__state.output:put("\n")
		self.__state.current_line = self.__state.current_line + 1
	elseif tag == "footnote" then
		-- Record footnote definition for pager navigation
		if self.__state.footnote_label and self.__state.footnote_start_line then
			self.__state.elements.footnote_defs[#self.__state.elements.footnote_defs + 1] = {
				start_line = self.__state.footnote_start_line,
				label = self.__state.footnote_label,
			}
		end
		-- Render footnote
		if self.__state.footnote_content then
			local marker = "[" .. self.__state.footnote_label .. "]"
			local styled_marker = self.__state.tss:apply({ "footnote.marker" }, marker).text
			local styled_text = build_styled_text(self, self.__state.footnote_content, { "footnote.content" })
			self.__state.output:put(styled_marker, " ", styled_text, "\n")
			-- Update current line
			self.__state.current_line = self.__state.current_line + 1
		end
		self.__state.in_footnote = false
		self.__state.footnote_label = nil
		self.__state.footnote_index = nil
		self.__state.footnote_content = nil
		self.__state.footnote_start_line = nil
	end
end

-- Handle inline start event
local handle_inline_start = function(self, tag, attrs)
	attrs = attrs or {}

	-- Footnote references are handled specially - they're self-contained
	if tag == "footnote_ref" then
		-- Render footnote reference marker inline
		local label = attrs.label or "?"
		local marker = "[" .. label .. "]"
		-- Add marker to current content with style
		local content = get_current_content(self)
		if content then
			local start_pos = std.utf.len(content.plain) + 1
			content.plain = content.plain .. marker
			local stop_pos = std.utf.len(content.plain)
			table.insert(content.ranges, {
				start = start_pos,
				stop = stop_pos,
				elements = { "footnote_ref" },
			})

			-- Track footnote ref for pager navigation (resolve position in render_paragraph)
			self.__state.pending_footnote_refs = self.__state.pending_footnote_refs or {}
			self.__state.pending_footnote_refs[#self.__state.pending_footnote_refs + 1] = {
				label = label,
			}
		end
		return -- Don't push to stack, footnote_ref is handled immediately
	end

	-- Record start position in plain text
	local start_pos = get_current_pos(self) + 1

	-- Push style context onto stack with position tracking
	local style_info = {
		tag = tag,
		attrs = attrs,
		start_pos = start_pos,
	}
	self.__state.inline_stack[#self.__state.inline_stack + 1] = style_info
end

-- Handle inline end event
local handle_inline_end = function(self, tag)
	-- Pop from stack
	local style_info = nil
	for i = #self.__state.inline_stack, 1, -1 do
		if self.__state.inline_stack[i].tag == tag then
			style_info = self.__state.inline_stack[i]
			table.remove(self.__state.inline_stack, i)
			break
		end
	end

	if not style_info then
		return
	end

	-- Record the style range
	local content = get_current_content(self)
	if content then
		local stop_pos = get_current_pos(self)

		-- Only add range if there's actual content
		if stop_pos >= style_info.start_pos then
			-- Determine style elements for this tag
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

		-- For links/images, track for pager navigation and optionally append URL
		if tag == "link" or tag == "image" then
			local url = style_info.attrs and style_info.attrs.href
			if url then
				-- Track link for pager navigation (resolve position later in render_paragraph)
				self.__state.pending_links = self.__state.pending_links or {}
				self.__state.pending_links[#self.__state.pending_links + 1] = {
					url = url,
					title = style_info.attrs and style_info.attrs.title,
				}

				-- Only add URL to rendered content if not hiding
				if not self.cfg.hide_link_urls then
					-- Record URL range (raw URL only, decorators applied during rendering)
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
		end
	end
end

-- Handle text event
local handle_text = function(self, text)
	if not text or text == "" then
		return
	end

	if self.__state.in_code_block then
		-- Code blocks: collect raw text, split into lines
		-- Text in code blocks comes as-is, may contain newlines
		for line in (text .. "\n"):gmatch("([^\n]*)\n") do
			self.__state.code_block_lines[#self.__state.code_block_lines + 1] = line
		end
		-- Remove the extra empty line we added
		if
			#self.__state.code_block_lines > 0
			and self.__state.code_block_lines[#self.__state.code_block_lines] == ""
		then
			self.__state.code_block_lines[#self.__state.code_block_lines] = nil
		end
	else
		-- Append plain text to current content buffer
		local content = get_current_content(self)
		if content then
			content.plain = content.plain .. text
		end
	end
end

-- Handle softbreak event
local handle_softbreak = function(self)
	-- Soft break becomes a space in rendered output
	local content = get_current_content(self)
	if content then
		content.plain = content.plain .. " "
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

-- Finalize and return output
local finish = function(self)
	local result = self.__state.output:get()

	-- Apply global indent if configured
	if self.cfg.indent > 0 then
		result = std.txt.indent(result, self.cfg.indent)
	end

	return {
		rendered = result,
		elements = self.__state.elements,
	}
end

-- Reset renderer state for reuse
local reset = function(self)
	self.__state.output = buffer.new()
	self.__state.in_code_block = false
	self.__state.code_block_lang = nil
	self.__state.code_block_lines = {}
	self.__state.in_paragraph = false
	self.__state.paragraph_content = { plain = "", ranges = {} }
	self.__state.paragraph_tss = nil
	self.__state.in_heading = false
	self.__state.heading_level = 0
	self.__state.heading_content = { plain = "", ranges = {} }
	self.__state.inline_stack = {}
	self.__state.list_stack = {}
	self.__state.list_item_count = {}
	self.__state.in_list_item = false
	self.__state.list_item_depth = 0
	self.__state.list_item_first_block = false
	self.__state.list_continuation_indent = ""
	self.__state.list_item_task = nil
	self.__state.in_table = false
	self.__state.table_data = nil
	self.__state.in_table_head = false
	self.__state.in_table_body = false
	self.__state.in_table_row = false
	self.__state.table_row_cells = {}
	self.__state.table_row_header = false
	self.__state.in_table_cell = false
	self.__state.table_cell_content = { plain = "", ranges = {} }
	self.__state.table_cell_align = "left"
	self.__state.previous_block = nil
	self.__state.div_stack = {}
	self.__state.blockquote_stack = {}
	self.__state.in_footnotes = false
	self.__state.in_footnote = false
	self.__state.footnote_label = nil
	self.__state.footnote_index = nil
	self.__state.footnote_content = nil
	self.__state.footnote_start_line = nil
	-- Element tracking state
	self.__state.elements = { code_blocks = {}, links = {}, footnote_refs = {}, footnote_defs = {}, headers = {} }
	self.__state.current_line = 1
	self.__state.pending_links = nil
	self.__state.pending_footnote_refs = nil
end

-- Create a new static renderer instance
local new = function(options)
	options = options or {}

	-- Create TSS instance
	local rss = theme_mod.get("markdown", options.rss)
	local width = options.width or 80
	local tss = tss_mod.merge(DEFAULT_RSS, rss, { supports_ts = options.supports_ts })
	-- Override TSS window width to match content width so all width/alignment
	-- calculations (especially in apply()) use content width, not terminal width
	tss:set_window_width(width)

	local renderer = {
		cfg = {
			width = width,
			indent = options.indent or 0,
			hide_link_urls = options.hide_link_urls or false,
			rss = rss,
			supports_ts = options.supports_ts,
		},
		__state = {
			output = buffer.new(),
			width = width,
			tss = tss,

			-- Element tracking for pager navigation
			elements = {
				code_blocks = {}, -- { start_line, end_line, raw, lang }
				links = {}, -- { line, url, title }
				footnote_refs = {}, -- { line, label }
				footnote_defs = {}, -- { start_line, label }
				headers = {}, -- { line, level, text }
			},
			current_line = 1, -- Track current rendered line number
			pending_links = nil, -- Pending links to resolve after paragraph wrapping
			pending_footnote_refs = nil, -- Pending footnote refs to resolve

			-- Block state
			in_code_block = false,
			code_block_lang = nil,
			code_block_lines = {},

			in_paragraph = false,
			-- Styled content buffer: { plain = "", ranges = {} }
			-- ranges: list of { start, stop, elements }
			paragraph_content = { plain = "", ranges = {} },
			paragraph_tss = nil,

			in_heading = false,
			heading_level = 0,
			heading_content = { plain = "", ranges = {} },

			-- Inline state - stack of active styles with start positions
			-- Each entry: { tag, attrs, start_pos }
			inline_stack = {},

			-- List state
			list_stack = {}, -- Stack of { ordered, start, tight, depth }
			list_item_count = {}, -- Item count at each nesting level
			in_list_item = false,
			list_item_depth = 0,
			list_item_first_block = false,
			list_continuation_indent = "",
			list_item_task = nil, -- { checked = bool } for task list items

			-- Table state (GFM)
			in_table = false,
			table_data = nil, -- { columns, alignments, rows, start_line }
			in_table_head = false,
			in_table_body = false,
			in_table_row = false,
			table_row_cells = {},
			table_row_header = false,
			in_table_cell = false,
			table_cell_content = { plain = "", ranges = {} },
			table_cell_align = "left",

			-- Block spacing state (tracks last completed block for newline insertion)
			previous_block = nil,

			div_stack = {},

			-- Blockquote state
			blockquote_stack = {},

			in_footnotes = false,
			in_footnote = false,
			footnote_label = nil,
			footnote_index = nil,
			footnote_content = nil,
			footnote_start_line = nil,
		},

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
