-- SPDX-FileCopyrightText: © 2022—2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: LicenseRef-OWL-1.0-or-later OR GPL-3.0-or-later
-- Dual-licensed under OWL v1.0+ and GPLv3+. See LICENSE and LICENSE-GPL3.

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
	if self.__state.callback then
		self.__state.callback(event)
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
	self.__state.callback = fn
end

-- Create a new event emitter
local new = function(on_event)
	local cfg = {
		on_event = on_event,
	}

	return {
		cfg = cfg,
		__state = {
			callback = cfg.on_event,
		},
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
