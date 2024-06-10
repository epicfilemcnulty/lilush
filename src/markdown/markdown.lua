-- SPDX-FileCopyrightText: © 2023 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: GPL-3.0-or-later

--[[ 
     Simple markdown parser, sort of trying to comply with https://github.github.com/gfm specs,
     but to a certain extent, you know, because some peculiarities of the standard 
     turned out to be particularly hard to implement without completely losing your shit over it :-)

     We parse markdown to a "linear" AST, so to say: elements don't have children, but
     list item elements are marked as such...
                                                    ]]

local std = require("std")

local block_type = function(line)
	local line = line or ""

	if line == "" or line:match("^%s*$") then
		return { t = "newline", indent = 0 }
	end

	-- Count and then remove leading spaces and tabs
	local spaces = 0
	for c in line:gmatch(".") do
		if c == " " then
			spaces = spaces + 1
		elseif c == "\t" then
			spaces = spaces + 4
		else
			break
		end
	end
	if spaces > 0 then
		line = line:gsub("^(%s+)", "")
	end

	local element = { indent = spaces, t = "p" }
	-- headers, thematic breaks and blockquotes are only allowed to have no more than 3 leading spaces,
	-- so let's check this case first.
	-- Theoretically, blockquotes can be contained within list items, but I'm not sure if we
	-- want to deal with it...
	if spaces <= 3 then
		-- Regular headers
		local level, header = line:match("^(#+)%s+(.*)")
		if level and level ~= "" then
			element.level = #level
			element.t = "header"
			element.content = header
			return element
		end
		-- Setext headers are evil!
		if line:match("^=+%s*$") then
			element.level = 1
			element.t = "setext"
			return element
		end
		if line:match("^%-+%s*$") then
			element.level = 2
			element.t = "setext"
			return element
		end
		-- Simplified thematic break
		if line:match("^[_%s]+$") or line:match("^[-%s]+$") or line:match("^[*%s]+$") then
			element.t = "thematic_break"
			return element
		end
	end
	-- Fenced codeblock
	if line:match("^```+") then
		element.t = "codeblock"
		return element
	end
	-- List item
	if line:match("^%d-[.)]%s") or line:match("^[-+]%s") or line:match("^%*%s") then
		local subtype = "ul"
		local variant = "star"
		local content = line:match("^%d-[.)]%s+(.*)")
		if line:match("^%d") then
			subtype = "ol"
			variant = "arabic"
		else
			if line:match("^%-") then
				variant = "minus"
				content = line:match("^%-%s+(.*)")
			elseif line:match("^%+") then
				variant = "plus"
				content = line:match("^%+%s+(.*)")
			else
				content = line:match("^%*%s+(.*)")
			end
		end
		element.t = "list"
		element.subtype = subtype
		element.variant = variant
		element.content = content
		local _, offset = line:find("%S+%s+%S")
		local offset = offset or 1
		element.indent = element.indent + offset - 1
		return element
	end
	return element
end

local parse_inline_elements = function(ast)
	local out = {}
	for i, v in pairs(ast) do
		if v.t == "header" or v.t == "p" then
			local str = table.concat(v.lines, " ")
			local splits = std.txt.split_by(str, "`[^`]+`", 1, 1)
			local l1 = {}
			for i, v in ipairs(splits) do
				if v.t == "cap" then
					table.insert(l1, { t = "verbatim", c = v.c })
				else
					local bolds = std.txt.split_by(v.c, "%*%*[^*]+%*%*", 2, 2)
					for i1, v1 in ipairs(bolds) do
						if v1.t == "cap" then
							table.insert(l1, { t = "strong", c = v1.c })
						else
							table.insert(l1, v1)
						end
					end
				end
			end
			local l2 = {}
			for i, v in ipairs(l1) do
				if v.t ~= "reg" then
					table.insert(l2, v)
				else
					local italics = std.txt.split_by(v.c, "%*[^*]+%*", 1, 1)
					for i1, v1 in ipairs(italics) do
						if v1.t == "cap" then
							table.insert(l2, { t = "emph", c = v1.c })
						else
							table.insert(l2, v1)
						end
					end
				end
			end
			local l3 = {}
			for i, v in pairs(l2) do
				if v.t ~= "reg" then
					table.insert(l3, v)
				else
					local links = std.txt.split_by(v.c, "%[[^[%]]+%]%([^()]+%)")
					for i1, v1 in ipairs(links) do
						if v1.t == "cap" then
							local title = v1.c:match("%[([^[%]]+)%]")
							local link = v1.c:match("%[[^[%]]+%]%(([^()]+)%)")
							table.insert(l3, { t = "link", title = title, link = link })
						else
							table.insert(l3, v1)
						end
					end
				end
			end
			v.lines = l3
			l1 = nil
			l2 = nil
			str = nil
		end
		table.insert(out, v)
	end
	return out
end

