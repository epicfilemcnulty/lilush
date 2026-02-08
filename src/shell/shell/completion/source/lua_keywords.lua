-- SPDX-FileCopyrightText: © 2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: OWL-1.0 or later
-- Licensed under the Open Weights License v1.0. See LICENSE for details.

local std = require("std")

local DEFAULT_KEYWORDS = {
	"and",
	"break",
	"do",
	"else",
	"elseif",
	"end",
	"false",
	"for",
	"function",
	"goto",
	"if",
	"in",
	"local",
	"nil",
	"not",
	"or",
	"repeat",
	"return",
	"then",
	"true",
	"until",
	"while",
}

local update = function(self)
	return nil
end

local search = function(self, prefix)
	local variants = {}
	local escaped = std.escape_magic_chars(prefix or "")
	for _, keyword in ipairs(self.cfg.keywords) do
		if keyword:match("^" .. escaped) then
			table.insert(variants, keyword)
		end
	end
	table.sort(variants, function(a, b)
		if #a == #b then
			return a < b
		end
		return #a < #b
	end)
	return variants
end

local new = function(config)
	local cfg = {
		keywords = DEFAULT_KEYWORDS,
	}
	if config then
		std.tbl.merge(cfg, config)
	end
	return {
		cfg = cfg,
		__state = {},
		update = update,
		search = search,
	}
end

return {
	new = new,
}
