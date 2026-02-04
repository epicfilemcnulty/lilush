-- SPDX-FileCopyrightText: © 2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: OWL-1.0 or later
-- Licensed under the Open Weights License v1.0. See LICENSE for details.

--[[
Block state machine definitions for the markdown parser.

Defines block types and their detection/continuation logic.

Pattern matching notes:
- We use [ \t] for horizontal whitespace instead of %s, because %s also
  matches \n, \r, \f, \v which we don't want for line-based markdown parsing
  where newlines are handled separately by the parser.
- Lua patterns lack {n,m} quantifiers, so we use loops or explicit repetition
  for things like "0-3 spaces" (CommonMark indent limit).
- We use string.find() for simple boolean checks as it's faster than match().

UTF-8 Safety:
All string operations in this module are UTF-8 safe because:
1. Markdown block syntax markers (# ` ~ - * _ space tab) are ASCII single-byte
2. We use byte indexing only for these ASCII markers
3. Content (headings, code, paragraphs) passes through unmodified
4. Pattern captures like (.-) preserve arbitrary UTF-8 content
When character-based operations are needed (e.g., display width), use std.utf.
]]

-- Helper: strip up to max leading spaces, return rest of line and indent count
-- Returns nil if there are more than max leading spaces (invalid indent)
-- Only counts spaces, not tabs, per CommonMark indent rules
local function strip_leading_indent(line, max)
	local count = 0
	for i = 1, max do
		if line:sub(i, i) == " " then
			count = i
		else
			break
		end
	end
	-- If there's still a space after the counted ones, indent exceeds max
	if line:sub(count + 1, count + 1) == " " then
		return nil, 0
	end
	return line:sub(count + 1), count
end

-- Check if a line is blank (empty or contains only horizontal whitespace)
-- Using find() is faster than match() for simple boolean checks
local function is_blank_line(line)
	return not line:find("[^ \t]")
end

-- Detect ATX heading (# through ######)
-- Returns level (1-6) and content, or nil if not a heading
local function detect_heading(line)
	-- ATX heading: 0-3 leading spaces, 1-6 hashes, then space+content or EOL
	local rest, indent = strip_leading_indent(line, 3)
	if not rest then
		return nil -- Too much indentation (4+ spaces)
	end

	-- Match hashes at start
	local hashes = rest:match("^(#+)")
	if not hashes or #hashes < 1 or #hashes > 6 then
		return nil
	end

	local after_hashes = rest:sub(#hashes + 1)

	-- After hashes must be: EOL, whitespace only, or whitespace + content
	-- A heading like "#foo" (no space) is NOT valid
	if after_hashes == "" then
		-- Just hashes, valid empty heading
		return #hashes, ""
	end

	-- Must have space or tab after hashes
	local first_char = after_hashes:sub(1, 1)
	if first_char ~= " " and first_char ~= "\t" then
		return nil
	end

	-- Extract content: strip leading whitespace
	local content = after_hashes:match("^[ \t]+(.*)$") or ""

	-- Strip optional closing hashes: whitespace + hashes + optional whitespace at end
	content = content:gsub("[ \t]+#+[ \t]*$", "")
	-- Strip trailing whitespace
	content = content:gsub("[ \t]+$", "")

	return #hashes, content
end

-- Detect fenced code block opening
-- Returns: fence_char (` or ~), fence_len, info_string, indent
-- or nil if not a code fence
local function detect_code_fence_open(line)
	-- Fenced code block: 0-3 spaces, 3+ backticks or tildes, optional info string
	local rest, indent = strip_leading_indent(line, 3)
	if not rest then
		return nil -- Too much indentation (4+ spaces)
	end

	-- Try backtick fence: 3+ backticks
	local fence = rest:match("^(`+)")
	if fence and #fence >= 3 then
		local info = rest:sub(#fence + 1)
		-- CommonMark: backtick info string cannot contain backticks
		if not info:find("`") then
			-- Trim whitespace from info string
			info = info:match("^[ \t]*(.-)[ \t]*$") or ""
			return "`", #fence, info, indent
		end
	end

	-- Try tilde fence: 3+ tildes (info string can contain anything)
	fence = rest:match("^(~+)")
	if fence and #fence >= 3 then
		local info = rest:sub(#fence + 1)
		info = info:match("^[ \t]*(.-)[ \t]*$") or ""
		return "~", #fence, info, indent
	end

	return nil
end

-- Check if a line closes a code fence
-- fence_char: the opening fence character (` or ~)
-- fence_len: minimum length required (must be >= opening fence length)
local function is_code_fence_close(line, fence_char, fence_len)
	-- Closing fence: 0-3 spaces, >= fence_len of same char, only whitespace after
	local rest = strip_leading_indent(line, 3)
	if not rest then
		return false -- Too much indentation (4+ spaces)
	end

	-- Match fence characters at start
	-- Using character class [x] where x is ` or ~ (neither needs escaping)
	local fence = rest:match("^([" .. fence_char .. "]+)")
	if not fence or #fence < fence_len then
		return false
	end

	-- After fence must be only whitespace (or nothing)
	local after_fence = rest:sub(#fence + 1)
	return not after_fence:find("[^ \t]")
end

-- Detect thematic break (---, ***, ___)
-- Returns true if line is a valid thematic break
local function detect_thematic_break(line)
	-- Thematic break: 0-3 spaces, then 3+ of same char (-, *, _)
	-- with optional spaces/tabs between characters
	local rest = strip_leading_indent(line, 3)
	if not rest then
		return false -- Too much indentation (4+ spaces)
	end

	-- Remove all horizontal whitespace to check the pattern chars
	local chars = rest:gsub("[ \t]", "")

	-- Empty after removing whitespace? Not a thematic break
	if chars == "" then
		return false
	end

	-- Must be 3+ of the same character and nothing else
	-- Note: underscore (_) is not a magic character in Lua patterns
	-- Dash (-) must be escaped as %- when not in a character class
	if #chars >= 3 then
		if chars:match("^%-+$") then
			return true
		end
		if chars:match("^%*+$") then
			return true
		end
		if chars:match("^_+$") then
			return true
		end
	end

	return false
end

-- Detect unordered list marker: -, *, +
-- Also detects task list items: - [ ] or - [x] or - [X]
-- Returns: marker_char, content, pre_indent, content_indent, task_info
-- where pre_indent is spaces before marker, content_indent is column where content starts
-- task_info is nil for normal items, or { checked = bool } for task items
local function detect_ul_marker(line)
	-- Unordered list: 0-3 spaces, then -, *, or +, then 1+ spaces, then content
	-- Task list: same but content starts with [ ] or [x] or [X]
	local rest, pre_indent = strip_leading_indent(line, 3)
	if not rest then
		return nil -- Too much indentation
	end

	-- Match marker and required space after it
	local marker, space_after, content = rest:match("^([%-%*%+])( +)(.*)$")
	if marker and #space_after >= 1 then
		-- content_indent = pre_indent + marker(1) + space_after
		local content_indent = pre_indent + 1 + #space_after

		-- Check for task list syntax: [ ], [x], or [X] at start of content
		local task_info = nil
		local checkbox, task_space, task_content = content:match("^(%[[ xX]%])( )(.*)$")
		if not checkbox then
			-- Also check for checkbox at end of line (empty task content)
			checkbox, task_space = content:match("^(%[[ xX]%])( *)$")
			if checkbox then
				task_content = ""
			end
		end

		if checkbox then
			local is_checked = (checkbox == "[x]" or checkbox == "[X]")
			task_info = { checked = is_checked }
			content = task_content or ""
			-- Adjust content_indent to account for checkbox
			content_indent = content_indent + #checkbox + (task_space and #task_space or 0)
		end

		return marker, content, pre_indent, content_indent, task_info
	end

	-- Also handle marker at end of line (empty item): "- " with nothing after
	marker, space_after = rest:match("^([%-%*%+])( *)$")
	if marker and #space_after >= 1 then
		local content_indent = pre_indent + 1 + #space_after
		return marker, "", pre_indent, content_indent, nil
	end

	return nil
end

-- Detect ordered list marker: 1. or 1)
-- Returns: start_num, delimiter, content, pre_indent, content_indent
local function detect_ol_marker(line)
	-- Ordered list: 0-3 spaces, 1-9 digits, . or ), 1+ spaces, content
	local rest, pre_indent = strip_leading_indent(line, 3)
	if not rest then
		return nil -- Too much indentation
	end

	-- Match number + delimiter + space + content
	local num, delim, space_after, content = rest:match("^(%d+)([%.%)])( +)(.*)$")
	if num and #space_after >= 1 then
		local num_val = tonumber(num)
		-- CommonMark: ordered list numbers can be 1-9 digits (up to 999999999)
		if num_val and num_val <= 999999999 then
			local content_indent = pre_indent + #num + 1 + #space_after
			return num_val, delim, content, pre_indent, content_indent
		end
	end

	-- Also handle marker at end of line (empty item): "1. " with nothing after
	num, delim, space_after = rest:match("^(%d+)([%.%)])( *)$")
	if num and #space_after >= 1 then
		local num_val = tonumber(num)
		if num_val and num_val <= 999999999 then
			local content_indent = pre_indent + #num + 1 + #space_after
			return num_val, delim, "", pre_indent, content_indent
		end
	end

	return nil
end

-- Detect any list item (ordered or unordered)
-- Returns: "list_item", attrs table, or nil
local function detect_list_item(line)
	-- Try unordered first
	local marker, content, pre_indent, content_indent, task_info = detect_ul_marker(line)
	if marker then
		local attrs = {
			ordered = false,
			marker = marker,
			content = content,
			indent = pre_indent,
			content_indent = content_indent,
		}
		-- Add task list info if present
		if task_info then
			attrs.task = true
			attrs.checked = task_info.checked
		end
		return "list_item", attrs
	end

	-- Try ordered
	local num, delim, ol_content, ol_pre_indent, ol_content_indent = detect_ol_marker(line)
	if num then
		return "list_item",
			{
				ordered = true,
				start = num,
				delimiter = delim,
				content = ol_content,
				indent = ol_pre_indent,
				content_indent = ol_content_indent,
			}
	end

	return nil
end

-- Parse a GFM table row into cells
-- Returns: array of cell strings (trimmed), or nil if not a valid table row
-- A valid table row starts and ends with | (leading/trailing pipes are required for GFM)
local function parse_table_row(line)
	-- Must have at least one pipe
	if not line:find("|") then
		return nil
	end

	-- Split by unescaped pipes
	local cells = {}
	local current = ""
	local i = 1
	local len = #line
	local in_escape = false

	while i <= len do
		local c = line:sub(i, i)
		if in_escape then
			current = current .. c
			in_escape = false
		elseif c == "\\" then
			in_escape = true
			current = current .. c
		elseif c == "|" then
			-- Trim whitespace from cell
			local trimmed = current:match("^%s*(.-)%s*$")
			cells[#cells + 1] = trimmed
			current = ""
		else
			current = current .. c
		end
		i = i + 1
	end

	-- Add last cell (after final pipe or end of line)
	local trimmed = current:match("^%s*(.-)%s*$")
	cells[#cells + 1] = trimmed

	-- If first cell is empty (line starts with |), remove it
	if cells[1] == "" then
		table.remove(cells, 1)
	end
	-- If last cell is empty (line ends with |), remove it
	if #cells > 0 and cells[#cells] == "" then
		table.remove(cells)
	end

	-- Must have at least one cell
	if #cells == 0 then
		return nil
	end

	return cells
end

-- Detect GFM table delimiter row and parse alignments
-- Returns: array of alignments ("left", "center", "right"), or nil if not a delimiter row
-- A delimiter row looks like: |:---|:---:|---:|
local function detect_table_delimiter(line)
	local cells = parse_table_row(line)
	if not cells then
		return nil
	end

	local alignments = {}
	for _, cell in ipairs(cells) do
		-- Cell must be: optional :, one or more -, optional :
		-- With optional whitespace
		local trimmed = cell:match("^%s*(.-)%s*$")
		local left_colon = trimmed:sub(1, 1) == ":"
		local right_colon = trimmed:sub(-1) == ":"

		-- Remove colons for validation
		local dashes = trimmed:gsub("^:?", ""):gsub(":?$", "")

		-- Must have at least one dash and only dashes
		if dashes == "" or dashes:match("[^%-]") then
			return nil
		end

		-- Determine alignment
		if left_colon and right_colon then
			alignments[#alignments + 1] = "center"
		elseif right_colon then
			alignments[#alignments + 1] = "right"
		else
			alignments[#alignments + 1] = "left"
		end
	end

	return alignments
end

-- Detect block type from a line
-- Returns: block_type (string), attrs (table or nil)
-- block_type can be: "heading", "code_block", "thematic_break", "list_item", or nil (paragraph)
local function detect_block(line)
	-- Check for thematic break first (before heading, since --- could be setext)
	-- Also before list item, since "---" could be a thematic break or list item
	if detect_thematic_break(line) then
		return "thematic_break", nil
	end

	-- Check for heading
	local level, content = detect_heading(line)
	if level then
		return "heading", { level = level, content = content }
	end

	-- Check for code fence
	local fence_char, fence_len, lang, indent = detect_code_fence_open(line)
	if fence_char then
		return "code_block", { fence_char = fence_char, fence_len = fence_len, lang = lang, indent = indent }
	end

	-- Check for list item
	local list_type, list_attrs = detect_list_item(line)
	if list_type then
		return list_type, list_attrs
	end

	return nil
end

-- Check if a block type can interrupt a paragraph
-- Per CommonMark, certain blocks can start even in the middle of a paragraph
local function can_interrupt_paragraph(block_type, attrs)
	-- These block types can interrupt a paragraph
	local interrupters = {
		heading = true,
		thematic_break = true,
		code_block = true,
		list_item = true, -- Lists can interrupt paragraphs
	}
	return interrupters[block_type] or false
end

-- Detect link reference definition
-- Format: [label]: destination "optional title"
-- Returns: label, destination, title (or nil if not a link reference)
local function detect_link_reference(line)
	-- Link reference: 0-3 leading spaces, [label]:, destination, optional title
	local rest, indent = strip_leading_indent(line, 3)
	if not rest then
		return nil -- Too much indentation
	end

	-- Match [label]: pattern
	-- Label cannot contain unescaped brackets
	-- Label cannot start with ^ (that's a footnote)
	local label, after_label = rest:match("^%[([^%]]+)%]:(.*)$")
	if not label then
		return nil
	end

	-- Footnote labels start with ^, not link references
	if label:sub(1, 1) == "^" then
		return nil
	end

	-- Normalize label: collapse whitespace, lowercase for case-insensitive matching
	label = label:gsub("%s+", " "):lower()

	-- Parse destination (required)
	local remainder = after_label:match("^%s*(.*)$") -- trim leading space
	if remainder == "" then
		return nil -- No destination
	end

	local dest, title_part

	-- Check for angle-bracketed destination
	if remainder:sub(1, 1) == "<" then
		local close = remainder:find(">")
		if not close then
			return nil -- Unclosed angle bracket
		end
		dest = remainder:sub(2, close - 1)
		title_part = remainder:sub(close + 1)
	else
		-- Unbracketed destination: ends at whitespace
		dest, title_part = remainder:match("^(%S+)(.*)$")
		if not dest then
			return nil
		end
	end

	-- Parse optional title
	local title = nil
	if title_part then
		title_part = title_part:match("^%s*(.*)$") -- trim leading space
		if title_part ~= "" then
			-- Title can be in "...", '...', or (...)
			local quote_char = title_part:sub(1, 1)
			if quote_char == '"' or quote_char == "'" then
				-- Find matching close quote
				local close_pos = title_part:find(quote_char, 2, true)
				if close_pos then
					title = title_part:sub(2, close_pos - 1)
					-- Check nothing after title except whitespace
					local after = title_part:sub(close_pos + 1)
					if after:find("[^ \t]") then
						return nil -- Extra content after title
					end
				end
			elseif quote_char == "(" then
				local close_pos = title_part:find(")", 2, true)
				if close_pos then
					title = title_part:sub(2, close_pos - 1)
					local after = title_part:sub(close_pos + 1)
					if after:find("[^ \t]") then
						return nil
					end
				end
			elseif title_part:find("[^ \t]") then
				-- Non-whitespace content that's not a valid title
				return nil
			end
		end
	end

	return label, dest, title
end

-- Detect footnote definition
-- Format: [^label]: content
-- Returns: label, content (first line), or nil if not a footnote definition
local function detect_footnote_definition(line)
	-- Footnote definition: 0-3 leading spaces, [^label]:, content
	local rest, indent = strip_leading_indent(line, 3)
	if not rest then
		return nil -- Too much indentation
	end

	-- Match [^label]: pattern
	local label, content = rest:match("^%[%^([^%]]+)%]:%s*(.*)$")
	if not label then
		return nil
	end

	-- Normalize label for case-insensitive matching
	label = label:lower()

	return label, content, indent
end

-- Detect blockquote line
-- Format: > content (optional space after >)
-- Returns: content (after > marker), indent, or nil if not a blockquote line
local function detect_blockquote(line)
	-- Blockquote: 0-3 leading spaces, then >, optionally followed by space
	local rest, indent = strip_leading_indent(line, 3)
	if not rest then
		return nil -- Too much indentation (4+ spaces makes it code block)
	end

	-- Check for > marker
	if rest:sub(1, 1) ~= ">" then
		return nil
	end

	-- Get content after >
	local after_marker = rest:sub(2)

	-- Optional space after > is consumed
	if after_marker:sub(1, 1) == " " then
		return after_marker:sub(2), indent
	end

	return after_marker, indent
end

-- Check if a line can continue a blockquote (lazy continuation)
-- A non-blank line without > can continue a blockquote paragraph
local function is_blockquote_continuation(line)
	-- Lazy continuation: any non-blank line that isn't a block marker
	if is_blank_line(line) then
		return false
	end

	-- Check if it's already a blockquote line
	if detect_blockquote(line) then
		return false -- Not lazy continuation, it's a regular blockquote line
	end

	-- Check if it's a block that would interrupt the blockquote
	local block_type = detect_block(line)
	if block_type and can_interrupt_paragraph(block_type, nil) then
		return false
	end

	return true
end

-- Detect fenced div opening (Djot extension)
-- Format: :::+ optional_class
-- Returns: fence_len, class_name, indent (or nil if not a div fence)
local function detect_div_fence_open(line)
	-- Div fence: 0-3 leading spaces, 3+ colons, optional class name
	local rest, indent = strip_leading_indent(line, 3)
	if not rest then
		return nil -- Too much indentation
	end

	-- Match ::: pattern
	local fence = rest:match("^(:+)")
	if not fence or #fence < 3 then
		return nil
	end

	-- Get optional class name (first word after fence)
	local after_fence = rest:sub(#fence + 1)
	local class_name = after_fence:match("^%s*(%S*)") or ""

	return #fence, class_name, indent
end

-- Check if a line closes a div fence
-- fence_len: minimum length required (must be >= opening fence length)
local function is_div_fence_close(line, fence_len)
	-- Closing fence: 0-3 spaces, >= fence_len colons, only whitespace after
	local rest = strip_leading_indent(line, 3)
	if not rest then
		return false -- Too much indentation
	end

	-- Match colons at start
	local fence = rest:match("^(:+)")
	if not fence or #fence < fence_len then
		return false
	end

	-- After fence must be only whitespace (or nothing)
	local after_fence = rest:sub(#fence + 1)
	return not after_fence:find("[^ \t]")
end

return {
	is_blank_line = is_blank_line,
	detect_heading = detect_heading,
	detect_code_fence_open = detect_code_fence_open,
	is_code_fence_close = is_code_fence_close,
	detect_thematic_break = detect_thematic_break,
	detect_ul_marker = detect_ul_marker,
	detect_ol_marker = detect_ol_marker,
	detect_list_item = detect_list_item,
	detect_block = detect_block,
	can_interrupt_paragraph = can_interrupt_paragraph,
	parse_table_row = parse_table_row,
	detect_table_delimiter = detect_table_delimiter,
	detect_link_reference = detect_link_reference,
	detect_footnote_definition = detect_footnote_definition,
	detect_div_fence_open = detect_div_fence_open,
	is_div_fence_close = is_div_fence_close,
	detect_blockquote = detect_blockquote,
	is_blockquote_continuation = is_blockquote_continuation,
}
