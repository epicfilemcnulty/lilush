-- SPDX-FileCopyrightText: © 2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: OWL-1.0 or later
-- Licensed under the Open Weights License v1.0. See LICENSE for details.

local testimony = require("testimony")
local markdown = require("markdown")
local renderer_registry = require("markdown.renderer")
local html_renderer = require("markdown.renderer.html")

local testify = testimony.new("== markdown.renderer.html ==")

-- Helper to check if string contains substring
local function contains(str, substr)
	return str:find(substr, 1, true) ~= nil
end

-- Helper to normalize whitespace for comparison
local function normalize_ws(str)
	return str:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
end

-- ============================================
-- Renderer Registry Tests
-- ============================================

testify:that("renderer registry returns html renderer", function()
	local mod, err = renderer_registry.get("html")
	testimony.assert_not_nil(mod)
	testimony.assert_nil(err)
	testimony.assert_not_nil(mod.new)
end)

testify:that("renderer registry create returns html instance", function()
	local r, err = renderer_registry.create("html", {})
	testimony.assert_not_nil(r)
	testimony.assert_nil(err)
	testimony.assert_not_nil(r.render_event)
	testimony.assert_not_nil(r.finish)
end)

-- ============================================
-- markdown.render_html Function Tests
-- ============================================

testify:that("markdown.render_html returns string", function()
	local result = markdown.render_html("Hello world")
	testimony.assert_equal("string", type(result))
end)

testify:that("markdown.render_html handles empty input", function()
	local result = markdown.render_html("")
	testimony.assert_equal("string", type(result))
end)

testify:that("markdown.render_html handles nil input", function()
	local result = markdown.render_html(nil)
	testimony.assert_equal("string", type(result))
end)

-- ============================================
-- Paragraph Rendering Tests
-- ============================================

testify:that("renders simple paragraph", function()
	local result = markdown.render_html("Hello world")
	testimony.assert_true(contains(result, "<p>"))
	testimony.assert_true(contains(result, "</p>"))
	testimony.assert_true(contains(result, "Hello world"))
end)

testify:that("renders multiple paragraphs", function()
	local result = markdown.render_html("First paragraph.\n\nSecond paragraph.")
	local count = 0
	for _ in result:gmatch("<p>") do
		count = count + 1
	end
	testimony.assert_equal(2, count)
end)

-- ============================================
-- Heading Rendering Tests
-- ============================================

testify:that("renders h1 heading", function()
	local result = markdown.render_html("# Heading 1")
	testimony.assert_true(contains(result, "<h1>"))
	testimony.assert_true(contains(result, "</h1>"))
	testimony.assert_true(contains(result, "Heading 1"))
end)

testify:that("renders h2 heading", function()
	local result = markdown.render_html("## Heading 2")
	testimony.assert_true(contains(result, "<h2>"))
	testimony.assert_true(contains(result, "</h2>"))
end)

testify:that("renders h3 through h6 headings", function()
	for level = 3, 6 do
		local md = string.rep("#", level) .. " Heading " .. level
		local result = markdown.render_html(md)
		testimony.assert_true(contains(result, "<h" .. level .. ">"))
		testimony.assert_true(contains(result, "</h" .. level .. ">"))
	end
end)

-- ============================================
-- Section Wrapping Tests (h2+ get wrapped in <section>)
-- ============================================

testify:that("h1 does not get section wrapper", function()
	local result = markdown.render_html("# Main Title")
	testimony.assert_false(contains(result, "<section>"))
	testimony.assert_true(contains(result, "<h1>"))
end)

testify:that("h2 creates section wrapper", function()
	local result = markdown.render_html("## Section Title")
	testimony.assert_true(contains(result, "<section>"))
	testimony.assert_true(contains(result, "</section>"))
	testimony.assert_true(contains(result, "<h2>"))
end)

testify:that("h3 creates nested section inside h2 section", function()
	local result = markdown.render_html("## Main\n\n### Sub")
	-- Should have 2 sections (h2 and nested h3)
	local section_count = 0
	for _ in result:gmatch("<section>") do
		section_count = section_count + 1
	end
	testimony.assert_equal(2, section_count)
end)

