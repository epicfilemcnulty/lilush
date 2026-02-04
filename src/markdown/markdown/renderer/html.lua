-- SPDX-FileCopyrightText: © 2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: OWL-1.0 or later
-- Licensed under the Open Weights License v1.0. See LICENSE for details.

--[[
HTML renderer for markdown.

Consumes parser events and produces semantic HTML5 output with class attributes
for styling hooks. Supports GFM extensions and djot features (fenced divs,
inline attributes).

Usage:
    local html = require("markdown.renderer.html")
    local renderer = html.new()

    -- Feed events from parser
    renderer:render_event({ type = "block_start", tag = "para" })
    renderer:render_event({ type = "text", text = "Hello" })
    renderer:render_event({ type = "block_end", tag = "para" })

    -- Get final output
    local output = renderer:finish()
]]

local buffer = require("string.buffer")

-- HTML entity escaping for text content
-- Note: parentheses around gsub chain to discard the replacement count (gsub returns 2 values)
local html_escape = function(text)
	if not text then
		return ""
	end
	return (text:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

-- HTML attribute escaping (includes quotes)
-- Note: parentheses around gsub chain to discard the replacement count (gsub returns 2 values)
local attr_escape = function(text)
	if not text then
		return ""
	end
	return (text:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;"):gsub("'", "&#39;"))
end

-- Build HTML attribute string from table
local build_attrs = function(attrs)
	if not attrs or next(attrs) == nil then
		return ""
	end
	local parts = {}
	for k, v in pairs(attrs) do
		parts[#parts + 1] = string.format('%s="%s"', k, attr_escape(tostring(v)))
	end
	return " " .. table.concat(parts, " ")
end

-- Close sections with level >= target_level
local close_sections_to_level = function(self, target_level)
	while #self._section_stack > 0 do
		local top = self._section_stack[#self._section_stack]
		if top >= target_level then
			self._section_stack[#self._section_stack] = nil
			self._output:put("</section>\n")
		else
			break
		end
	end
end

-- Handle block_start events
local handle_block_start = function(self, tag, attrs)
	attrs = attrs or {}

	if tag == "para" then
		self._in_paragraph = true
		self._output:put("<p>")
	elseif tag == "heading" then
		self._in_heading = true
		self._heading_level = attrs.level or 1
		-- For h2+, handle section wrapping
		if self._heading_level >= 2 then
			-- Close any sections with level >= this heading level
			close_sections_to_level(self, self._heading_level)
			-- Open new section
			self._output:put("<section>\n")
			self._section_stack[#self._section_stack + 1] = self._heading_level
		end
		local html_attrs = {}
		if attrs.id then
			html_attrs.id = attrs.id
		end
		if attrs.class then
			html_attrs.class = attrs.class
		end
		self._output:put("<h", tostring(self._heading_level), build_attrs(html_attrs), ">")
	elseif tag == "code_block" then
		self._in_code_block = true
		self._code_block_lang = attrs.lang
		self._code_block_content = ""
	elseif tag == "thematic_break" then
		self._output:put("<hr>\n")
	elseif tag == "list" then
		local list_info = {
			ordered = attrs.ordered or false,
			tight = attrs.tight or false,
			has_task = false,
		}
		self._list_stack[#self._list_stack + 1] = list_info

		if attrs.ordered then
			if attrs.start and attrs.start ~= 1 then
				self._output:put('<ol start="', tostring(attrs.start), '">\n')
			else
				self._output:put("<ol>\n")
			end
		else
			self._output:put("<ul>\n")
		end
	elseif tag == "list_item" then
		self._in_list_item = true
		self._list_item_task = attrs.task
		self._list_item_checked = attrs.checked

		-- Mark parent list as having tasks if this is a task item
		if attrs.task and #self._list_stack > 0 then
			self._list_stack[#self._list_stack].has_task = true
		end

		if attrs.task then
			self._output:put('<li class="task-item">')
			local checkbox = attrs.checked and '<input type="checkbox" disabled checked> '
				or '<input type="checkbox" disabled> '
			self._output:put(checkbox)
		else
			self._output:put("<li>")
		end
	elseif tag == "table" then
		self._in_table = true
		self._output:put("<table>\n")
	elseif tag == "table_head" then
		self._in_table_head = true
		self._output:put("<thead>\n")
	elseif tag == "table_body" then
		self._in_table_body = true
		self._output:put("<tbody>\n")
	elseif tag == "table_row" then
		self._in_table_row = true
		self._output:put("<tr>")
	elseif tag == "table_cell" then
		self._in_table_cell = true
		local cell_tag = attrs.header and "th" or "td"
		local html_attrs = {}
		if attrs.align and attrs.align ~= "left" then
			html_attrs.style = "text-align: " .. attrs.align
		end
		self._output:put("<", cell_tag, build_attrs(html_attrs), ">")
		self._table_cell_tag = cell_tag
	elseif tag == "blockquote" then
		self._blockquote_depth = (self._blockquote_depth or 0) + 1
		self._output:put("<blockquote>\n")
	elseif tag == "div" then
		local html_attrs = {}
		if attrs.class then
			html_attrs.class = attrs.class
		end
		self._div_stack[#self._div_stack + 1] = attrs
		self._output:put("<div", build_attrs(html_attrs), ">\n")
	elseif tag == "footnotes" then
		self._in_footnotes = true
		self._output:put('<section class="footnotes">\n<hr>\n<ol>\n')
	elseif tag == "footnote" then
		self._in_footnote = true
		self._footnote_label = attrs.label
		self._footnote_index = attrs.index
		self._output:put('<li id="fn-', attr_escape(attrs.label), '">')
	end
end

-- Handle block_end events
local handle_block_end = function(self, tag)
	if tag == "para" then
		self._in_paragraph = false
		self._output:put("</p>\n")
	elseif tag == "heading" then
		self._in_heading = false
		self._output:put("</h", tostring(self._heading_level), ">\n")
		self._heading_level = 0
	elseif tag == "code_block" then
		self._in_code_block = false
		local lang_class = ""
		if self._code_block_lang and self._code_block_lang ~= "" then
			lang_class = ' class="language-' .. attr_escape(self._code_block_lang) .. '"'
		end
		self._output:put("<pre><code", lang_class, ">", html_escape(self._code_block_content), "</code></pre>\n")
		self._code_block_lang = nil
		self._code_block_content = ""
	elseif tag == "list" then
		local list_info = self._list_stack[#self._list_stack]
		self._list_stack[#self._list_stack] = nil

		if list_info then
			-- If the list had task items, add class to ul (need to rewrite opening tag)
			-- Since we can't go back, we just close normally
			if list_info.ordered then
				self._output:put("</ol>\n")
			else
				self._output:put("</ul>\n")
			end
		end
	elseif tag == "list_item" then
		self._in_list_item = false
		self._list_item_task = nil
		self._list_item_checked = nil
		self._output:put("</li>\n")
	elseif tag == "table" then
		self._in_table = false
		self._output:put("</table>\n")
	elseif tag == "table_head" then
		self._in_table_head = false
		self._output:put("</thead>\n")
	elseif tag == "table_body" then
		self._in_table_body = false
		self._output:put("</tbody>\n")
	elseif tag == "table_row" then
		self._in_table_row = false
		self._output:put("</tr>\n")
	elseif tag == "table_cell" then
		self._in_table_cell = false
		self._output:put("</", self._table_cell_tag or "td", ">")
		self._table_cell_tag = nil
	elseif tag == "blockquote" then
		self._blockquote_depth = (self._blockquote_depth or 1) - 1
		self._output:put("</blockquote>\n")
	elseif tag == "div" then
		self._div_stack[#self._div_stack] = nil
		self._output:put("</div>\n")
	elseif tag == "footnotes" then
		self._in_footnotes = false
		self._output:put("</ol>\n</section>\n")
	elseif tag == "footnote" then
		self._in_footnote = false
		-- Add backref link
		self._output:put(
			' <a href="#fnref-',
			attr_escape(self._footnote_label),
			'" class="footnote-backref">↩</a></li>\n'
		)
		self._footnote_label = nil
		self._footnote_index = nil
	end
end

-- Handle inline_start events
local handle_inline_start = function(self, tag, attrs)
	attrs = attrs or {}

	-- Push to inline stack
	self._inline_stack[#self._inline_stack + 1] = { tag = tag, attrs = attrs }

	if tag == "strong" then
		self._output:put("<strong>")
	elseif tag == "emph" then
		self._output:put("<em>")
	elseif tag == "code" then
		local html_attrs = {}
		if attrs.class then
			html_attrs.class = attrs.class
		end
		self._output:put("<code", build_attrs(html_attrs), ">")
	elseif tag == "link" then
		local html_attrs = {}
		html_attrs.href = attrs.href or ""
		if attrs.title and attrs.title ~= "" then
			html_attrs.title = attrs.title
		end
		if attrs.class then
			html_attrs.class = attrs.class
		end
		self._output:put("<a", build_attrs(html_attrs), ">")
	elseif tag == "image" then
		-- Start accumulating alt text
		self._in_image = true
		self._image_alt = ""
		self._image_attrs = attrs
	elseif tag == "strikethrough" then
		self._output:put("<del>")
	elseif tag == "footnote_ref" then
		-- Footnote reference: render immediately as it has no content
		local label = attrs.label or ""
		local index = attrs.index or label
		self._output:put(
			'<sup id="fnref-',
			attr_escape(label),
			'"><a href="#fn-',
			attr_escape(label),
			'">[',
			html_escape(tostring(index)),
			"]</a></sup>"
		)
	end
end

-- Handle inline_end events
local handle_inline_end = function(self, tag)
	-- Pop from inline stack
	if #self._inline_stack > 0 then
		self._inline_stack[#self._inline_stack] = nil
	end

	if tag == "strong" then
		self._output:put("</strong>")
	elseif tag == "emph" then
		self._output:put("</em>")
	elseif tag == "code" then
		self._output:put("</code>")
	elseif tag == "link" then
		self._output:put("</a>")
	elseif tag == "image" then
		-- Finish image tag with accumulated alt text
		self._in_image = false
		local attrs = self._image_attrs or {}
		local html_attrs = {}
		html_attrs.src = attrs.href or ""
		html_attrs.alt = self._image_alt
		if attrs.title and attrs.title ~= "" then
			html_attrs.title = attrs.title
		end
		if attrs.class then
			html_attrs.class = attrs.class
		end
		self._output:put("<img", build_attrs(html_attrs), ">")
		self._image_alt = ""
		self._image_attrs = nil
	elseif tag == "strikethrough" then
		self._output:put("</del>")
	elseif tag == "footnote_ref" then
		-- Already rendered in inline_start, nothing to do
	end
end

-- Handle text events
local handle_text = function(self, text)
	if self._in_code_block then
		-- Accumulate raw content for code blocks (will be escaped on output)
		self._code_block_content = self._code_block_content .. text
	elseif self._in_image then
		-- Accumulate alt text (escape it)
		self._image_alt = self._image_alt .. html_escape(text)
	else
		-- Output escaped text
		self._output:put(html_escape(text))
	end
end

-- Handle softbreak events
local handle_softbreak = function(self)
	-- Soft break becomes a newline in HTML
	self._output:put("\n")
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
	-- Close any remaining open sections
	while #self._section_stack > 0 do
		self._section_stack[#self._section_stack] = nil
		self._output:put("</section>\n")
	end
	return self._output:get()
end

-- Reset renderer state for reuse
local reset = function(self)
	self._output = buffer.new()
	self._in_paragraph = false
	self._in_heading = false
	self._heading_level = 0
	self._in_code_block = false
	self._code_block_lang = nil
	self._code_block_content = ""
	self._inline_stack = {}
	self._list_stack = {}
	self._in_list_item = false
	self._list_item_task = nil
	self._list_item_checked = nil
	self._in_table = false
	self._in_table_head = false
	self._in_table_body = false
	self._in_table_row = false
	self._in_table_cell = false
	self._table_cell_tag = nil
	self._blockquote_depth = 0
	self._div_stack = {}
	self._section_stack = {}
	self._in_footnotes = false
	self._in_footnote = false
	self._footnote_label = nil
	self._footnote_index = nil
	self._in_image = false
	self._image_alt = ""
	self._image_attrs = nil
end

-- Create a new HTML renderer instance
local new = function(options)
	options = options or {}

	local renderer = {
		-- Output buffer
		_output = buffer.new(),

		-- Block state
		_in_paragraph = false,
		_in_heading = false,
		_heading_level = 0,
		_in_code_block = false,
		_code_block_lang = nil,
		_code_block_content = "",

		-- Inline state
		_inline_stack = {},

		-- List state
		_list_stack = {},
		_in_list_item = false,
		_list_item_task = nil,
		_list_item_checked = nil,

		-- Table state
		_in_table = false,
		_in_table_head = false,
		_in_table_body = false,
		_in_table_row = false,
		_in_table_cell = false,
		_table_cell_tag = nil,

		-- Blockquote state
		_blockquote_depth = 0,

		-- Div state (for nested divs)
		_div_stack = {},

		-- Section state (for h2+ wrapping)
		_section_stack = {},

		-- Footnote state
		_in_footnotes = false,
		_in_footnote = false,
		_footnote_label = nil,
		_footnote_index = nil,

		-- Image state (for alt text accumulation)
		_in_image = false,
		_image_alt = "",
		_image_attrs = nil,

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
