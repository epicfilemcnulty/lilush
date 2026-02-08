-- SPDX-FileCopyrightText: © 2022—2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: LicenseRef-OWL-1.0-or-later OR GPL-3.0-or-later
-- Dual-licensed under OWL v1.0+ and GPLv3+. See LICENSE and LICENSE-GPL3.

--[[
Inline element parser for markdown.

Parses emphasis, strong, inline code, links, images, strikethrough, and autolinks
using an opener stack approach. Implements CommonMark flanking rules for emphasis
delimiters and GFM extensions for strikethrough (~~text~~) and autolinks.

The parser uses a two-phase approach:
1. First pass: identify all potential openers and closers, record positions
2. Second pass: match openers with closers and emit events

This approach ensures that unclosed openers are treated as literal text,
which is the correct CommonMark behavior.
]]

local byte = string.byte
local sub = string.sub
local find = string.find

-- Unicode whitespace check (simplified: space, tab, newline, CR)
local function is_whitespace(char)
	if not char or char == "" then
		return true -- Treat boundary as whitespace
	end
	local b = byte(char)
	return b == 32 or b == 9 or b == 10 or b == 13
end

-- ASCII punctuation per CommonMark spec
local function is_punctuation(char)
	if not char or char == "" then
		return false
	end
	local b = byte(char)
	return (b >= 33 and b <= 47) or (b >= 58 and b <= 64) or (b >= 91 and b <= 96) or (b >= 123 and b <= 126)
end

-- CommonMark flanking rules
local function is_left_flanking(before, after)
	if is_whitespace(after) then
		return false
	end
	if not is_punctuation(after) then
		return true
	end
	return is_whitespace(before) or is_punctuation(before)
end

local function is_right_flanking(before, after)
	if is_whitespace(before) then
		return false
	end
	if not is_punctuation(before) then
		return true
	end
	return is_whitespace(after) or is_punctuation(after)
end

local function can_open_emphasis(char, before, after)
	local left = is_left_flanking(before, after)
	if not left then
		return false
	end
	if char == "*" then
		return true
	end
	local right = is_right_flanking(before, after)
	if not right then
		return true
	end
	return is_punctuation(before)
end

local function can_close_emphasis(char, before, after)
	local right = is_right_flanking(before, after)
	if not right then
		return false
	end
	if char == "*" then
		return true
	end
	local left = is_left_flanking(before, after)
	if not left then
		return true
	end
	return is_punctuation(after)
end

-- Forward declaration
local new_inline_parser

-- Parse link destination and optional title
local function parse_link_destination(subject, start_pos)
	local pos = start_pos
	local len = #subject

	while pos <= len and (sub(subject, pos, pos) == " " or sub(subject, pos, pos) == "\t") do
		pos = pos + 1
	end

	if pos > len then
		return nil
	end

	local dest
	local dest_start = pos

	if sub(subject, pos, pos) == "<" then
		pos = pos + 1
		local dest_content_start = pos
		while pos <= len do
			local c = sub(subject, pos, pos)
			if c == ">" then
				dest = sub(subject, dest_content_start, pos - 1)
				pos = pos + 1
				break
			elseif c == "<" or c == "\n" then
				return nil
			elseif c == "\\" and pos + 1 <= len then
				pos = pos + 2
			else
				pos = pos + 1
			end
		end
		if not dest then
			return nil
		end
	else
		local paren_depth = 0
		while pos <= len do
			local c = sub(subject, pos, pos)
			if c == " " or c == "\t" or c == "\n" or c == "\r" then
				break
			elseif c == "(" then
				paren_depth = paren_depth + 1
				pos = pos + 1
			elseif c == ")" then
				if paren_depth == 0 then
					break
				end
				paren_depth = paren_depth - 1
				pos = pos + 1
			elseif c == "\\" and pos + 1 <= len then
				pos = pos + 2
			else
				pos = pos + 1
			end
		end
		dest = sub(subject, dest_start, pos - 1)
	end

	while
		pos <= len
		and (sub(subject, pos, pos) == " " or sub(subject, pos, pos) == "\t" or sub(subject, pos, pos) == "\n")
	do
		pos = pos + 1
	end

	local title = nil
	local title_char = sub(subject, pos, pos)
	if title_char == '"' or title_char == "'" or title_char == "(" then
		local close_char = title_char == "(" and ")" or title_char
		pos = pos + 1
		local title_start = pos
		while pos <= len do
			local c = sub(subject, pos, pos)
			if c == close_char then
				title = sub(subject, title_start, pos - 1)
				pos = pos + 1
				break
			elseif c == "\\" and pos + 1 <= len then
				pos = pos + 2
			else
				pos = pos + 1
			end
		end
		if not title then
			return nil
		end
	end

	while pos <= len and (sub(subject, pos, pos) == " " or sub(subject, pos, pos) == "\t") do
		pos = pos + 1
	end

	if sub(subject, pos, pos) ~= ")" then
		return nil
	end

	return dest, title, pos + 1