testify:that("h2 closes previous h3 section", function()
	local md = "## First\n\n### Sub\n\n## Second"
	local result = markdown.render_html(md)
	-- h2 "Second" should close h3's section and h2 "First"'s section, then open new
	-- Total: 3 section opens, 3 section closes
	local open_count = 0
	local close_count = 0
	for _ in result:gmatch("<section>") do
		open_count = open_count + 1
	end
	for _ in result:gmatch("</section>") do
		close_count = close_count + 1
	end
	testimony.assert_equal(3, open_count)
	testimony.assert_equal(3, close_count)
end)

testify:that("multiple h2s each get own section", function()
	local result = markdown.render_html("## First\n\n## Second\n\n## Third")
	local section_count = 0
	for _ in result:gmatch("<section>") do
		section_count = section_count + 1
	end
	testimony.assert_equal(3, section_count)
end)

testify:that("document end closes all open sections", function()
	local result = markdown.render_html("## Main\n\n### Sub\n\nContent")
	local open_count = 0
	local close_count = 0
	for _ in result:gmatch("<section>") do
		open_count = open_count + 1
	end
	for _ in result:gmatch("</section>") do
		close_count = close_count + 1
	end
	testimony.assert_equal(open_count, close_count)
end)

testify:that("complex hierarchy closes correctly", function()
	-- h2 -> h3 -> h4 -> h2 should close h4, h3, and h2 before opening new h2
	local md = "## A\n\n### B\n\n#### C\n\n## D"
	local result = markdown.render_html(md)
	-- Total: 4 sections (h2 A, h3 B, h4 C, h2 D)
	local open_count = 0
	for _ in result:gmatch("<section>") do
		open_count = open_count + 1
	end
	testimony.assert_equal(4, open_count)
end)

testify:that("section contains heading and content", function()
	local result = markdown.render_html("## Title\n\nContent paragraph.")
	-- Section should wrap both heading and paragraph
	testimony.assert_true(contains(result, "<section>\n<h2>Title</h2>"))
	testimony.assert_true(contains(result, "<p>Content paragraph.</p>"))
end)

-- ============================================
-- Inline Formatting Tests
-- ============================================

testify:that("renders strong (bold) text", function()
	local result = markdown.render_html("This is **bold** text")
	testimony.assert_true(contains(result, "<strong>"))
	testimony.assert_true(contains(result, "</strong>"))
	testimony.assert_true(contains(result, "bold"))
end)

testify:that("renders emphasis (italic) text", function()
	local result = markdown.render_html("This is *italic* text")
	testimony.assert_true(contains(result, "<em>"))
	testimony.assert_true(contains(result, "</em>"))
	testimony.assert_true(contains(result, "italic"))
end)

testify:that("renders inline code", function()
	local result = markdown.render_html("Use `code` here")
	testimony.assert_true(contains(result, "<code>"))
	testimony.assert_true(contains(result, "</code>"))
	testimony.assert_true(contains(result, "code"))
end)

testify:that("renders strikethrough", function()
	local result = markdown.render_html("This is ~~deleted~~ text")
	testimony.assert_true(contains(result, "<del>"))
	testimony.assert_true(contains(result, "</del>"))
	testimony.assert_true(contains(result, "deleted"))
end)

testify:that("renders nested inline elements", function()
	local result = markdown.render_html("This is ***bold and italic*** text")
	testimony.assert_true(contains(result, "<strong>"))
	testimony.assert_true(contains(result, "<em>"))
end)

-- ============================================
-- Link Tests
-- ============================================

testify:that("renders basic link", function()
	local result = markdown.render_html("[click here](https://example.com)")
	testimony.assert_true(contains(result, '<a href="https://example.com"'))
	testimony.assert_true(contains(result, "</a>"))
	testimony.assert_true(contains(result, "click here"))
end)

testify:that("renders link with title", function()
	local result = markdown.render_html('[click](https://example.com "Example Site")')
	testimony.assert_true(contains(result, 'href="https://example.com"'))
	testimony.assert_true(contains(result, 'title="Example Site"'))
end)

