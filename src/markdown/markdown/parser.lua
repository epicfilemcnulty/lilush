-- SPDX-FileCopyrightText: © 2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: OWL-1.0 or later
-- Licensed under the Open Weights License v1.0. See LICENSE for details.

--[[
Core streaming parser for markdown.

Coordinates block detection and event emission.
Supports chunk-based streaming input with inline parsing.

Options:
  on_event: callback function(event) invoked for each event
  inline: boolean (default true) - whether to parse inline elements
  streaming_inline: boolean (default true) - emit inline events incrementally

When streaming_inline is true, inline content is emitted as soon as possible
at safe boundaries (word breaks when no unclosed delimiters). This enables
real-time rendering for LLM output.
]]

local events = require("markdown.events")
local state = require("markdown.state")
local buffer = require("markdown.buffer")
local inline = require("markdown.inline")

-- Forward declarations for mutually recursive functions
local close_list_item
local close_all_lists
local open_paragraph
local close_table
local close_div
local close_blockquote
local close_all_blockquotes
local process_line

-- Close the current paragraph if open
local close_paragraph = function(self)
	if self._in_paragraph then
		-- Flush any buffered inline content
		if self._inline_buffer then
			self._inline_buffer:flush()
		end
		self._events:emit_block_end("para")
		self._in_paragraph = false
		self._para_content = ""
	end
end

-- Close the current list item (and paragraph inside it)
close_list_item = function(self)
	if self._in_list_item then
		close_paragraph(self)
		self._events:emit_block_end("list_item")
		self._in_list_item = false
	end
end