end

--[[
Two-phase parsing approach:

Phase 1: Scan the input and build a list of "tokens" - either text spans or
         potential delimiters (openers/closers).

Phase 2: Process the tokens, matching openers with closers for emphasis,
         and emit events.

This ensures unclosed delimiters become literal text.
]]

local TOKEN_TEXT = 1
local TOKEN_EMPH_DELIM = 2
local TOKEN_CODE = 3
local TOKEN_LINK_OPEN = 4
local TOKEN_LINK_CLOSE = 5
local TOKEN_ESCAPE = 6
local TOKEN_STRIKE_DELIM = 7
local TOKEN_AUTOLINK = 8
local TOKEN_FOOTNOTE_REF = 9
local TOKEN_ATTR_BLOCK = 10

-- Tokenize the input
local function tokenize(subject)
	local tokens = {}
	local len = #subject
	local pos = 1
	local text_start = 1

	local function add_text_token(end_pos)
		if end_pos >= text_start then
			tokens[#tokens + 1] = {
				type = TOKEN_TEXT,
				text = sub(subject, text_start, end_pos),
			}
		end
	end

	while pos <= len do
		local char = sub(subject, pos, pos)
		local b = byte(char)

		if b == 92 then -- backslash
			local next_char = sub(subject, pos + 1, pos + 1)
			if next_char ~= "" and is_punctuation(next_char) then
				add_text_token(pos - 1)
				tokens[#tokens + 1] = {
					type = TOKEN_ESCAPE,
					text = next_char,
				}
				pos = pos + 2
				text_start = pos
			else
				pos = pos + 1
			end
		elseif b == 96 then -- backtick
			local run_start = pos
			while pos <= len and sub(subject, pos, pos) == "`" do
				pos = pos + 1
			end
			local open_count = pos - run_start

			-- Search for matching close
			local search_pos = pos
			local found_close = false
			local close_end = nil
			local content_start = pos
			local content_end = nil

			while search_pos <= len do
				local close_start = find(subject, "`", search_pos, true)
				if not close_start then
					break
				end
				local close_count = 0
				local cp = close_start
				while cp <= len and sub(subject, cp, cp) == "`" do
					close_count = close_count + 1
					cp = cp + 1
				end
				if close_count == open_count then
					found_close = true
					content_end = close_start - 1
					close_end = cp
					break
				end
				search_pos = cp
			end

			if found_close then
				add_text_token(run_start - 1)
				local content = sub(subject, content_start, content_end)
				if
					#content >= 2
					and sub(content, 1, 1) == " "
					and sub(content, -1) == " "
					and find(content, "[^ ]")
				then
					content = sub(content, 2, -2)
				end
				content = content:gsub("\n", " ")
				tokens[#tokens + 1] = {
					type = TOKEN_CODE,
					text = content,
				}
				pos = close_end
				text_start = pos
			else
				-- No matching close, treat backticks as literal
				pos = run_start + open_count
			end
		elseif b == 42 or b == 95 then -- * or _
			local run_start = pos
			while pos <= len and sub(subject, pos, pos) == char do
				pos = pos + 1
			end
			local run_len = pos - run_start
			local before = run_start > 1 and sub(subject, run_start - 1, run_start - 1) or ""
			local after = pos <= len and sub(subject, pos, pos) or ""

			local can_open = can_open_emphasis(char, before, after)
			local can_close = can_close_emphasis(char, before, after)

			if can_open or can_close then
				add_text_token(run_start - 1)
				tokens[#tokens + 1] = {
					type = TOKEN_EMPH_DELIM,
					char = char,
					count = run_len,
					can_open = can_open,
					can_close = can_close,
				}
				text_start = pos
			end
			-- If neither, leave as text
		elseif b == 126 then -- ~ (tilde for strikethrough)
			local run_start = pos
			while pos <= len and sub(subject, pos, pos) == "~" do
				pos = pos + 1
			end
			local run_len = pos - run_start

			-- GFM strikethrough requires exactly 2 tildes
			if run_len >= 2 then
				local before = run_start > 1 and sub(subject, run_start - 1, run_start - 1) or ""
				local after = pos <= len and sub(subject, pos, pos) or ""

				-- Use similar flanking rules as emphasis
				local can_open = is_left_flanking(before, after)
				local can_close = is_right_flanking(before, after)

				if can_open or can_close then
					add_text_token(run_start - 1)
					-- Count how many pairs of 2 we have
					local pair_count = math.floor(run_len / 2)
					local remainder = run_len % 2
					tokens[#tokens + 1] = {
						type = TOKEN_STRIKE_DELIM,
						count = pair_count, -- Number of ~~ pairs
						can_open = can_open,
						can_close = can_close,
					}
					text_start = pos
					-- Handle odd tilde at end (will be emitted as text later if unused)
					if remainder > 0 then
						-- The single ~ at the end is kept as part of the delimiter token
						-- and will be output as literal if not matched
						tokens[#tokens].remainder = remainder
					end
				end
			end
			-- If only 1 tilde or no flanking, leave as text
		elseif b == 60 then -- < (potential autolink)
			-- Check for autolink: <URL> or <email>
			local close_pos = find(subject, ">", pos + 1, true)
			if close_pos then
				local content = sub(subject, pos + 1, close_pos - 1)
				-- Check for URL autolink (must have scheme)
				local url_match = content:match("^[a-zA-Z][a-zA-Z0-9+.-]*:[^%s<>]*$")
				-- Check for email autolink
				local email_match = content:match("^[a-zA-Z0-9.!#$%%&'*+/=?^_`{|}~-]+@[a-zA-Z0-9]")
					and content:match("@[a-zA-Z0-9][a-zA-Z0-9.-]*%.[a-zA-Z][a-zA-Z]*$")
					and not content:find("%s")

				if url_match then
					add_text_token(pos - 1)
					tokens[#tokens + 1] = {
						type = TOKEN_AUTOLINK,
						url = content,
						is_email = false,
					}
					pos = close_pos + 1
					text_start = pos
				elseif email_match then
					add_text_token(pos - 1)
					tokens[#tokens + 1] = {
						type = TOKEN_AUTOLINK,
						url = "mailto:" .. content,
						display = content,
						is_email = true,
					}
					pos = close_pos + 1
					text_start = pos
				else
					-- Not a valid autolink, treat < as literal
					pos = pos + 1
				end
			else
				pos = pos + 1
			end
		-- Note: We exclude ![^ from image detection to allow footnote references
		-- immediately after !. This means ![^alt](url) would NOT be parsed as an
		-- image, but this edge case is extremely rare in practice.
		elseif b == 33 and sub(subject, pos + 1, pos + 1) == "[" and sub(subject, pos + 2, pos + 2) ~= "^" then -- ![ but not ![^
			add_text_token(pos - 1)
			tokens[#tokens + 1] = {
				type = TOKEN_LINK_OPEN,
				is_image = true,
				pos = pos,
			}
			pos = pos + 2
			text_start = pos
		elseif b == 91 then -- [
			-- Check for footnote reference: [^id]
			if sub(subject, pos + 1, pos + 1) == "^" then
				-- Look for closing ]
				local close_pos = find(subject, "]", pos + 2, true)
				if close_pos then
					local label = sub(subject, pos + 2, close_pos - 1)
					-- Label must not be empty and must not contain spaces or ]
					if label ~= "" and not label:find("[%s%]]") then
						add_text_token(pos - 1)
						tokens[#tokens + 1] = {
							type = TOKEN_FOOTNOTE_REF,
							label = label:lower(), -- Normalize for case-insensitive matching
							pos = pos,
						}
						pos = close_pos + 1
						text_start = pos
					else
						-- Not a valid footnote, treat as regular link open
						add_text_token(pos - 1)
						tokens[#tokens + 1] = {
							type = TOKEN_LINK_OPEN,
							is_image = false,
							pos = pos,
						}
						pos = pos + 1
						text_start = pos
					end
				else
					-- No closing ], treat as regular link open
					add_text_token(pos - 1)
					tokens[#tokens + 1] = {
						type = TOKEN_LINK_OPEN,
						is_image = false,
						pos = pos,
					}
					pos = pos + 1
					text_start = pos
				end
			else
				add_text_token(pos - 1)
				tokens[#tokens + 1] = {
					type = TOKEN_LINK_OPEN,
					is_image = false,
					pos = pos,
				}
				pos = pos + 1
				text_start = pos
			end
		elseif b == 93 then -- ]
			add_text_token(pos - 1)
			-- Check if followed by ( for inline link
			local dest, title, end_pos = nil, nil, nil
			local ref_label = nil
			if sub(subject, pos + 1, pos + 1) == "(" then
				dest, title, end_pos = parse_link_destination(subject, pos + 2)
			elseif sub(subject, pos + 1, pos + 1) == "[" then
				-- Reference link: [text][ref] or [text][]
				local ref_close = find(subject, "]", pos + 2, true)
				if ref_close then
					ref_label = sub(subject, pos + 2, ref_close - 1)
					end_pos = ref_close + 1
				end
			end
			tokens[#tokens + 1] = {
				type = TOKEN_LINK_CLOSE,
				pos = pos,
				dest = dest,
				title = title,
				ref_label = ref_label,
				end_pos = end_pos,
			}
			if end_pos then
				pos = end_pos
			else
				pos = pos + 1
			end
			text_start = pos
		elseif b == 123 then -- { (potential attribute block)
			-- Look for closing } - parse attribute block
			local close_pos = find(subject, "}", pos + 1, true)
			if close_pos then
				local attr_content = sub(subject, pos + 1, close_pos - 1)
				-- Parse attributes: .class, #id, key=value, key="value"
				local attrs = {}
				local valid = true
				local attr_pos = 1
				local attr_len = #attr_content

				while attr_pos <= attr_len and valid do
					-- Skip whitespace
					while
						attr_pos <= attr_len
						and (
							sub(attr_content, attr_pos, attr_pos) == " "
							or sub(attr_content, attr_pos, attr_pos) == "\t"
						)
					do
						attr_pos = attr_pos + 1
					end
					if attr_pos > attr_len then
						break
					end

					local c = sub(attr_content, attr_pos, attr_pos)
					if c == "." then
						-- Class: .classname
						local class_match = attr_content:match("^%.([%w_%-]+)", attr_pos)
						if class_match then
							attrs.class = attrs.class and (attrs.class .. " " .. class_match) or class_match
							attr_pos = attr_pos + 1 + #class_match
						else
							valid = false
						end
					elseif c == "#" then
						-- ID: #idname
						local id_match = attr_content:match("^#([%w_%-]+)", attr_pos)
						if id_match then
							attrs.id = id_match
							attr_pos = attr_pos + 1 + #id_match
						else
							valid = false
						end
					else
						-- Key=value or key="value"
						local key, value_part = attr_content:match("^([%w_%-]+)=(.)", attr_pos)
						if key then
							local value
							local value_start = attr_pos + #key + 1
							if value_part == '"' or value_part == "'" then
								-- Quoted value
								local quote = value_part
								local quote_end = find(attr_content, quote, value_start + 1, true)
								if quote_end then
									value = sub(attr_content, value_start + 1, quote_end - 1)
									attr_pos = quote_end + 1
								else
									valid = false
								end
							else
								-- Unquoted value (ends at whitespace or end)
								value = attr_content:match("^([^%s]+)", value_start)
								if value then
									attr_pos = value_start + #value
								else
									valid = false
								end
							end
							if value then
								attrs[key] = value
							end
						else
							-- Unknown format
							valid = false
						end
					end
				end

				if valid and (attrs.class or attrs.id or next(attrs)) then
					add_text_token(pos - 1)
					tokens[#tokens + 1] = {
						type = TOKEN_ATTR_BLOCK,
						attrs = attrs,
						pos = pos,
					}
					pos = close_pos + 1
					text_start = pos
				else
					-- Not a valid attribute block, treat { as literal
					pos = pos + 1
				end
			else
				pos = pos + 1
			end
		else
			pos = pos + 1
		end
	end

	add_text_token(len)
	return tokens
end

-- Process tokens and emit events
-- link_refs: optional table of link reference definitions {label -> {url, title}}
-- footnote_tracker: optional table to track footnote usage {used = {label -> true}}
local function process_tokens(tokens, emit, link_refs, footnote_tracker)
	link_refs = link_refs or {}
	footnote_tracker = footnote_tracker or {}

	-- First, resolve links (they have higher precedence)
	-- Mark which tokens are part of valid links

	local link_openers = {} -- stack of {index, is_image}
	local link_ranges = {} -- list of {open_idx, close_idx, is_image, dest, title}

	for i, tok in ipairs(tokens) do
		if tok.type == TOKEN_LINK_OPEN then
			link_openers[#link_openers + 1] = { index = i, is_image = tok.is_image }
		elseif tok.type == TOKEN_LINK_CLOSE then
			local dest = tok.dest
			local title = tok.title

			-- Check for reference link if no inline destination
			if not dest and tok.ref_label ~= nil and #link_openers > 0 then
				local ref_key = tok.ref_label
				-- If empty ref_label, use link text as reference
				if ref_key == "" then
					-- Extract link text from tokens between opener and closer
					local opener = link_openers[#link_openers]
					local text_parts = {}
					for j = opener.index + 1, i - 1 do
						local inner_tok = tokens[j]
						if inner_tok.type == TOKEN_TEXT then
							text_parts[#text_parts + 1] = inner_tok.text
						elseif inner_tok.type == TOKEN_ESCAPE then
							text_parts[#text_parts + 1] = inner_tok.text
						end
					end
					ref_key = table.concat(text_parts):gsub("%s+", " "):lower()
				else
					ref_key = ref_key:gsub("%s+", " "):lower()
				end

				-- Look up reference
				local ref = link_refs[ref_key]
				if ref then
					dest = ref.url
					title = ref.title
				end
			end

			if dest and #link_openers > 0 then
				-- Valid link - match with most recent opener
				local opener = link_openers[#link_openers]
				link_openers[#link_openers] = nil
				link_ranges[#link_ranges + 1] = {
					open_idx = opener.index,
					close_idx = i,
					is_image = opener.is_image,
					dest = dest,
					title = title,
				}
				-- Remove any openers between this opener and closer (links can't nest)
				local new_openers = {}
				for _, op in ipairs(link_openers) do
					if op.index < opener.index then
						new_openers[#new_openers + 1] = op
					end
				end
				link_openers = new_openers
			end
		end
	end

	-- Mark tokens that are part of links
	local in_link = {} -- token index -> link range
	for _, range in ipairs(link_ranges) do
		for i = range.open_idx, range.close_idx do
			in_link[i] = range
		end
	end

	-- Now process emphasis and strikethrough, skipping tokens inside links
	-- (they'll be handled when we emit link content)
	-- Build opener stacks for tokens not in links

	local emph_openers = {} -- char -> stack of {index, count}
	local strike_openers = {} -- stack of {index, count}

	-- Mark which delimiter tokens close which openers
	local emph_matches = {} -- closer_idx -> {opener_idx, count, tag}
	local strike_matches = {} -- closer_idx -> {opener_idx, count}

	for i, tok in ipairs(tokens) do
		if tok.type == TOKEN_EMPH_DELIM and not in_link[i] then
			local char = tok.char
			local remaining = tok.count

			-- Try to close
			if tok.can_close then
				local stack = emph_openers[char] or {}
				while remaining > 0 and #stack > 0 do
					local opener = stack[#stack]
					local use_count = (remaining >= 2 and opener.remaining >= 2) and 2 or 1
					local tag = use_count == 2 and "strong" or "emph"

					emph_matches[i] = emph_matches[i] or {}
					emph_matches[i][#emph_matches[i] + 1] = {
						opener_idx = opener.index,
						count = use_count,
						tag = tag,
					}

					opener.remaining = opener.remaining - use_count
					if opener.remaining == 0 then
						stack[#stack] = nil
					end
					remaining = remaining - use_count
				end
				emph_openers[char] = stack
			end

			-- Try to open with remaining
			if tok.can_open and remaining > 0 then
				local stack = emph_openers[char]
				if not stack then
					stack = {}
					emph_openers[char] = stack
				end
				stack[#stack + 1] = { index = i, remaining = remaining }
			end

			-- Store how many were used
			tok.used = tok.count - remaining
		elseif tok.type == TOKEN_STRIKE_DELIM and not in_link[i] then
			local remaining = tok.count -- Number of ~~ pairs

			-- Try to close
			if tok.can_close then
				while remaining > 0 and #strike_openers > 0 do
					local opener = strike_openers[#strike_openers]
					-- Each match uses one ~~ pair from opener and closer
					strike_matches[i] = strike_matches[i] or {}
					strike_matches[i][#strike_matches[i] + 1] = {
						opener_idx = opener.index,
					}

					opener.remaining = opener.remaining - 1
					if opener.remaining == 0 then
						strike_openers[#strike_openers] = nil
					end
					remaining = remaining - 1
				end
			end

			-- Try to open with remaining
			if tok.can_open and remaining > 0 then
				strike_openers[#strike_openers + 1] = { index = i, remaining = remaining }
			end

			-- Store how many pairs were used
			tok.used = tok.count - remaining
		end
	end

	-- Now emit events
	-- We need to track which openers have been "started" so we can emit ends in the right order

	local active_emph = {} -- stack of {tag, opener_idx}
	local active_strike = {} -- stack of {opener_idx}

	local function emit_text(text)
		if text and text ~= "" then
			emit({ type = "text", text = text })
		end
	end

	local function emit_link_content(start_idx, end_idx)
		-- Collect tokens between start and end, recursively process for emphasis
		local inner_tokens = {}
		for i = start_idx, end_idx do
			inner_tokens[#inner_tokens + 1] = tokens[i]
		end
		-- For simplicity, extract text and re-parse
		local text_parts = {}
		for _, tok in ipairs(inner_tokens) do
			if tok.type == TOKEN_TEXT then
				text_parts[#text_parts + 1] = tok.text
			elseif tok.type == TOKEN_ESCAPE then
				text_parts[#text_parts + 1] = tok.text
			elseif tok.type == TOKEN_EMPH_DELIM then
				text_parts[#text_parts + 1] = string.rep(tok.char, tok.count)
			elseif tok.type == TOKEN_STRIKE_DELIM then
				-- Re-encode tildes for nested parse
				local total = tok.count * 2 + (tok.remainder or 0)
				text_parts[#text_parts + 1] = string.rep("~", total)
			elseif tok.type == TOKEN_CODE then
				-- Emit code directly
				text_parts[#text_parts + 1] = "`" .. tok.text .. "`" -- Re-encode for nested parse
			elseif tok.type == TOKEN_AUTOLINK then
				-- Re-encode autolink for nested parse
				if tok.is_email then
					text_parts[#text_parts + 1] = "<" .. tok.display .. ">"
				else
					text_parts[#text_parts + 1] = "<" .. tok.url .. ">"
				end
			elseif tok.type == TOKEN_LINK_OPEN then
				text_parts[#text_parts + 1] = tok.is_image and "![" or "["
			elseif tok.type == TOKEN_LINK_CLOSE then
				text_parts[#text_parts + 1] = "]"
			end
		end
		local nested_text = table.concat(text_parts)
		if nested_text ~= "" then
			local nested_parser = new_inline_parser(emit)
			nested_parser:parse(nested_text)
		end
	end

	local i = 1
	while i <= #tokens do
		local tok = tokens[i]

		-- Check if this starts a link
		local link_range = nil
		for _, range in ipairs(link_ranges) do
			if range.open_idx == i then
				link_range = range
				break
			end
		end

		if link_range then
			-- Emit link
			local tag = link_range.is_image and "image" or "link"
			local attrs = { href = link_range.dest }
			if link_range.title then
				attrs.title = link_range.title
			end

			-- Check for following attribute block
			local next_idx = link_range.close_idx + 1
			if next_idx <= #tokens and tokens[next_idx].type == TOKEN_ATTR_BLOCK then
				local attr_tok = tokens[next_idx]
				for k, v in pairs(attr_tok.attrs) do
					attrs[k] = v
				end
				link_range.close_idx = next_idx -- Include attribute block in skip
			end

			emit({ type = "inline_start", tag = tag, attrs = attrs })

			-- Emit content between open and close (excluding attribute block)
			emit_link_content(link_range.open_idx + 1, link_range.close_idx - 1)

			emit({ type = "inline_end", tag = tag })

			-- Skip to after link (and attribute block if present)
			i = link_range.close_idx + 1
		elseif in_link[i] then
			-- Skip tokens inside links (handled above)
			i = i + 1
		elseif tok.type == TOKEN_TEXT then
			emit_text(tok.text)
			i = i + 1
		elseif tok.type == TOKEN_ESCAPE then
			emit_text(tok.text)
			i = i + 1
		elseif tok.type == TOKEN_CODE then
			-- Check for following attribute block
			local attrs = nil
			if i + 1 <= #tokens and tokens[i + 1].type == TOKEN_ATTR_BLOCK then
				attrs = tokens[i + 1].attrs
				i = i + 1 -- Skip attribute block
			end
			emit({ type = "inline_start", tag = "code", attrs = attrs })
			emit_text(tok.text)
			emit({ type = "inline_end", tag = "code" })
			i = i + 1
		elseif tok.type == TOKEN_EMPH_DELIM then
			-- Check if this closes any openers
			local matches = emph_matches[i]
			if matches then
				-- Emit closes in reverse order (LIFO)
				for j = #matches, 1, -1 do
					local m = matches[j]
					emit({ type = "inline_end", tag = m.tag })
					-- Find and remove from active_emph
					for k = #active_emph, 1, -1 do
						if active_emph[k].opener_idx == m.opener_idx and active_emph[k].tag == m.tag then
							table.remove(active_emph, k)
							break
						end
					end
				end
			end

			-- Check if this token is an opener for any matches
			local opens_for = {}
			for closer_idx, closer_matches in pairs(emph_matches) do
				for _, m in ipairs(closer_matches) do
					if m.opener_idx == i then
						opens_for[#opens_for + 1] = { closer_idx = closer_idx, tag = m.tag, count = m.count }
					end
				end
			end

			-- Emit opens
			for _, o in ipairs(opens_for) do
				emit({ type = "inline_start", tag = o.tag })
				active_emph[#active_emph + 1] = { opener_idx = i, tag = o.tag }
			end

			-- Emit any unused delimiters as text
			local used = 0
			for _, o in ipairs(opens_for) do
				used = used + o.count
			end
			if matches then
				for _, m in ipairs(matches) do
					used = used + m.count
				end
			end
			local unused = tok.count - used
			if unused > 0 then
				emit_text(string.rep(tok.char, unused))
			end

			i = i + 1
		elseif tok.type == TOKEN_STRIKE_DELIM then
			-- Check if this closes any strikethrough openers
			local matches = strike_matches[i]
			if matches then
				-- Emit closes in reverse order (LIFO)
				for j = #matches, 1, -1 do
					local m = matches[j]
					emit({ type = "inline_end", tag = "strikethrough" })
					-- Find and remove from active_strike
					for k = #active_strike, 1, -1 do
						if active_strike[k].opener_idx == m.opener_idx then
							table.remove(active_strike, k)
							break
						end
					end
				end
			end

			-- Check if this token is an opener for any matches
			local opens_for = {}
			for closer_idx, closer_matches in pairs(strike_matches) do
				for _, m in ipairs(closer_matches) do
					if m.opener_idx == i then
						opens_for[#opens_for + 1] = { closer_idx = closer_idx }
					end
				end
			end

			-- Emit opens
			for _, o in ipairs(opens_for) do
				emit({ type = "inline_start", tag = "strikethrough" })
				active_strike[#active_strike + 1] = { opener_idx = i }
			end

			-- Emit any unused delimiter pairs as text
			local used = #opens_for
			if matches then
				used = used + #matches
			end
			local unused_pairs = tok.count - used
			if unused_pairs > 0 then
				emit_text(string.rep("~~", unused_pairs))
			end
			-- Emit remainder single tilde if present
			if tok.remainder and tok.remainder > 0 then
				emit_text("~")
			end

			i = i + 1
		elseif tok.type == TOKEN_AUTOLINK then
			-- Emit autolink as a link
			local attrs = { href = tok.url, autolink = true }
			-- Check for following attribute block
			if i + 1 <= #tokens and tokens[i + 1].type == TOKEN_ATTR_BLOCK then
				local attr_tok = tokens[i + 1]
				for k, v in pairs(attr_tok.attrs) do
					attrs[k] = v
				end
				i = i + 1 -- Skip attribute block
			end
			emit({ type = "inline_start", tag = "link", attrs = attrs })
			emit_text(tok.display or tok.url)
			emit({ type = "inline_end", tag = "link" })
			i = i + 1
		elseif tok.type == TOKEN_FOOTNOTE_REF then
			-- Emit footnote reference
			-- Track usage for batch emission at document end
			if footnote_tracker.used then
				footnote_tracker.used[tok.label] = true
			end
			emit({ type = "inline_start", tag = "footnote_ref", attrs = { label = tok.label } })
			emit({ type = "inline_end", tag = "footnote_ref" })
			i = i + 1
		elseif tok.type == TOKEN_ATTR_BLOCK then
			-- Standalone attribute block (not attached to anything) - emit as literal
			-- This shouldn't normally happen as they should be consumed by preceding elements
			local parts = {}
			if tok.attrs.class then
				parts[#parts + 1] = "." .. tok.attrs.class:gsub(" ", " .")
			end
			if tok.attrs.id then
				parts[#parts + 1] = "#" .. tok.attrs.id
			end
			emit_text("{" .. table.concat(parts, " ") .. "}")
			i = i + 1
		elseif tok.type == TOKEN_LINK_OPEN then
			-- Unclosed link opener - emit as literal
			emit_text(tok.is_image and "![" or "[")
			i = i + 1
		elseif tok.type == TOKEN_LINK_CLOSE then
			-- Unmatched link closer - emit as literal
			emit_text("]")
			-- If there was a ref_label, emit it too
			if tok.ref_label then
				emit_text("[" .. tok.ref_label .. "]")
			end
			i = i + 1
		else
			i = i + 1
		end
	end
end

-- Main parse function
local function parse(self, subject)
	local tokens = tokenize(subject)
	process_tokens(tokens, self.cfg.emit, self.cfg.link_refs, self.cfg.footnote_tracker)
end

-- Create a new inline parser
-- Options:
--   emit: callback function for events (or first arg if not a table)
--   link_refs: table of link reference definitions {label -> {url, title}}
--   footnote_tracker: table to track footnote usage {used = {label -> true}}
local function new(emit_or_options, link_refs, footnote_tracker)
	local emit, opts
	if type(emit_or_options) == "table" then
		opts = emit_or_options
		emit = opts.emit
		link_refs = opts.link_refs
		footnote_tracker = opts.footnote_tracker
	else
		emit = emit_or_options
	end

	return {
		cfg = {
			emit = emit or function() end,
			link_refs = link_refs or {},
			footnote_tracker = footnote_tracker or {},
		},
		__state = {},
		parse = parse,
	}
end

new_inline_parser = new

return { new = new }