local build_ast = function(raw)
	local raw = raw or ""
	if not raw:match("\n$") then
		raw = raw .. "\n"
	end

	local ast = {}
	local ast_idx = 0

	local new_block = function()
		local block = {
			t = "p",
			indent = 0,
			lines = {},
			__in_list = false,
			__prev_item = 0,
		}
		local save = function(self)
			if self.t == "list" or #self.lines > 0 then
				if self.__in_list then
					if not self.list_item and self.t ~= "list" then
						self.__in_list = false
						table.insert(ast, { t = "newline" })
						ast_idx = ast_idx + 1
					end
					if self.list_item and self.list_item == 1 and self.__prev_item == 1 then
						table.insert(ast, { t = "newline" })
						ast_idx = ast_idx + 1
					end
				elseif self.list_item then
					self.__in_list = true
					self.__prev_item = 0
				end
				table.insert(ast, {
					t = self.t,
					lines = self.lines,
					indent = self.indent,
					list_item = self.list_item,
					level = self.level,
					subtype = self.subtype,
					variant = self.variant,
					items = self.items,
					parent = self.parent,
					lang = self.lang,
				})
				ast_idx = ast_idx + 1
				if self.t ~= "list" and (not self.__in_list or self.__prev_item == self.list_item) then
					table.insert(ast, { t = "newline" })
					ast_idx = ast_idx + 1
				end
				if self.list_item then
					self.__prev_item = self.list_item
				end
			else
				--table.insert(ast, { t = "newline" })
				--ast_idx = ast_idx + 1
			end
			self.t = "p"
			self.lines = {}
			self.indent = 0
			self.list_item = nil
			self.level = nil
			self.parent = nil
			self.subtype = nil
			self.variant = nil
			self.items = nil
		end
		block.save = save
		return block
	end

	local block = new_block()
	local list_idx = 0

	local find_idx = function(start_idx, indent)
		local idx = start_idx or 0
		if not ast[start_idx] then
			return 0
		end
		while idx > 0 and indent < ast[idx].indent do
			if ast[idx].parent then
				idx = ast[idx].parent
			else
				idx = 0
			end
		end
		return idx
	end

	for line in raw:gmatch("(.-)\n") do
		local element = block_type(line)

		if block.t == "p" then
			if element.t == "newline" then
				block:save()
			elseif element.t == "list" then
				block:save()
				local idx = find_idx(list_idx, element.indent)
				if idx == 0 or element.indent > ast[idx].indent then
					block.parent = list_idx
					list_idx = ast_idx + 1
					block.t = "list"
					block.indent = element.indent
					block.subtype = element.subtype
					block.variant = element.variant
					block.items = 1
					block.lines = nil
					block:save()
					local l, c = element.content:gsub("(%S)  $", "%1")
					block.indent = element.indent
					block.lines = { l }
					block.list_item = 1
					block.parent = list_idx
					if c > 0 then
						block:save()
					end
				else
					ast[idx].items = ast[idx].items + 1
					block.indent = element.indent
					local l, c = element.content:gsub("(%S)  $", "%1")
					block.lines = { l }
					block.list_item = ast[idx].items
					block.parent = idx
					if c > 0 then
						block:save()
					end
				end
			elseif element.t == "codeblock" then
				block:save()
				local idx = find_idx(list_idx, element.indent)
				if idx > 0 and element.indent >= ast[idx].indent then
					block.list_item = ast[idx].items
					block.parent = idx
				else
					list_idx = 0
				end
				block.t = "codeblock"
				block.lang = line:match("^%s*```+(.*)") or ""
				block.indent = element.indent
				block.lines = {}
			elseif element.t == "header" then
				block:save()
				list_idx = 0
				block.t = "header"
				block.level = element.level
				block.indent = element.indent
				block.lines = { element.content }
				block:save()
			elseif element.t == "setext" then
				if #block.lines > 0 then
					list_idx = 0
					block.t = "header"
					block.level = element.level
					block.indent = element.indent
					block:save()
				elseif element.level == 2 then
					block.t = "thematic_break"
					list_idx = 0
					block.lines = { line }
					block:save()
				else
					table.insert(block.lines, line)
				end
			elseif element.t == "thematic_break" then
				block:save()
				list_idx = 0
				block.t = "thematic_break"
				block.indent = element.indent
				block.lines = { line }
				block:save()
			else
				block.indent = element.indent
				local idx = find_idx(list_idx, element.indent)
				if idx > 0 and element.indent >= ast[idx].indent then
					block.list_item = ast[list_idx].items
					block.parent = idx
				else
					list_idx = 0
				end
				local l_ = line:gsub("^%s*", "")
				local l, c = l_:gsub("(%S)  $", "%1")
				table.insert(block.lines, l)
				if c > 0 then
					block:save()
				end
			end
		else
			if block.t == "codeblock" then
				if element.t == "codeblock" then
					block:save()
				else
					local l = line:gsub("^" .. string.rep(" ", block.indent), "")
					table.insert(block.lines, l)
				end
			end
		end
	end
	block:save()
	return parse_inline_elements(ast)
end

return {
	ast = build_ast,
}