-- ============================================
-- Image Tests
-- ============================================

testify:that("renders basic image", function()
	local result = markdown.render_html("![Alt text](image.png)")
	testimony.assert_true(contains(result, '<img'))
	testimony.assert_true(contains(result, 'src="image.png"'))
	testimony.assert_true(contains(result, 'alt="Alt text"'))
end)

testify:that("renders image with title", function()
	local result = markdown.render_html('![Alt](image.png "Image Title")')
	testimony.assert_true(contains(result, 'title="Image Title"'))
end)

-- ============================================
-- Code Block Tests
-- ============================================

testify:that("renders fenced code block", function()
	local result = markdown.render_html("```\ncode here\n```")
	testimony.assert_true(contains(result, "<pre>"))
	testimony.assert_true(contains(result, "<code>"))
	testimony.assert_true(contains(result, "</code>"))
	testimony.assert_true(contains(result, "</pre>"))
	testimony.assert_true(contains(result, "code here"))
end)

testify:that("renders code block with language", function()
	local result = markdown.render_html("```python\ndef hello():\n    pass\n```")
	testimony.assert_true(contains(result, 'class="language-python"'))
	testimony.assert_true(contains(result, "def hello():"))
end)

testify:that("escapes HTML in code blocks", function()
	local result = markdown.render_html("```\n<div>&test</div>\n```")
	testimony.assert_true(contains(result, "&lt;div&gt;"))
	testimony.assert_true(contains(result, "&amp;test"))
end)

-- ============================================
-- List Tests
-- ============================================

testify:that("renders unordered list", function()
	local result = markdown.render_html("- Item 1\n- Item 2\n- Item 3")
	testimony.assert_true(contains(result, "<ul>"))
	testimony.assert_true(contains(result, "</ul>"))
	testimony.assert_true(contains(result, "<li>"))
	testimony.assert_true(contains(result, "</li>"))
end)

testify:that("renders ordered list", function()
	local result = markdown.render_html("1. First\n2. Second\n3. Third")
	testimony.assert_true(contains(result, "<ol>"))
	testimony.assert_true(contains(result, "</ol>"))
	testimony.assert_true(contains(result, "<li>"))
end)

testify:that("renders ordered list with custom start", function()
	local result = markdown.render_html("5. Fifth item\n6. Sixth item")
	testimony.assert_true(contains(result, 'start="5"'))
end)

testify:that("renders task list", function()
	local result = markdown.render_html("- [x] Checked\n- [ ] Unchecked")
	testimony.assert_true(contains(result, 'class="task-item"'))
	testimony.assert_true(contains(result, '<input type="checkbox" disabled checked>'))
	testimony.assert_true(contains(result, '<input type="checkbox" disabled>'))
end)

testify:that("renders nested lists", function()
	local result = markdown.render_html("- Item 1\n  - Nested 1\n  - Nested 2\n- Item 2")
	-- Check for multiple ul/li pairs indicating nesting
	local ul_count = 0
	for _ in result:gmatch("<ul>") do
		ul_count = ul_count + 1
	end
	testimony.assert_true(ul_count >= 2)
end)

-- ============================================
-- Table Tests
-- ============================================

testify:that("renders basic table", function()
	local result = markdown.render_html("| A | B |\n|---|---|\n| 1 | 2 |")
	testimony.assert_true(contains(result, "<table>"))
	testimony.assert_true(contains(result, "</table>"))
	testimony.assert_true(contains(result, "<thead>"))
	testimony.assert_true(contains(result, "<tbody>"))
	testimony.assert_true(contains(result, "<th>"))
	testimony.assert_true(contains(result, "<td>"))
end)

testify:that("renders table with alignment", function()
	local result = markdown.render_html("| Left | Center | Right |\n|:-----|:------:|------:|\n| a | b | c |")
	testimony.assert_true(contains(result, 'text-align: center'))
	testimony.assert_true(contains(result, 'text-align: right'))
end)

-- ============================================
-- Blockquote Tests
-- ============================================

