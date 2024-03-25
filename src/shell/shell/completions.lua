-- SPDX-FileCopyrightText: © 2023 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: GPL-3.0-or-later
local term = require("term")
local std = require("std")

local get = function(self)
	if #self.source.variants.candidates > 0 then
		if self.source.variants.chosen <= #self.source.variants.candidates then
			return self.source.variants.candidates[self.source.variants.chosen]
		end
	end
	return ""
end

local available = function(self)
	return self.source:available()
end

local scroll_up = function(self)
	if self.source.variants.chosen > 1 then
		self.source.variants.chosen = self.source.variants.chosen - 1
		return self.source.variants.chosen + 1 -- return previous index for the sake of erasing
	end
	return nil
end

local scroll_down = function(self)
	if self.source.variants.chosen < #self.source.variants.candidates then
		self.source.variants.chosen = self.source.variants.chosen + 1
		return self.source.variants.chosen - 1
	end
	return nil
end

local erase = function(self, index)
	local idx = index or self.source.variants.chosen -- PAY ATTENTION: might provoke edge cases...
	if self.source.variants.chosen > 0 and self.source.variants.candidates[idx] then
		for i = 1, std.utf.len(self.source.variants.candidates[idx]) do
			term.write("\b \b")
		end
		return true
	end
	return nil
end

local flush = function(self)
	self.source:flush()
end

local clear = function(self, index)
	self:erase(index)
	self:flush()
end

local complete = function(self, input)
	return self.source:complete(input)
end

local new = function(source)
	local completions = {
		source = source.new(),
		complete = complete,
		get = get,
		available = available,
		clear = clear,
		erase = erase,
		flush = flush,
		scroll_up = scroll_up,
		scroll_down = scroll_down,
	}
	return completions
end

return { new = new }
