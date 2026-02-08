-- SPDX-FileCopyrightText: © 2022—2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: LicenseRef-OWL-1.0-or-later OR GPL-3.0-or-later
-- Dual-licensed under OWL v1.0+ and GPLv3+. See LICENSE and LICENSE-GPL3.

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
	while #self.__state.section_stack > 0 do
		local top = self.__state.section_stack[#self.__state.section_stack]
		if top >= target_level then
			self.__state.section_stack[#self.__state.section_stack] = nil
			self.__state.output:put("</section>\n")
		else
			break
		end
	end
end

-- Handle block_start events
local handle_block_start = function(self, tag, attrs)
	attrs = attrs or {}

	if tag == "para" then
		self.__state.in_paragraph = true
		self.__state.output:put("<p>")
	elseif tag == "heading" then
		self.__state.in_heading = true
		self.__state.heading_level = attrs.level or 1
		-- For h2+, handle section wrapping
		if self.__state.heading_level >= 2 then
			-- Close any sections with level >= this heading level
			close_sections_to_level(self, self.__state.heading_level)
			-- Open new section
			self.__state.output:put("<section>\n")
			self.__state.section_stack[#self.__state.section_stack + 1] = self.__state.heading_level
		end
		local html_attrs = {}
		if attrs.id then
			html_attrs.id = attrs.id
		end
		if attrs.class then
			html_attrs.class = attrs.class
		end
		self.__state.output:put("<h", tostring(self.__state.heading_level), build_attrs(html_attrs), ">")
	elseif tag == "code_block" then
		self.__state.in_code_block = true
		self.__state.code_block_lang = attrs.lang
		self.__state.code_block_content = ""
	elseif tag == "thematic_break" then
		self.__state.output:put("<hr>\n")
	elseif tag == "list" then
		local list_info = {
			ordered = attrs.ordered or false,
			tight = attrs.tight or false,
			has_task = false,
		}
		self.__state.list_stack[#self.__state.list_stack + 1] = list_info

		if attrs.ordered then
			if attrs.start and attrs.start ~= 1 then
				self.__state.output:put('<ol start="', tostring(attrs.start), '">\n')
			else
				self.__state.output:put("<ol>\n")
			end
		else
			self.__state.output:put("<ul>\n")
		end
	elseif tag == "list_item" then
		self.__state.in_list_item = true
		self.__state.list_item_task = attrs.task
		self.__state.list_item_checked = attrs.checked

		-- Mark parent list as having tasks if this is a task item
		if attrs.task and #self.__state.list_stack > 0 then
			self.__state.list_stack[#self.__state.list_stack].has_task = true
		end

		if attrs.task then
			self.__state.output:put('<li class="task-item">')
			local checkbox = attrs.checked and '<input type="checkbox" disabled checked> '
				or '<input type="checkbox" disabled> '
			self.__state.output:put(checkbox)
		else
			self.__state.output:put("<li>")
		end
	elseif tag == "table" then
		self.__state.in_table = true
		self.__state.output:put("<table>\n")
	elseif tag == "table_head" then
		self.__state.in_table_head = true
		self.__state.output:put("<thead>\n")
	elseif tag == "table_body" then
		self.__state.in_table_body = true
		self.__state.output:put("<tbody>\n")
	elseif tag == "table_row" then
		self.__state.in_table_row = true
		self.__state.output:put("<tr>")
	elseif tag == "table_cell" then
		self.__state.in_table_cell = true
		local cell_tag = attrs.header and "th" or "td"
		local html_attrs = {}
		if attrs.align and attrs.align ~= "left" then
			html_attrs.style = "text-align: " .. attrs.align
		end
		self.__state.output:put("<", cell_tag, build_attrs(html_attrs), ">")
		self.__state.table_cell_tag = cell_tag
	elseif tag == "blockquote" then
		self.__state.blockquote_depth = (self.__state.blockquote_depth or 0) + 1
		self.__state.output:put("<blockquote>\n")
	elseif tag == "div" then
		local html_attrs = {}
		if attrs.class then
			html_attrs.class = attrs.class
		end
		self.__state.div_stack[#self.__state.div_stack + 1] = attrs
		self.__state.output:put("<div", build_attrs(html_attrs), ">\n")
	elseif tag == "footnotes" then
		self.__state.in_footnotes = true
		self.__state.output:put('<section class="footnotes">\n<hr>\n<ol>\n')
	elseif tag == "footnote" then
		self.__state.in_footnote = true
		self.__state.footnote_label = attrs.label
		self.__state.footnote_index = attrs.index
		self.__state.output:put('<li id="fn-', attr_escape(attrs.label), '">')
	end
end

-- Handle block_end events
local handle_block_end = function(self, tag)
	if tag == "para" then
		self.__state.in_paragraph = false
		self.__state.output:put("</p>\n")
	elseif tag == "heading" then
		self.__state.in_heading = false
		self.__state.output:put("</h", tostring(self.__state.heading_level), ">\n")
		self.__state.heading_level = 0
	elseif tag == "code_block" then
		self.__state.in_code_block = false
		local lang_class = ""
		if self.__state.code_block_lang and self.__state.code_block_lang ~= "" then
			lang_class = ' class="language-' .. attr_escape(self.__state.code_block_lang) .. '"'
		end
		self.__state.output:put(
			"<pre><code",
			lang_class,
			">",
			html_escape(self.__state.code_block_content),
			"</code></pre>\n"
		)
		self.__state.code_block_lang = nil
		self.__state.code_block_content = ""
	elseif tag == "list" then
		local list_info = self.__state.list_stack[#self.__state.list_stack]
		self.__state.list_stack[#self.__state.list_stack] = nil

		if list_info then
			-- If the list had task items, add class to ul (need to rewrite opening tag)
			-- Since we can't go back, we just close normally
			if list_info.ordered then
				self.__state.output:put("</ol>\n")
			else
				self.__state.output:put("</ul>\n")
			end
		end
	elseif tag == "list_item" then
		self.__state.in_list_item = false
		self.__state.list_item_task = nil
		self.__state.list_item_checked = nil
		self.__state.output:put("</li>\n")
	elseif tag == "table" then
		self.__state.in_table = false
		self.__state.output:put("</table>\n")
	elseif tag == "table_head" then
		self.__state.in_table_head = false
		self.__state.output:put("</thead>\n")
	elseif tag == "table_body" then
		self.__state.in_table_body = false
		self.__state.output:put("</tbody>\n")
	elseif tag == "table_row" then
		self.__state.in_table_row = false
		self.__state.output:put("</tr>\n")
	elseif tag == "table_cell" then
		self.__state.in_table_cell = false
		self.__state.output:put("</", self.__state.table_cell_tag or "td", ">")
		self.__state.table_cell_tag = nil
	elseif tag == "blockquote" then
		self.__state.blockquote_depth = (self.__state.blockquote_depth or 1) - 1
		self.__state.output:put("</blockquote>\n")
	elseif tag == "div" then
		self.__state.div_stack[#self.__state.div_stack] = nil
		self.__state.output:put("</div>\n")
	elseif tag == "footnotes" then
		self.__state.in_footnotes = false
		self.__state.output:put("</ol>\n</section>\n")
	elseif tag == "footnote" then
		self.__state.in_footnote = false
		-- Add backref link
		self.__state.output:put(
			' <a href="#fnref-',
			attr_escape(self.__state.footnote_label),
			'" class="footnote-backref">↩</a></li>\n'
		)
		self.__state.footnote_label = nil
		self.__state.footnote_index = nil
	end
end

-- Handle inline_start events
local handle_inline_start = function(self, tag, attrs)
	attrs = attrs or {}

	-- Push to inline stack
	self.__state.inline_stack[#self.__state.inline_stack + 1] = { tag = tag, attrs = attrs }

	if tag == "strong" then
		self.__state.output:put("<strong>")
	elseif tag == "emph" then
		self.__state.output:put("<em>")
	elseif tag == "code" then
		local html_attrs = {}
		if attrs.class then
			html_attrs.class = attrs.class
		end
		self.__state.output:put("<code", build_attrs(html_attrs), ">")
	elseif tag == "link" then
		local html_attrs = {}
		html_attrs.href = attrs.href or ""
		if attrs.title and attrs.title ~= "" then
			html_attrs.title = attrs.title
		end
		if attrs.class then
			html_attrs.class = attrs.class
		end
		self.__state.output:put("<a", build_attrs(html_attrs), ">")
	elseif tag == "image" then
		-- Start accumulating alt text
		self.__state.in_image = true
		self.__state.image_alt = ""
		self.__state.image_attrs = attrs
	elseif tag == "strikethrough" then
		self.__state.output:put("<del>")
	elseif tag == "footnote_ref" then
		-- Footnote reference: render immediately as it has no content
		local label = attrs.label or ""
		local index = attrs.index or label
		self.__state.output:put(
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
	if #self.__state.inline_stack > 0 then
		self.__state.inline_stack[#self.__state.inline_stack] = nil
	end

	if tag == "strong" then
		self.__state.output:put("</strong>")
	elseif tag == "emph" then
		self.__state.output:put("</em>")
	elseif tag == "code" then
		self.__state.output:put("</code>")
	elseif tag == "link" then
		self.__state.output:put("</a>")
	elseif tag == "image" then
		-- Finish image tag with accumulated alt text
		self.__state.in_image = false
		local attrs = self.__state.image_attrs or {}
		local html_attrs = {}
		html_attrs.src = attrs.href or ""
		html_attrs.alt = self.__state.image_alt
		if attrs.title and attrs.title ~= "" then
			html_attrs.title = attrs.title
		end
		if attrs.class then
			html_attrs.class = attrs.class
		end
		self.__state.output:put("<img", build_attrs(html_attrs), ">")
		self.__state.image_alt = ""
		self.__state.image_attrs = nil
	elseif tag == "strikethrough" then
		self.__state.output:put("</del>")
	elseif tag == "footnote_ref" then
		-- Already rendered in inline_start, nothing to do
	end
end

-- Handle text events
local handle_text = function(self, text)
	if self.__state.in_code_block then
		-- Accumulate raw content for code blocks (will be escaped on output)
		self.__state.code_block_content = self.__state.code_block_content .. text
	elseif self.__state.in_image then
		-- Accumulate alt text (escape it)
		self.__state.image_alt = self.__state.image_alt .. html_escape(text)
	else
		-- Output escaped text
		self.__state.output:put(html_escape(text))
	end
end

-- Handle softbreak events
local handle_softbreak = function(self)
	-- Soft break becomes a newline in HTML
	self.__state.output:put("\n")
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
	while #self.__state.section_stack > 0 do
		self.__state.section_stack[#self.__state.section_stack] = nil
		self.__state.output:put("</section>\n")
	end
	return self.__state.output:get()
end

-- Reset renderer state for reuse
local reset = function(self)
	self.__state.output = buffer.new()
	self.__state.in_paragraph = false
	self.__state.in_heading = false
	self.__state.heading_level = 0
	self.__state.in_code_block = false
	self.__state.code_block_lang = nil
	self.__state.code_block_content = ""
	self.__state.inline_stack = {}
	self.__state.list_stack = {}
	self.__state.in_list_item = false
	self.__state.list_item_task = nil
	self.__state.list_item_checked = nil
	self.__state.in_table = false
	self.__state.in_table_head = false
	self.__state.in_table_body = false
	self.__state.in_table_row = false
	self.__state.in_table_cell = false
	self.__state.table_cell_tag = nil
	self.__state.blockquote_depth = 0
	self.__state.div_stack = {}
	self.__state.section_stack = {}
	self.__state.in_footnotes = false
	self.__state.in_footnote = false
	self.__state.footnote_label = nil
	self.__state.footnote_index = nil
	self.__state.in_image = false
	self.__state.image_alt = ""
	self.__state.image_attrs = nil
end

-- Create a new HTML renderer instance
local new = function(options)
	local renderer = {
		cfg = options or {},
		__state = {},
		render_event = render_event,
		finish = finish,
		reset = reset,
	}
	reset(renderer)
	return renderer
end

-- Module export
return {
	new = new,
}