-- Close lists down to a given indentation level
-- If target_indent is nil, close all lists
local close_lists_to_indent = function(self, target_indent)
	while #self._list_stack > 0 do
		local current = self._list_stack[#self._list_stack]
		if target_indent and current.indent <= target_indent then
			break
		end
		close_list_item(self)
		self._events:emit_block_end("list")
		table.remove(self._list_stack)
	end
end

-- Close all open lists
close_all_lists = function(self)
	close_lists_to_indent(self, nil)
end

-- Close any open code block
local close_code_block = function(self)
	if self._code_block then
		-- Emit accumulated code block content (no inline parsing for code)
		if self._code_block.content and self._code_block.content ~= "" then
			self._events:emit_text(self._code_block.content)
		end
		self._events:emit_block_end("code_block")
		self._code_block = nil
	end
end

-- Close any open div
close_div = function(self)
	if #self._div_stack > 0 then
		local div = table.remove(self._div_stack)
		-- Close any content inside the div
		close_paragraph(self)
		close_all_lists(self)
		self._events:emit_block_end("div")
	end
end

-- Close all open divs
local close_all_divs = function(self)
	while #self._div_stack > 0 do
		close_div(self)
	end
end

-- Close any open blockquote
close_blockquote = function(self)
	if #self._blockquote_stack > 0 then
		table.remove(self._blockquote_stack)
		-- Close any content inside the blockquote
		close_paragraph(self)
		close_all_lists(self)
		close_all_divs(self)
		self._events:emit_block_end("blockquote")
	end
end

-- Close all open blockquotes
close_all_blockquotes = function(self)
	while #self._blockquote_stack > 0 do
		close_blockquote(self)
	end
end

-- Handle a line inside a div - check for closing fence
local handle_div_line = function(self, line)
	if #self._div_stack == 0 then
		return false -- Not in a div
	end

	local current_div = self._div_stack[#self._div_stack]

	-- Check for closing fence
	if state.is_div_fence_close(line, current_div.fence_len) then
		close_div(self)
		return true -- Line consumed
	end

	-- Check for nested div opening
	local fence_len, class_name, indent = state.detect_div_fence_open(line)
	if fence_len then
		close_paragraph(self)
		-- Open nested div
		self._div_stack[#self._div_stack + 1] = {
			fence_len = fence_len,
			class = class_name,
			indent = indent,
		}
		local attrs = nil
		if class_name and class_name ~= "" then
			attrs = { class = class_name }
		end
		self._events:emit_block_start("div", attrs)
		return true -- Line consumed
	end

	return false -- Line not consumed, needs further processing
end

-- Handle a line inside a code block
local handle_code_block_line = function(self, line)
	local cb = self._code_block

	-- If code block is inside a list, strip the list's content indent first
	local adjusted_line = line
	if cb.list_indent > 0 then
		local spaces = line:match("^( *)")
		if spaces and #spaces >= cb.list_indent then
			adjusted_line = line:sub(cb.list_indent + 1)
		end
	end

	-- Check for closing fence (using adjusted line with list indent stripped)
	if state.is_code_fence_close(adjusted_line, cb.fence_char, cb.fence_len) then
		close_code_block(self)
		return
	end

	-- Remove indentation (up to the original indent level)
	-- Only count leading spaces (not tabs) for indent removal.
	-- This matches CommonMark behavior where code block indentation is space-based.
	local content = adjusted_line
	if cb.indent > 0 then
		local spaces = adjusted_line:match("^( *)")
		local remove_count = math.min(#spaces, cb.indent)
		content = adjusted_line:sub(remove_count + 1)
	end

	-- Accumulate content
	if cb.content == "" then
		cb.content = content
	else
		cb.content = cb.content .. "\n" .. content
	end
end

-- Close any open table
close_table = function(self)
	if not self._table then
		return
	end

	local tbl = self._table

	-- Emit table events
	self._events:emit_block_start("table", { columns = #tbl.alignments })

	-- Emit header row
	self._events:emit_block_start("table_head")
	self._events:emit_block_start("table_row", { header = true })
	for i, cell in ipairs(tbl.header_cells) do
		self._events:emit_block_start("table_cell", { align = tbl.alignments[i] or "left", header = true })
		-- Parse inline content in cell
		if self._parse_inline then
			local parser = inline.new({
				emit = function(e)
					self._events:emit(e)
				end,
				link_refs = self._link_refs,
				footnote_tracker = self._footnote_tracker,
			})
			parser:parse(cell)
		else
			self._events:emit_text(cell)
		end
		self._events:emit_block_end("table_cell")
	end
	self._events:emit_block_end("table_row")
	self._events:emit_block_end("table_head")

	-- Emit body rows
	if #tbl.body_rows > 0 then
		self._events:emit_block_start("table_body")
		for _, row_cells in ipairs(tbl.body_rows) do
			self._events:emit_block_start("table_row")
			for i, cell in ipairs(row_cells) do
				self._events:emit_block_start("table_cell", { align = tbl.alignments[i] or "left" })
				-- Parse inline content in cell
				if self._parse_inline then
					local parser = inline.new({
						emit = function(e)
							self._events:emit(e)
						end,
						link_refs = self._link_refs,
						footnote_tracker = self._footnote_tracker,
					})
					parser:parse(cell)
				else
					self._events:emit_text(cell)
				end
				self._events:emit_block_end("table_cell")
			end
			self._events:emit_block_end("table_row")
		end
		self._events:emit_block_end("table_body")
	end

	self._events:emit_block_end("table")
	self._table = nil
end

-- Handle a line inside a table
local handle_table_line = function(self, line)
	-- Check for blank line (ends table)
	if state.is_blank_line(line) then
		close_table(self)
		return true -- Line was consumed
	end

	-- Try to parse as table row
	local cells = state.parse_table_row(line)
	if cells then
		-- Normalize cell count to match header
		local col_count = #self._table.alignments
		while #cells < col_count do
			cells[#cells + 1] = ""
		end
		-- Truncate extra cells
		while #cells > col_count do
			cells[#cells] = nil
		end
		self._table.body_rows[#self._table.body_rows + 1] = cells
		return true -- Line was consumed
	end

	-- Not a table row - close table and let line be reprocessed
	close_table(self)
	return false -- Line was not consumed, needs reprocessing
end

-- Check if a line could start a table (has pipe characters)
local could_be_table_row = function(line)
	return line:find("|") ~= nil
end

-- Handle a blank line
local handle_blank_line = function(self)
	-- Close table on blank line
	close_table(self)

	-- Close paragraph on blank line
	close_paragraph(self)

	-- If we're in a list, mark that we've seen a blank line
	-- This affects tight/loose determination
	if #self._list_stack > 0 then
		local current = self._list_stack[#self._list_stack]
		current.had_blank = true
		self._pending_blank = true
	end
end

-- Emit inline content (either parsed or raw)
local emit_inline_content = function(self, content)
	if not self._parse_inline then
		-- Raw mode: emit as plain text
		self._events:emit_text(content)
		return
	end

	if self._streaming_inline and self._inline_buffer then
		-- Streaming mode: feed to buffer for incremental emission
		self._inline_buffer:feed(content)
	else
		-- Non-streaming mode: parse and emit immediately
		local parser = inline.new({
			emit = function(e)
				self._events:emit(e)
			end,
			link_refs = self._link_refs,
			footnote_tracker = self._footnote_tracker,
		})
		parser:parse(content)
	end
end

-- Emit a softbreak, handling inline parsing mode
local emit_softbreak = function(self)
	if self._streaming_inline and self._inline_buffer then
		-- In streaming mode, feed softbreak as space to buffer
		-- (CommonMark: softbreak renders as space or newline depending on renderer)
		self._inline_buffer:feed(" ")
	else
		self._events:emit_softbreak()
	end
end

-- Open a new heading
local open_heading = function(self, attrs)
	self._events:emit_block_start("heading", { level = attrs.level })

	-- Parse inline content in heading
	if self._parse_inline then
		local parser = inline.new({
			emit = function(e)
				self._events:emit(e)
			end,
			link_refs = self._link_refs,
			footnote_tracker = self._footnote_tracker,
		})
		parser:parse(attrs.content)
	else
		self._events:emit_text(attrs.content)
	end

	self._events:emit_block_end("heading")
end

-- Open a new code block
local open_code_block = function(self, attrs)
	-- If inside a list, store the list's content indent for fence detection
	local list_indent = 0
	if #self._list_stack > 0 then
		list_indent = self._list_stack[#self._list_stack].content_indent
	end
	self._code_block = {
		fence_char = attrs.fence_char,
		fence_len = attrs.fence_len,
		lang = attrs.lang,
		indent = attrs.indent,
		list_indent = list_indent,
		content = "",
	}
	local block_attrs = nil
	if attrs.lang and attrs.lang ~= "" then
		block_attrs = { lang = attrs.lang }
	end
	self._events:emit_block_start("code_block", block_attrs)
end

-- Emit a thematic break
local emit_thematic_break = function(self)
	self._events:emit_block_start("thematic_break")
	self._events:emit_block_end("thematic_break")
end

-- Check if we can continue the current list (same type and marker)
local function can_continue_list(self, attrs)
	if #self._list_stack == 0 then
		return false
	end
	local current = self._list_stack[#self._list_stack]
	-- Must match ordered/unordered type
	if current.ordered ~= attrs.ordered then
		return false
	end
	-- For unordered, marker must match (-, *, + are different lists)
	if not attrs.ordered and current.marker ~= attrs.marker then
		return false
	end
	-- For ordered, delimiter must match (. vs ))
	if attrs.ordered and current.delimiter ~= attrs.delimiter then
		return false
	end
	-- Indent level must be compatible (same level, not nested)
	if attrs.indent ~= current.indent then
		return false
	end
	return true
end

-- Start a new list
local function start_list(self, attrs)
	local list = {
		ordered = attrs.ordered,
		marker = attrs.marker,
		delimiter = attrs.delimiter,
		start = attrs.start or 1,
		indent = attrs.indent,
		content_indent = attrs.content_indent,
		tight = true, -- Assume tight until proven otherwise
		had_blank = false, -- Track if we've seen blank line
	}
	table.insert(self._list_stack, list)
	self._events:emit_block_start("list", {
		ordered = list.ordered,
		start = list.start,
		tight = true,
	})
end

-- Start a new list item
-- If close_previous is true, close any open sibling item first
local function start_list_item(self, attrs, close_previous)
	if close_previous then
		close_list_item(self)
	end
	-- Build list_item event attributes
	local item_attrs = nil
	if attrs.task then
		item_attrs = { task = true, checked = attrs.checked }
	end
	self._events:emit_block_start("list_item", item_attrs)
	self._in_list_item = true

	-- If item has content, start a paragraph with it
	if attrs.content and attrs.content ~= "" then
		open_paragraph(self, attrs.content)
	end
end

-- Handle a list item line
local function handle_list_item(self, attrs)
	-- First, close any lists that are deeper than this item's indent level
	-- This handles cases like returning from a deeply nested list to an outer level
	close_lists_to_indent(self, attrs.indent)

	-- Now check if this continues the current list or starts a new one
	if can_continue_list(self, attrs) then
		-- Same list, new item - close previous sibling item
		start_list_item(self, attrs, true)
	else
		-- Different list type/marker - close current lists at this level and start new
		-- Close any lists at same or higher indent (we're replacing them)
		close_lists_to_indent(self, attrs.indent - 1)
		-- Close current paragraph (if any) before starting nested list
		-- but don't close the parent list item - nested list is inside it
		close_paragraph(self)
		start_list(self, attrs)
		-- First item of new list - don't close parent item
		start_list_item(self, attrs, false)
	end
end

-- Open a new paragraph
open_paragraph = function(self, line)
	self._in_paragraph = true
	self._para_content = line
	self._events:emit_block_start("para")

	-- Emit first line content
	emit_inline_content(self, line)
end

-- Continue current paragraph
local continue_paragraph = function(self, line)
	self._para_content = self._para_content .. "\n" .. line

	-- Emit soft break then line content
	emit_softbreak(self)
	emit_inline_content(self, line)
end

-- Process a single line
process_line = function(self, line)
	-- If in code block, handle specially (no interruption)
	if self._code_block then
		handle_code_block_line(self, line)
		return
	end

	-- Handle blockquotes
	-- Check if line starts with > (blockquote marker)
	local bq_content, bq_indent = state.detect_blockquote(line)
	if bq_content ~= nil then
		-- Line is a blockquote line
		-- Close any pending footnote since we're in a blockquote
		if self._current_footnote then
			self._current_footnote = nil
			self._footnote_indent = nil
		end

		-- If not already in a blockquote, start one
		if #self._blockquote_stack == 0 then
			-- Close any open table first
			close_table(self)
			self._blockquote_stack[#self._blockquote_stack + 1] = { indent = bq_indent }
			self._events:emit_block_start("blockquote")
		end

		-- Process the content inside the blockquote (may be nested blockquote, list, etc.)
		-- Set flag to prevent blockquote continuation logic from triggering on the stripped content
		self._processing_blockquote_content = true
		process_line(self, bq_content)
		self._processing_blockquote_content = false
		return
	elseif #self._blockquote_stack > 0 and not self._processing_blockquote_content then
		-- We're in a blockquote but this line doesn't have > marker
		-- (Only check this for new lines from the input, not for recursively processed content)
		-- Check for lazy continuation or close the blockquote

		if state.is_blank_line(line) then
			-- Blank line closes the blockquote
			close_all_blockquotes(self)
		elseif self._in_paragraph then
			-- Lazy continuation: non-blank line without > can continue a paragraph
			-- But only if it's not a block that would interrupt
			local block_type = state.detect_block(line)
			if block_type and state.can_interrupt_paragraph(block_type, nil) then
				-- This block type interrupts - close blockquote and process normally
				close_all_blockquotes(self)
			else
				-- Lazy continuation - continue the paragraph inside blockquote
				continue_paragraph(self, line)
				return
			end
		else
			-- Not in paragraph and line doesn't start with > - close blockquote
			close_all_blockquotes(self)
		end
		-- Fall through to process line normally after closing blockquotes
	end

	-- Check for link reference definition (not inside any block)
	-- Link references are collected but not emitted as events
	if not self._in_paragraph and #self._list_stack == 0 and not self._table then
		local label, dest, title = state.detect_link_reference(line)
		if label then
			-- Store link reference (first definition wins)
			if not self._link_refs[label] then
				self._link_refs[label] = { url = dest, title = title }
			end
			return -- Line consumed
		end
	end

	-- Check for footnote definition (not inside any block)
	if not self._in_paragraph and #self._list_stack == 0 and not self._table then
		local label, content, indent = state.detect_footnote_definition(line)
		if label then
			-- Store footnote definition (first definition wins)
			if not self._footnotes[label] then
				self._footnotes[label] = { content = content, lines = {} }
				self._current_footnote = label
				self._footnote_indent = indent
			end
			return -- Line consumed
		end
	end

	-- Check for footnote continuation (indented line after footnote definition)
	if self._current_footnote then
		-- Count leading spaces
		local leading_spaces = line:match("^( *)")
		if #leading_spaces >= self._footnote_indent + 2 then
			-- Continuation of footnote
			local content = line:sub(self._footnote_indent + 2 + 1) -- Strip indent
			table.insert(self._footnotes[self._current_footnote].lines, content)
			return -- Line consumed
		elseif state.is_blank_line(line) then
			-- Blank line in footnote - check next line
			table.insert(self._footnotes[self._current_footnote].lines, "")
			return -- Line consumed
		else
			-- End of footnote
			self._current_footnote = nil
			self._footnote_indent = nil
		end
	end

	-- Check for div fences
	if #self._div_stack > 0 then
		-- Check for closing or nested div first
		if handle_div_line(self, line) then
			return -- Line consumed by div handling
		end
		-- Not a div fence, continue processing (content inside div)
	end

	-- Check for div opening (only when not inside certain blocks)
	if not self._in_paragraph and not self._table then
		local fence_len, class_name, indent = state.detect_div_fence_open(line)
		if fence_len then
			close_paragraph(self)
			close_all_lists(self)
			-- Start new div
			self._div_stack[#self._div_stack + 1] = {
				fence_len = fence_len,
				class = class_name,
				indent = indent,
			}
			local attrs = nil
			if class_name and class_name ~= "" then
				attrs = { class = class_name }
			end
			self._events:emit_block_start("div", attrs)
			return -- Line consumed
		end
	end

	-- If we're inside a table, handle table lines
	if self._table then
		if handle_table_line(self, line) then
			return -- Line was consumed by table
		end
		-- Line was not consumed, continue processing below
	end

	-- Check if we have a pending table row (potential header waiting for delimiter)
	if self._pending_table_row then
		local pending = self._pending_table_row
		self._pending_table_row = nil

		-- Check if this line is a delimiter row
		local alignments = state.detect_table_delimiter(line)
		if alignments and #alignments == #pending.cells then
			-- Confirmed table! Start table mode
			close_paragraph(self)
			close_all_lists(self)
			self._table = {
				alignments = alignments,
				header_cells = pending.cells,
				body_rows = {},
			}
			return
		else
			-- Not a table - emit pending row as paragraph content
			-- Re-process the pending line as a paragraph
			open_paragraph(self, pending.line)
			-- Continue processing current line below
		end
	end

	-- Check for blank line
	if state.is_blank_line(line) then
		handle_blank_line(self)
		return
	end

	-- Clear pending blank flag when we see non-blank content
	self._pending_blank = false

	-- Detect block type
	local block_type, attrs = state.detect_block(line)

	-- Special handling when we're inside a list
	if #self._list_stack > 0 then
		local spaces = line:match("^( *)") or ""

		-- Check if this is a direct list item (for top-level items with <= 3 leading spaces)
		if block_type == "list_item" then
			handle_list_item(self, attrs)
			return
		end

		-- Find the appropriate list level for this line's indentation
		-- by checking the stack from top to bottom, looking for a list
		-- where the line could be a sibling or content continuation
		for i = #self._list_stack, 1, -1 do
			local list = self._list_stack[i]

			-- Check for sibling nested items (indented to marker position)
			if #spaces >= list.indent then
				-- Close any deeper lists first
				close_lists_to_indent(self, list.indent)

				local stripped = line:sub(list.indent + 1)
				local inner_type, inner_attrs = state.detect_block(stripped)
				if inner_type == "list_item" then
					-- Sibling or new nested list item
					inner_attrs.indent = inner_attrs.indent + list.indent
					inner_attrs.content_indent = inner_attrs.content_indent + list.indent
					handle_list_item(self, inner_attrs)
					return
				end
			end

			-- Check for content continuation (indented to content position)
			if #spaces >= list.content_indent then
				-- Close any deeper lists first
				close_lists_to_indent(self, list.indent)

				local content = line:sub(list.content_indent + 1)
				local inner_type, inner_attrs = state.detect_block(content)

				if inner_type == "list_item" then
					-- New deeper nested list
					inner_attrs.indent = inner_attrs.indent + list.content_indent
					inner_attrs.content_indent = inner_attrs.content_indent + list.content_indent
					handle_list_item(self, inner_attrs)
				elseif inner_type == "code_block" then
					close_paragraph(self)
					open_code_block(self, inner_attrs)
				elseif inner_type == "heading" then
					close_paragraph(self)
					open_heading(self, inner_attrs)
				elseif inner_type == "thematic_break" then
					close_paragraph(self)
					emit_thematic_break(self)
				elseif self._in_paragraph then
					continue_paragraph(self, content)
				else
					open_paragraph(self, content)
				end
				return
			end
		end

		-- Line doesn't belong to any list - close all lists
		close_all_lists(self)
	end

	-- Handle based on block type
	if block_type == "list_item" then
		-- Start a new list
		close_paragraph(self)
		start_list(self, attrs)
		start_list_item(self, attrs)
	elseif block_type and state.can_interrupt_paragraph(block_type, attrs) then
		close_paragraph(self)

		if block_type == "heading" then
			open_heading(self, attrs)
		elseif block_type == "code_block" then
			open_code_block(self, attrs)
		elseif block_type == "thematic_break" then
			emit_thematic_break(self)
		end
	elseif self._in_paragraph then
		continue_paragraph(self, line)
	else
		-- Check if this could be a table header row (has pipes)
		-- Only check when not in a list and not already in paragraph
		if could_be_table_row(line) and #self._list_stack == 0 then
			local cells = state.parse_table_row(line)
			if cells and #cells > 0 then
				-- Buffer this as a potential table header
				-- Next line will confirm if it's a table (delimiter row)
				self._pending_table_row = {
					line = line,
					cells = cells,
				}
				return
			end
		end
		open_paragraph(self, line)
	end
end

-- Feed a chunk of text to the parser
local feed = function(self, chunk)
	if not chunk or chunk == "" then
		return
	end

	-- Append chunk to pending content
	local content = self._pending .. chunk

	-- Process complete lines
	local last_newline = 0
	local i = 1
	while i <= #content do
		local char = content:sub(i, i)
		if char == "\n" then
			local line = content:sub(last_newline + 1, i - 1)
			-- Handle CRLF line endings (Windows)
			if line:sub(-1) == "\r" then
				line = line:sub(1, -2)
			end
			process_line(self, line)
			last_newline = i
		end
		i = i + 1
	end

	-- Keep incomplete line as pending
	if last_newline < #content then
		self._pending = content:sub(last_newline + 1)
	else
		self._pending = ""
	end
end

-- Finalize parsing
local finish = function(self)
	-- Process any remaining pending content as a final line
	if self._pending ~= "" then
		process_line(self, self._pending)
		self._pending = ""
	end

	-- Handle pending table row (table header without delimiter)
	if self._pending_table_row then
		local pending = self._pending_table_row
		self._pending_table_row = nil
		open_paragraph(self, pending.line)
	end

	-- End any current footnote
	self._current_footnote = nil
	self._footnote_indent = nil

	-- Close any open blocks
	close_table(self)
	close_code_block(self)
	close_all_lists(self)
	close_all_divs(self)
	close_all_blockquotes(self)
	close_paragraph(self)

	-- Emit used footnotes at document end
	local used_footnotes = {}
	if self._footnote_tracker and self._footnote_tracker.used then
		for label, _ in pairs(self._footnote_tracker.used) do
			if self._footnotes[label] then
				used_footnotes[#used_footnotes + 1] = label
			end
		end
	end

	if #used_footnotes > 0 then
		-- Sort footnotes by first use order (alphabetically as fallback)
		table.sort(used_footnotes)

		-- Emit footnotes block
		self._events:emit_block_start("footnotes")
		for i, label in ipairs(used_footnotes) do
			local fn = self._footnotes[label]
			-- Combine content lines
			local full_content = fn.content
			if #fn.lines > 0 then
				full_content = full_content .. "\n" .. table.concat(fn.lines, "\n")
			end

			self._events:emit_block_start("footnote", { label = label, index = i })
			-- Parse inline content in footnote
			if self._parse_inline then
				local parser = inline.new({
					emit = function(e)
						self._events:emit(e)
					end,
					link_refs = self._link_refs,
					footnote_tracker = self._footnote_tracker,
				})
				parser:parse(full_content)
			else
				self._events:emit_text(full_content)
			end
			self._events:emit_block_end("footnote")
		end
		self._events:emit_block_end("footnotes")
	end
end

-- Reset parser state for reuse
local reset = function(self)
	self._pending = ""
	self._in_paragraph = false
	self._code_block = nil
	self._para_content = ""
	self._list_stack = {}
	self._in_list_item = false
	self._pending_blank = false
	self._table = nil
	self._pending_table_row = nil
	-- Clear table contents rather than replacing (keeps same reference for buffer)
	for k in pairs(self._link_refs) do
		self._link_refs[k] = nil
	end
	self._footnotes = {}
	for k in pairs(self._footnote_tracker.used) do
		self._footnote_tracker.used[k] = nil
	end
	self._current_footnote = nil
	self._footnote_indent = nil
	self._div_stack = {}
	self._blockquote_stack = {}
	if self._inline_buffer then
		self._inline_buffer:reset()
	end
end

-- Create a new parser
local new = function(options)
	options = options or {}

	local parse_inline = options.inline ~= false -- Default true
	local streaming_inline = options.streaming_inline ~= false -- Default true

	local emit_callback = options.on_event or function() end

	-- Shared state tables (same references used by buffer and inline parsers)
	local link_refs = {} -- {label -> {url, title}}
	local footnote_tracker = { used = {} } -- {used = {label -> true}}

	-- Create inline buffer for streaming mode
	local inline_buffer = nil
	if parse_inline and streaming_inline then
		inline_buffer = buffer.new({
			emit = emit_callback,
			link_refs = link_refs,
			footnote_tracker = footnote_tracker,
		})
	end

	return {
		_events = events.new(emit_callback),
		_pending = "",
		_in_paragraph = false,
		_code_block = nil,
		_para_content = "",
		_list_stack = {},
		_in_list_item = false,
		_pending_blank = false,
		_table = nil,
		_pending_table_row = nil,
		_parse_inline = parse_inline,
		_streaming_inline = streaming_inline,
		_inline_buffer = inline_buffer,
		-- Phase 6: Document-level state (same table refs as passed to buffer)
		_link_refs = link_refs, -- {label -> {url, title}}
		_footnotes = {}, -- {label -> {content, lines}}
		_footnote_tracker = footnote_tracker, -- {used = {label -> true}}
		_current_footnote = nil, -- Currently collecting footnote
		_footnote_indent = nil, -- Indent level of current footnote
		_div_stack = {}, -- Stack of open divs
		_blockquote_stack = {}, -- Stack of open blockquotes
		feed = feed,
		finish = finish,
		reset = reset,
	}
end

return { new = new }
