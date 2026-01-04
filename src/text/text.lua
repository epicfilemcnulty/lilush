-- SPDX-FileCopyrightText: © 2023 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: GPL-3.0-or-later
local std = require("std")
local buffer = require("string.buffer")
local term = require("term")
local djot = require("djot")
local style = require("term.tss")

local default_plain_rss = {
	clip = -1,
	fg = 253,
	global_indent = -1,
	wrap = -1,
}

local default_borders = {
	align = "none",
	indent = 0,
	top_line = { before = "╭", content = "─", after = "╮", fill = true },
	bottom_line = { before = "╰", content = "─", after = "╯", fill = true },
	subtitle_line = { before = "⎜", content = "┈", after = "⎜", fill = true },
	v = { content = "⎜", w = 1 },
}

local default_djot_rss = {
	wrap = 80,
	table_wrap = false,
	codeblock_wrap = true,
	global_indent = 2,
	hide_links = false,
	clip = -1,
	fg = 253,
	verbatim = { fg = 249 },
	header = { s = "bold", level = { content = "⁜", fill = true } },
	emph = { s = "italic" },
	strong = { s = "bold" },
	codeblock = {
		border = default_borders,
		clip = 0,
		align = "left",
		lang = { indent = 0, s = "italic,bold", before = "⧼ ", after = " ⧽", w = -1 },
	},
	link = {
		title = { s = "underlined" },
		url = { s = "dim", before = "(", after = ")", clip = 0 },
	},
	list = {
		definition = {
			suffix = { s = "dim", content = "─", fill = true },
		},
		ul = {
			plus = { content = "✚", nested = { content = "✛" } },
			minus = { content = "▧", nested = { content = "▪" } },
			star = { content = "⚆", nested = { content = "⦁" } },
			task = {
				content = "[]",
				nested = { content = "[]" },
				checked = { content = "[X]", nested = { content = "[X]" } },
				unchecked = { content = "[ ]", nested = { content = "[ ]" } },
			},
		},
		ol = { s = "bold" },
	},
	tbl = {
		header = { s = "italic,bold" },
		border = default_borders,
	},
	thematic_break = { w = 0.9, align = "center" },
	blockquote = {
		marker = { content = "│ ", fg = 245 },
		fg = 250,
	},
	class = {
		tbl = { s = "italic" },
		bool = { fg = 250 },
		num = { fg = 252 },
		str = { fg = 251 },
		fn = { before = "ʄ(", after = ")" },
		file = { before = "Ⓕ " },
		dir = { before = "Ⓓ " },
		def = { s = "dim" },
		req = { s = "bold" },
	},
	div = {
		border = default_borders,
		label = { s = "italic,bold", before = " ", after = " " },
		note = { label = { before = "📝 " }, fg = 75, border = { fg = 75 } },
		warning = { label = { before = "⚠ " }, fg = 214, border = { fg = 214 } },
		tip = { label = { before = "💡 " }, fg = 82, border = { fg = 82 } },
		important = { label = { before = "❗ " }, fg = 196, s = "bold", border = { fg = 196 } },
		caution = { label = { before = "🔥 " }, fg = 208, border = { fg = 208 } },
	},
}

local render_text = function(raw, rss, conf)
	raw = raw or ""
	local tss = style.merge(default_plain_rss, rss)
	local conf = conf or {}
	local wrap = tss.__style.wrap or 0
	if conf.wrap then
		wrap = conf.wrap
	end
	local g_indent = tss.__style.global_indent or 0
	if conf.global_indent ~= nil then
		g_indent = conf.global_indent
	end
	local out = tss:apply("raw", raw)
	if wrap > 0 then
		out = std.txt.lines_of(out, wrap)
	end
	return std.txt.indent(out, g_indent)
end

-- All things djot are below =)

