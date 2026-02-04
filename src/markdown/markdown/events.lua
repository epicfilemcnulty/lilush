-- SPDX-FileCopyrightText: © 2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: OWL-1.0 or later
-- Licensed under the Open Weights License v1.0. See LICENSE for details.

--[[
Event emitter for the markdown parser.

Callback-based emitter that invokes handlers immediately as events occur,
enabling true streaming rendering.

Event format:
{
    type = "block_start" | "block_end" | "inline_start" | "inline_end" | "text" | "softbreak",
    tag = "para" | "heading" | "code_block" | "thematic_break" |
          "strong" | "emph" | "code" | "link" | "image",
    text = string | nil,
    attrs = { level, lang, href, title, ... } | nil,
}

Block events:
  - block_start/block_end with tag: para, heading, code_block, thematic_break, blockquote, list, list_item

Inline events:
  - inline_start/inline_end with tag: strong, emph, code, link, image
  - text: plain text content
  - softbreak: soft line break within a block

Inline element attrs:
  - link: { href = "url", title = "optional title" }
  - image: { href = "url", title = "optional title" } (href is the src)
  - code: none (content is in nested text event)
]]

-- Emit an event to the callback
local emit = function(self, event)
	if self._callback then
		self._callback(event)
	end
end

-- Emit a block start event
local emit_block_start = function(self, tag, attrs)
	self:emit({ type = "block_start", tag = tag, attrs = attrs })
end

-- Emit a block end event
local emit_block_end = function(self, tag)
	self:emit({ type = "block_end", tag = tag })
end

-- Emit a text event
local emit_text = function(self, text)
	if text and text ~= "" then
		self:emit({ type = "text", text = text })
	end
end

-- Emit an inline start event
local emit_inline_start = function(self, tag, attrs)
	self:emit({ type = "inline_start", tag = tag, attrs = attrs })
end

-- Emit an inline end event
local emit_inline_end = function(self, tag)
	self:emit({ type = "inline_end", tag = tag })
end

-- Emit a softbreak event
local emit_softbreak = function(self)
	self:emit({ type = "softbreak" })
end

-- Change the callback function
local set_callback = function(self, fn)
	self._callback = fn
end

-- Create a new event emitter
local new = function(on_event)
	return {
		_callback = on_event,
		emit = emit,
		emit_block_start = emit_block_start,
		emit_block_end = emit_block_end,
		emit_inline_start = emit_inline_start,
		emit_inline_end = emit_inline_end,
		emit_text = emit_text,
		emit_softbreak = emit_softbreak,
		set_callback = set_callback,
	}
end

return { new = new }
