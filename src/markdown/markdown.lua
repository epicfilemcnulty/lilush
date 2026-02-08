-- SPDX-FileCopyrightText: © 2022—2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: LicenseRef-OWL-1.0-or-later OR GPL-3.0-or-later
-- Dual-licensed under OWL v1.0+ and GPLv3+. See LICENSE and LICENSE-GPL3.

--[[
Markdown parser/renderer module for Lilush.

Provides streaming markdown parsing with callback-based event emission.

Usage:

-- Streaming API (for LLM)
local parser = markdown.stream({
    on_event = function(event)
        print(event.type, event.tag)
    end,
})
parser:feed(chunk)
parser:finish()

-- Convenience: parse and collect events
local events = markdown.parse(input)
for _, event in ipairs(events) do
    print(event.type, event.tag)
end
]]

local parser = require("markdown.parser")
local renderer_registry = require("markdown.renderer")

-- Streaming API - returns a parser instance
-- options.on_event: callback function(event) invoked for each event
local stream = function(options)
	return parser.new(options)
end

-- Static rendering using the specified renderer
-- options:
--   renderer: string - renderer name ("static" default, "streaming" future)
--   width: number - content width (default 80)
--   rss: table - custom renderer style sheet to merge with defaults
--   indent: number - global indentation (default 0)
--   hide_link_urls: boolean - hide URLs in rendered output (default false)
--   supports_ts: boolean - whether terminal supports OSC 66 text sizing (default true)
--   return_metadata: boolean - return { rendered, elements } instead of just string (default false)
local render = function(input, options)
	options = options or {}
	local renderer_name = options.renderer or "static"

	-- Create renderer instance
	local r, err = renderer_registry.create(renderer_name, {
		width = options.width or 80,
		rss = options.rss,
		indent = options.indent or 0,
		hide_link_urls = options.hide_link_urls or false,
		supports_ts = options.supports_ts,
	})

	if not r then
		return nil, err
	end

	-- Parse input and feed events to renderer
	local p = parser.new({
		on_event = function(e)
			r:render_event(e)
		end,
		inline = true,
		streaming_inline = false, -- Static rendering doesn't need streaming inline
	})

	p:feed(input or "")
	p:finish()

	local result = r:finish()

	-- For backward compatibility, return just string unless metadata requested
	if options.return_metadata then
		return result -- { rendered, elements }
	end
	return result.rendered
end

-- AST generation (stub for later phases)
local to_ast = function(input)
	-- Will be implemented in later phases
	return nil, "not implemented"
end

-- HTML rendering convenience function
-- Returns HTML string from markdown input
local render_html = function(input, options)
	options = options or {}

	-- Create HTML renderer instance
	local r, err = renderer_registry.create("html", options)
	if not r then
		return nil, err
	end

	-- Parse input and feed events to renderer
	local p = parser.new({
		on_event = function(e)
			r:render_event(e)
		end,
		inline = true,
		streaming_inline = false,
	})

	p:feed(input or "")
	p:finish()

	return r:finish()
end

-- Convenience: parse input and collect events into an array
-- Useful for testing and non-streaming use cases
-- Options:
--   inline: boolean (default true) - whether to parse inline elements
--   streaming_inline: boolean (default true) - emit inline events incrementally
local parse = function(input, options)
	options = options or {}
	local collected = {}
	local p = parser.new({
		on_event = options.on_event or function(e)
			collected[#collected + 1] = e
		end,
		inline = options.inline,
		streaming_inline = options.streaming_inline,
	})
	p:feed(input)
	p:finish()
	return collected
end

return {
	stream = stream,
	render = render,
	render_html = render_html,
	to_ast = to_ast,
	parse = parse,
}