testify:that("renders blockquote", function()
	local result = markdown.render_html("> This is quoted text")
	testimony.assert_true(contains(result, "<blockquote>"))
	testimony.assert_true(contains(result, "</blockquote>"))
	testimony.assert_true(contains(result, "This is quoted text"))
end)

testify:that("renders blockquote with multiple lines", function()
	local result = markdown.render_html("> Line 1\n> Line 2")
	testimony.assert_true(contains(result, "<blockquote>"))
	testimony.assert_true(contains(result, "Line 1"))
	testimony.assert_true(contains(result, "Line 2"))
end)

-- ============================================
-- Thematic Break Tests
-- ============================================

testify:that("renders thematic break", function()
	local result = markdown.render_html("---")
	testimony.assert_true(contains(result, "<hr>"))
end)

testify:that("renders thematic break with asterisks", function()
	local result = markdown.render_html("***")
	testimony.assert_true(contains(result, "<hr>"))
end)

-- ============================================
-- Fenced Div Tests (Djot Extension)
-- ============================================

testify:that("renders fenced div with class", function()
	local result = markdown.render_html("::: warning\nWarning content\n:::")
	testimony.assert_true(contains(result, '<div class="warning">'))
	testimony.assert_true(contains(result, "</div>"))
	testimony.assert_true(contains(result, "Warning content"))
end)

testify:that("renders nested fenced divs", function()
	local result = markdown.render_html("::: outer\n:::: inner\nContent\n::::\n:::")
	local div_count = 0
	for _ in result:gmatch("<div") do
		div_count = div_count + 1
	end
	testimony.assert_true(div_count >= 2)
end)

-- ============================================
-- Inline Attributes Tests (Djot Extension)
-- ============================================

testify:that("renders inline code with class attribute", function()
	local result = markdown.render_html("`value`{.num}")
	testimony.assert_true(contains(result, '<code class="num">'))
end)

-- ============================================
-- Footnote Tests
-- ============================================

testify:that("renders footnote reference", function()
	local result = markdown.render_html("[^note]: Footnote text\n\nSome text[^note].")
	testimony.assert_true(contains(result, 'id="fnref-note"'))
	testimony.assert_true(contains(result, 'href="#fn-note"'))
end)

testify:that("renders footnote definition", function()
	local result = markdown.render_html("[^1]: This is the footnote.\n\nText[^1].")
	testimony.assert_true(contains(result, 'class="footnotes"'))
	testimony.assert_true(contains(result, 'id="fn-1"'))
	testimony.assert_true(contains(result, 'class="footnote-backref"'))
end)

-- ============================================
-- HTML Escaping Tests
-- ============================================

testify:that("escapes HTML entities in text", function()
	local result = markdown.render_html("Use <div> and & characters")
	testimony.assert_true(contains(result, "&lt;div&gt;"))
	testimony.assert_true(contains(result, "&amp;"))
end)

testify:that("escapes quotes in attributes", function()
	local result = markdown.render_html('[link](https://example.com?a="b")')
	-- The URL should have escaped quotes
	testimony.assert_true(contains(result, 'href="'))
end)

-- ============================================
-- Integration Tests
-- ============================================

testify:that("renders complex document", function()
	local md = [[
# Main Title

This is a paragraph with **bold** and *italic* text.

## Code Example

```lua
local x = 1
```

- Item with `code`
- Item with [link](https://example.com)

> A blockquote with **emphasis**

| Col 1 | Col 2 |
|-------|-------|
| A     | B     |
]]
	local result = markdown.render_html(md)
	testimony.assert_true(contains(result, "<h1>"))
	testimony.assert_true(contains(result, "<h2>"))
	testimony.assert_true(contains(result, "<strong>"))
	testimony.assert_true(contains(result, "<em>"))
	testimony.assert_true(contains(result, '<code class="language-lua">'))
	testimony.assert_true(contains(result, "<ul>"))
	testimony.assert_true(contains(result, "<blockquote>"))
	testimony.assert_true(contains(result, "<table>"))
end)

-- Run tests
testify:conclude()
