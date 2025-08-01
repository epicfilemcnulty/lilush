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
			task = { content = "[]", nested = { content = "[]" } },
		},
		ol = { s = "bold" },
	},
	tbl = {
		header = { s = "italic,bold" },
		border = default_borders,
	},
	thematic_break = { w = 0.9, align = "center" },
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
}

local render_text = function(raw, rss, conf)
	local raw = raw or ""
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
local typographics = {
	["en_dash"] = "–",
	["em_dash"] = "—",
	["ellipsis"] = "…",
	["right_single_quote"] = "’",
	["left_single_quote"] = "‘",
	["right_double_quote"] = "”",
	["left_double_quote"] = "“",
}

local render_djot_element
render_djot_element = function(el, tss, wrap, parent, list_item_idx)
	local wrap = wrap or 0
	local codeblock_wrap = tss.__style.codeblock_wrap
	local parent = parent or "str"
	local list_item_idx = list_item_idx or 1
	local get_children = function(children, p)
		local out = ""
		for i, child in ipairs(children) do
			out = out .. render_djot_element(child, tss, wrap, p, i)
		end
		return out
	end
	local get_list_info = function(parent)
		if parent:match("list") then
			local list_style = parent:match("([^/]+)$") or "star"
			local level = 0
			local indent = 0
			for _ in parent:gmatch("|") do
				level = level + 1
			end
			if list_style:match("%d") then
				indent = #tostring(list_item_idx) + 2 + level * 2 -- list index + dot + space
			elseif list_style == ":" then
				indent = 2 + level * 2
			else
				indent = 2 + level * 2 -- list marker + space
			end
			return level, indent, list_style
		end
		return nil
	end
	local get_classes = function(e, tag)
		local classes = {}
		if e.attr and e.attr.class then
			for class in e.attr.class:gmatch("(%S+)%s?") do
				if tss.__style.class[tag] and tss.__style.class[tag][class] then
					table.insert(classes, "class." .. tag .. "." .. class)
				elseif tss.__style.class[class] then
					table.insert(classes, "class." .. class)
				end
			end
		end
		return classes
	end

	if typographics[el.tag] then
		return typographics[el.tag]
	end
	if el.tag == "softbreak" then
		return " "
	end
	if el.tag == "str" then
		if parent == "str" then
			return el.text
		end
		return tss:apply(parent, el.text)
	end
	if el.tag == "single_quoted" then
		return tss:apply(parent, "‘") .. get_children(el.children, parent) .. tss:apply(parent, "’")
	end
	if el.tag == "double_quoted" then
		return tss:apply(parent, "“") .. get_children(el.children, parent) .. tss:apply(parent, "”")
	end
	if el.tag == "emph" or el.tag == "strong" then
		return tss:apply({ parent, el.tag }, get_children(el.children))
	end
	if el.tag == "verbatim" then
		local elements = get_classes(el, el.tag)
		return tss:apply({ el.tag, unpack(elements) }, el.text)
	end
	if el.tag == "link" then
		if tss.__style.hide_links then
			tss.__style.link.url.content = ""
		end
		local elements = get_classes(el, el.tag)
		local target = el.destination or el.reference
		local title = get_children(el.children)
		return tss:apply({ "link.title", unpack(elements) }, title) .. tss:apply("link.url", target)
	end
	if el.tag == "thematic_break" then
		tss.__style.w = wrap
		return tss:apply(el.tag, el.text) .. "\n"
	end
	if el.tag == "heading" then
		tss.__style.header.level.w = el.level
		return tss:apply("header.level") .. " " .. get_children(el.children, "header") .. "\n\n"
	end
	if el.tag == "code_block" then
		local out = ""
		local indent = 0
		local padding = tss.__style.codeblock.padding or 0
		local level, list_indent, list_style = get_list_info(parent)
		if level then
			indent = list_indent
			out = "\n"
		end
		if wrap > 0 then
			tss.__style.codeblock.w = wrap + indent + padding * 2
			tss.__style.codeblock.border.w = wrap + indent + padding * 2
		end
		local elements = get_classes(el, "codeblock")
		local top_line = tss:apply("codeblock.border.top_line")
		if el.lang and el.lang ~= "" then
			local lang = tss:apply("codeblock.lang", el.lang)
			local st = tss:apply(
				"codeblock.border",
				tss.__style.codeblock.border.top_line.before .. tss.__style.codeblock.border.top_line.content
			)
			local lang_len = std.utf.len(lang)
			st = st
				.. lang
				.. tss:apply(
					"codeblock.border",
					string.rep(
						tss.__style.codeblock.border.top_line.content,
						wrap + indent + padding * 2 - lang_len - 1
					) .. tss.__style.codeblock.border.top_line.after
				)
			top_line = st
		end
		local content = std.txt.lines(el.text)
		if wrap > 0 and codeblock_wrap then
			content = std.txt.lines_of(table.concat(content, "\n"), wrap, true)
		end
		out = out .. string.rep(" ", indent) .. top_line .. "\n"
		for _, l in ipairs(content) do
			out = out
				.. string.rep(" ", indent)
				.. tss:apply("codeblock.border.v")
				.. tss:apply({ "codeblock", unpack(elements) }, l)
				.. tss:apply("codeblock.border.v")
				.. "\n"
		end
		out = out .. string.rep(" ", indent) .. tss:apply("codeblock.border.bottom_line") .. "\n"
		return out .. "\n"
	end
	if el.tag == "div" then
		local elements = get_classes(el, el.tag)
		return tss:apply({ el.tag, unpack(elements) }, get_children(el.children, "div"))
	end
	if el.tag == "para" then
		local elements = get_classes(el, parent)
		local content = tss:apply({ el.tag, unpack(elements) }, get_children(el.children, "para"))
		local trailing_newline = "\n\n"
		local indent = 0
		local list_level, list_indent, list_style = get_list_info(parent)
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
		local level, list_indent, list_style = get_list_info(parent)
		local out = ""
		local def = ""
		local def_term = get_children(el.children[1].children, "list.definition.term")
		if el.children[2] then
			def = get_children(el.children[2].children, parent)
		end
		out = out .. string.rep(" ", list_indent) .. tss:apply("list.definition.term", def_term) .. "\n"
		tss.__style.list.definition.suffix.w = std.utf.len(def_term)
		out = out .. string.rep(" ", list_indent) .. tss:apply("list.definition.suffix") .. "\n\n"
		out = out .. string.rep(" ", list_indent) .. tss:apply("list.definition.def", def) .. "\n"
		return out
	end
	if el.tag == "list_item" then
		local level, list_indent, list_style = get_list_info(parent)
		local marker
		if not list_style:match("%d") then
			local styles = { ["X"] = "task", ["*"] = "star", ["-"] = "minus", ["+"] = "plus" }
			if level == 1 then
				marker = tss:apply("list.ul." .. styles[list_style])
			else
				marker = tss:apply("list.ul." .. styles[list_style] .. ".nested")
			end
		else
			marker = tss:apply("list.ol", tostring(list_item_idx) .. ".")
		end
		return string.rep(" ", level * 2) .. marker .. " " .. get_children(el.children, parent)
	end
	if el.tag == "list" then
		if parent:match("list") then
			return get_children(el.children, parent .. "|list/" .. el.style) .. "\n"
		else
			return get_children(el.children, "list/" .. el.style) .. "\n" -- used to be two newlines
		end
	end
	if el.tag == "table" then
		local tbl_headers = {}
		local tbl_data = {}
		local indent = 0
		local level, list_indent, list_style = get_list_info(parent)
		if level then
			indent = list_indent
		end
		for i, row in ipairs(el.children) do
			tbl_data[i] = {}
			for j, cell in ipairs(row.children) do
				local cell_content = cell.text or ""
				if cell.children then
					cell_content = get_children(cell.children)
				end
				if cell.head then
					tbl_headers[j] = { cell_content, cell.align or "left" }
				else
					tbl_data[i][j] = cell_content
				end
			end
		end
		local maxes = std.tbl.calc_table_maxes(tbl_headers, tbl_data)
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
			out = out
				.. " "
				.. tss:apply("tbl.header", std.txt.align(h_name, maxes[h_name], "center"))
				.. " "
				.. tss:apply("tbl.border.v")
		end
		out = out .. "\n" .. string.rep(" ", indent) .. tss:apply("tbl.border.subtitle_line") .. "\n"
		for i, row in ipairs(tbl_data) do
			if #row > 0 then
				out = out .. string.rep(" ", indent) .. tss:apply("tbl.border.v")
				for j, cell in ipairs(row) do
					local h_name, h_align = std.tbl.parse_pipe_table_header(tbl_headers[j])
					out = out
						.. " "
						.. tss:apply("tbl.cell", std.txt.align(cell, maxes[h_name], h_align))
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
		return tss:apply(el.tag, get_children(el.children))
	end
	return "\n"
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

	local raw = raw or ""
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
	math.randomseed(os.time())
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