-- Helper to get list info from parent string
local function get_list_info(parent, list_item_idx)
	if not parent:match("list") then
		return nil
	end
	local list_style = parent:match("([^/]+)$") or "star"
	local level = 0
	for _ in parent:gmatch("|") do
		level = level + 1
	end
	local indent
	if list_style:match("%d") then
		indent = #tostring(list_item_idx) + 2 + level * 2
	elseif list_style == ":" then
		indent = 2 + level * 2
	else
		indent = 2 + level * 2
	end
	return level, indent, list_style
end

-- Helper to get CSS-like classes from element attributes
local function get_classes(el, tag, tss)
	local classes = {}
	if el.attr and el.attr.class then
		for class in el.attr.class:gmatch("(%S+)%s?") do
			if tss.__style[tag] and tss.__style[tag][class] then
				table.insert(classes, tag .. "." .. class)
			elseif tss.__style.class[tag] and tss.__style.class[tag][class] then
				table.insert(classes, "class." .. tag .. "." .. class)
			elseif tss.__style.class[class] then
				table.insert(classes, "class." .. class)
			end
		end
	end
	return classes
end

--- Render a bordered block (used for code blocks, divs, etc.)
--- @param tss TSS instance
--- @param style_base string Base style path (e.g., "codeblock", "div")
--- @param lines table Array of content lines
--- @param width number Width of the block
--- @param label string|nil Optional label for the top border
--- @param indent number Left indentation
--- @param opts table|nil Optional render settings (content_style, label_style)
--- @return string Rendered block with borders
local function render_bordered_block(tss, style_base, lines, width, label, indent, opts)
	opts = opts or {}
	local content_style = opts.content_style or style_base
	local label_style = opts.label_style or (style_base .. ".label")
	indent = indent or 0
	local out = ""
	local indent_str = string.rep(" ", indent)

	-- Set the border width; content width is applied after the top line is built.
	local orig_w = tss.__style[style_base].w
	local orig_align = tss.__style[style_base].align
	local orig_border_w = tss.__style[style_base].border.w
	tss.__style[style_base].border.w = width

	-- Build top line - use exact same approach as code_block
	local border_def = tss.__style[style_base].border
	local top_line = tss:apply(style_base .. ".border.top_line")
	if label and label ~= "" then
		-- Avoid padding the label to the block width
		tss.__style[style_base].w = 0
		tss.__style[style_base].align = "none"
		local styled_label = tss:apply(label_style, label)
		local label_len = std.utf.display_len(styled_label)
		tss.__style[style_base].w = orig_w
		tss.__style[style_base].align = orig_align
		local st = tss:apply(style_base .. ".border", border_def.top_line.before .. border_def.top_line.content)
		st = st
			.. styled_label
			.. tss:apply(
				style_base .. ".border",
				string.rep(border_def.top_line.content, math.max(width - label_len - 1, 0)) .. border_def.top_line.after
			)
		top_line = st
	end

	-- Set content width so lines pad to align with borders.
	tss.__style[style_base].w = width
	if not orig_align or orig_align == "none" then
		tss.__style[style_base].align = "left"
	end

	-- Build content lines with vertical borders
	out = out .. indent_str .. top_line .. "\n"
	for i, l in ipairs(lines) do
		-- Skip empty trailing lines
		local is_last = (i == #lines)
		local is_empty = (l == "" or l:match("^%s*$"))
		if not (is_last and is_empty) then
			out = out
				.. indent_str
				.. tss:apply(style_base .. ".border.v")
				.. tss:apply(content_style, l)
				.. tss:apply(style_base .. ".border.v")
				.. "\n"
		end
	end
	out = out .. indent_str .. tss:apply(style_base .. ".border.bottom_line") .. "\n"

	-- Restore original width/alignment
	tss.__style[style_base].w = orig_w
	tss.__style[style_base].align = orig_align
	tss.__style[style_base].border.w = orig_border_w

	return out
end

local typographics = {
	["en_dash"] = "–",
	["em_dash"] = "—",
	["ellipses"] = "…",
	["right_single_quote"] = "'",
	["left_single_quote"] = "'",
	["right_double_quote"] = '"',
	["left_double_quote"] = '"',
}

local render_djot_element
render_djot_element = function(el, tss, wrap, parent, list_item_idx)
	wrap = wrap or 0
	local codeblock_wrap = tss.__style.codeblock_wrap
	parent = parent or "str"
	list_item_idx = list_item_idx or 1

	-- Local helper to render children recursively
	local function render_children(children, p)
		local out = ""
		for i, child in ipairs(children) do
			out = out .. render_djot_element(child, tss, wrap, p, i)
		end
		return out
	end

	-- Check typographics first
	if typographics[el.tag] then
		return typographics[el.tag]
	end
	if el.tag == "softbreak" then
		return " "
	end
	if el.tag == "hardbreak" then
		return "\n"
	end
	if el.tag == "str" then
		if parent == "str" then
			return el.text
		end
		return tss:apply(parent, el.text)
	end
	if el.tag == "single_quoted" then
		return tss:apply(parent, "‘") .. render_children(el.children, parent) .. tss:apply(parent, "’")
	end
	if el.tag == "double_quoted" then
		return tss:apply(parent, "“") .. render_children(el.children, parent) .. tss:apply(parent, "”")
	end
	if el.tag == "emph" or el.tag == "strong" then
		return tss:apply({ parent, el.tag }, render_children(el.children))
	end
	if el.tag == "verbatim" then
		local elements = get_classes(el, el.tag, tss)
		return tss:apply({ el.tag, unpack(elements) }, el.text)
	end
	if el.tag == "link" then
		if tss.__style.hide_links then
			tss.__style.link.url.content = ""
			tss.__style.link.url.after = ""
			tss.__style.link.url.before = ""
		end
		local elements = get_classes(el, el.tag, tss)
		local target = el.destination or el.reference
		local title = render_children(el.children)
		return tss:apply({ "link.title", unpack(elements) }, title) .. tss:apply("link.url", target)
	end
	if el.tag == "thematic_break" then
		tss.__style.w = wrap
		return tss:apply(el.tag, el.text) .. "\n"
	end
	if el.tag == "heading" then
		tss.__style.header.level.w = el.level
		return tss:apply("header.level") .. " " .. render_children(el.children, "header") .. "\n\n"
	end
	if el.tag == "code_block" then
		local out = ""
		local indent = 0
		local padding = tss.__style.codeblock.padding or 0
		local level, list_indent, list_style = get_list_info(parent, list_item_idx)
		if level then
			indent = list_indent
			out = "\n"
		end
		local elements = get_classes(el, "codeblock", tss)
		local content = std.txt.lines(el.text)
		if wrap > 0 and codeblock_wrap then
			content = std.txt.lines_of(table.concat(content, "\n"), wrap, true)
		end
		local block_width = 0
		if wrap > 0 then
			block_width = wrap + indent + padding * 2
		end
		out = out
			.. render_bordered_block(tss, "codeblock", content, block_width, el.lang, indent, {
				content_style = { "codeblock", unpack(elements) },
				label_style = "codeblock.lang",
			})
		return out .. "\n"
	end
	if el.tag == "div" then
		local out = ""
		local indent = 0
		local level, list_indent, list_style = get_list_info(parent, list_item_idx)
		if level then
			indent = list_indent
			out = "\n"
		end

		-- Get class name for label and styling
		local class_name = ""
		local class_style = tss.__style.div
		if el.attr and el.attr.class then
			class_name = el.attr.class:match("(%S+)") or ""
			if class_style[class_name] then
				class_style = class_style[class_name]
			end
		end

		-- Build label with optional emoji prefix
		local label = nil
		if class_name ~= "" then
			local label_prefix = (class_style.label and class_style.label.before) or ""
			label = label_prefix .. class_name
		end

		-- Apply class-specific fg color to div style temporarily
		local orig_fg = tss.__style.div.fg
		local orig_border_fg = tss.__style.div.border.fg
		if class_style.fg then
			tss.__style.div.fg = class_style.fg
		end
		if class_style.border and class_style.border.fg then
			tss.__style.div.border.fg = class_style.border.fg
		end

		-- Render content and get lines
		local content = render_children(el.children, "div")
		local lines = std.txt.lines(content)

		-- Calculate width
		local div_width = wrap > 0 and wrap + indent or 60

		-- Render the bordered block
		out = out .. render_bordered_block(tss, "div", lines, div_width, label, indent)

		-- Restore original colors
		tss.__style.div.fg = orig_fg
		tss.__style.div.border.fg = orig_border_fg

		return out .. "\n"
	end
	if el.tag == "blockquote" then
		local content = render_children(el.children, "blockquote")
		local marker = tss:apply("blockquote.marker")
		local lines = std.txt.lines(content)
		local out = ""
		for i, line in ipairs(lines) do
			out = out .. marker .. tss:apply("blockquote", line)
			if i < #lines then
				out = out .. "\n"
			end
		end
		return out .. "\n"
	end
	if el.tag == "para" then
		local elements = get_classes(el, parent, tss)
		local content = tss:apply({ el.tag, unpack(elements) }, render_children(el.children, "para"))
		local trailing_newline = "\n\n"
		local indent = 0
		local list_level, list_indent, list_style = get_list_info(parent, list_item_idx)
		if list_level then
			trailing_newline = "\n"
			indent = list_indent
		end
		if wrap > 0 then
			if list_item_idx == 1 then
				return table.concat(
					std.txt.indent_all_lines_but_first(std.txt.lines_of(content, wrap, false, true), indent),
					"\n"
				) .. trailing_newline
			end
			return table.concat(std.txt.indent_lines(std.txt.lines_of(content, wrap, false, true), indent), "\n")
				.. trailing_newline
		end
		return content .. trailing_newline
	end
	if el.tag == "definition_list_item" then
		local level, list_indent, list_style = get_list_info(parent, list_item_idx)
		local out = ""
		local def = ""
		local def_term = render_children(el.children[1].children, "list.definition.term")
		if el.children[2] then
			def = render_children(el.children[2].children, parent)
		end
		out = out .. string.rep(" ", list_indent) .. tss:apply("list.definition.term", def_term) .. "\n"
		tss.__style.list.definition.suffix.w = std.utf.len(def_term)
		out = out .. string.rep(" ", list_indent) .. tss:apply("list.definition.suffix") .. "\n\n"
		out = out .. string.rep(" ", list_indent) .. tss:apply("list.definition.def", def) .. "\n"
		return out
	end
	if el.tag == "list_item" then
		local level, list_indent, list_style = get_list_info(parent, list_item_idx)
		local marker
		if not list_style:match("%d") then
			local styles = { ["X"] = "task", ["*"] = "star", ["-"] = "minus", ["+"] = "plus" }
			local marker_style = "list.ul." .. styles[list_style]
			if list_style == "X" and el.checkbox then
				local state = el.checkbox == "checked" and "checked" or "unchecked"
				if tss.__style.list.ul.task and tss.__style.list.ul.task[state] then
					marker_style = marker_style .. "." .. state
				end
			end
			if level == 1 then
				marker = tss:apply(marker_style)
			else
				marker = tss:apply(marker_style .. ".nested")
			end
		else
			marker = tss:apply("list.ol", tostring(list_item_idx) .. ".")
		end
		return string.rep(" ", level * 2) .. marker .. " " .. render_children(el.children, parent)
	end
	if el.tag == "list" then
		if parent:match("list") then
			return render_children(el.children, parent .. "|list/" .. el.style) .. "\n"
		else
			return render_children(el.children, "list/" .. el.style) .. "\n" -- used to be two newlines
		end
	end
	if el.tag == "table" then
		local tbl_headers = {}
		local tbl_data = {}
		local indent = 0
		local level, list_indent, list_style = get_list_info(parent, list_item_idx)
		if level then
			indent = list_indent
		end
		local max_table_width = tss.__window.w - indent * 2 - 4
		if wrap > 0 and tss.__style.table_wrap then
			max_table_width = wrap - indent - 1
		end
		for i, row in ipairs(el.children) do
			tbl_data[i] = {}
			for j, cell in ipairs(row.children) do
				local cell_content = cell.text or ""
				if cell.children then
					cell_content = render_children(cell.children)
				end
				if cell.head then
					tbl_headers[j] = { cell_content, cell.align or "left" }
				else
					tbl_data[i][j] = cell_content
				end
			end
		end
		local maxes = std.tbl.calc_table_maxes(tbl_headers, tbl_data)
		if max_table_width > 0 then
			local cols = {}
			local min_width = 0
			local tbl_width = 0
			for i, header in ipairs(tbl_headers) do
				local h_name = std.tbl.parse_pipe_table_header(header)
				local min = math.max(1, std.utf.len(h_name))
				min_width = min_width + min + 3
				tbl_width = tbl_width + maxes[h_name] + 3
				cols[i] = { name = h_name, min = min, max = maxes[h_name] }
			end
			local target_width = max_table_width
			if target_width < min_width then
				target_width = min_width
			end
			while tbl_width > target_width do
				local idx = nil
				local room = 0
				for i, col in ipairs(cols) do
					local avail = col.max - col.min
					if avail > room then
						room = avail
						idx = i
					end
				end
				if not idx or room == 0 then
					break
				end
				local dec = math.min(room, tbl_width - target_width)
				cols[idx].max = cols[idx].max - dec
				tbl_width = tbl_width - dec
			end
			for _, col in ipairs(cols) do
				maxes[col.name] = col.max
			end
		end
		local tbl_width = 0
		local out = ""
		for col_name, max in pairs(maxes) do
			tbl_width = tbl_width + max + 2 + 1
		end
		tss.__style.tbl.border.w = tbl_width - 1
		out = out
			.. string.rep(" ", indent)
			.. tss:apply("tbl.border.top_line")
			.. "\n"
			.. string.rep(" ", indent)
			.. tss:apply("tbl.border.v")
		for i, header in ipairs(tbl_headers) do
			local h_name = std.tbl.parse_pipe_table_header(header)
			local header_text = std.txt.limit(h_name, maxes[h_name])
			out = out
				.. " "
				.. tss:apply("tbl.header", std.txt.align(header_text, maxes[h_name], "center"))
				.. " "
				.. tss:apply("tbl.border.v")
		end
		out = out .. "\n" .. string.rep(" ", indent) .. tss:apply("tbl.border.subtitle_line") .. "\n"
		for i, row in ipairs(tbl_data) do
			if #row > 0 then
				out = out .. string.rep(" ", indent) .. tss:apply("tbl.border.v")
				for j, cell in ipairs(row) do
					local h_name, h_align = std.tbl.parse_pipe_table_header(tbl_headers[j])
					local cell_text = std.txt.limit(cell, maxes[h_name])
					out = out
						.. " "
						.. tss:apply("tbl.cell", std.txt.align(cell_text, maxes[h_name], h_align))
						.. " "
						.. tss:apply("tbl.border.v")
				end
				out = out .. "\n"
			end
		end
		out = out .. string.rep(" ", indent) .. tss:apply("tbl.border.bottom_line") .. "\n"
		if level then
			return out -- don't add additional newline when a table is in a list
		end
		return out .. "\n"
	end
	if el.tag == "section" then
		return tss:apply(el.tag, render_children(el.children))
	end
	-- Unknown element: return empty string to avoid extra blank lines
	return ""
end

local render_djot = function(raw, rss, conf)
	local tss = style.merge(default_djot_rss, rss)
	local conf = conf or {}
	local wrap = conf.wrap or tss.__style.wrap or 0
	local g_indent = conf.global_indent or tss.__style.global_indent or 0
	if g_indent == 0 then
		if conf.global_indent then
			g_indent = conf.global_indent
		end
	end
	if conf.hide_links ~= nil then
		tss.__style.hide_links = conf.hide_links
	end

	raw = raw or ""
	raw = raw:gsub("\t", "    ")

	local doc = djot.parse(raw) or { children = {} }
	local out = ""
	if not doc or not doc.children then
		return ""
	end
	for i, el in ipairs(doc.children) do
		out = out .. render_djot_element(el, tss, wrap, "doc", i)
	end
	return std.txt.indent(out, g_indent)
end

local render = function(raw, rss, conf)
	local conf = conf or {}
	local mode = "raw"
	if conf.mode then
		mode = conf.mode
	end
	if mode == "djot" or mode == "markdown" then
		return render_djot(raw, rss, conf)
	end
	return render_text(raw, rss, conf)
end

local all_braille =
	"⠁⠂⠃⠄⠅⠆⠇⠈⠉⠊⠋⠌⠍⠎⠏⠐⠑⠒⠓⠔⠕⠖⠗⠘⠙⠚⠛⠜⠝⠞⠟⠠⠡⠢⠣⠤⠥⠦⠧⠨⠩⠪⠫⠬⠭⠮⠯⠰⠱⠲⠳⠴⠵⠶⠷⠸⠹⠺⠻⠼⠽⠾⠿⡀⡁⡂⡃⡄⡅⡆⡇⡈⡉⡊⡋⡌⡍⡎⡏⡐⡑⡒⡓⡔⡕⡖⡗⡘⡙⡚⡛⡜⡝⡞⡟⡠⡡⡢⡣⡤⡥⡦⡧⡨⡩⡪⡫⡬⡭⡮⡯⡰⡱⡲⡳⡴⡵⡶⡷⡸⡹⡺⡻⡼⡽⡾⡿⢀⢁⢂⢃⢄⢅⢆⢇⢈⢉⢊⢋⢌⢍⢎⢏⢐⢑⢒⢓⢔⢕⢖⢗⢘⢙⢚⢛⢜⢝⢞⢟⢠⢡⢢⢣⢤⢥⢦⢧⢨⢩⢪⢫⢬⢭⢮⢯⢰⢱⢲⢳⢴⢵⢶⢷⢸⢹⢺⢻⢼⢽⢾⢿⣀⣁⣂⣃⣄⣅⣆⣇⣈⣉⣊⣋⣌⣍⣎⣏⣐⣑⣒⣓⣔⣕⣖⣗⣘⣙⣚⣛⣜⣝⣞⣟⣠⣡⣢⣣⣤⣥⣦⣧⣨⣩⣪⣫⣬⣭⣮⣯⣰⣱⣲⣳⣴⣵⣶⣷⣸⣹⣺⣻⣼⣽⣾⣿"

local mask_with_braille = function(text, hardness, r, g)
	hardness = tonumber(hardness) or 73
	local out = buffer.new()
	local r = r or math.random(50, 255)
	local g = g or math.random(47, 255)

	for c in text:gmatch(std.utf.patterns.glob) do
		local pos = math.random(1, 255)
		local char = std.utf.sub(all_braille, pos, pos)
		if math.random(1, 100) > hardness then
			char = c
			if pos > 99 then
				char = term.style("bold") .. c .. term.style("reset")
			end
		end
		out:put(term.color({ r, g, pos }), char)
	end
	out:put(term.color("reset"))
	return out:get()
end

return {
	render_text = render_text,
	render_djot = render_djot,
	mask_with_braille = mask_with_braille,
	render = render,
}
