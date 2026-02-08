-- SPDX-FileCopyrightText: © 2022—2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: LicenseRef-OWL-1.0-or-later OR GPL-3.0-or-later
-- Dual-licensed under OWL v1.0+ and GPLv3+. See LICENSE and LICENSE-GPL3.

--[[ 
Minimal testing framework for Lilush
]]

local term = require("term")
local style = require("term.tss")

local testimony_rss = {
	passed = { fg = "green", s = "bold", content = "✓" },
	failed = { fg = "red", s = "bold", content = "✗" },
	failure = { fg = "red", s = "inverted,bold" },
	title = { fg = "green", s = "inverted,bold" },
	error = { fg = "red", s = "dim" },
}
local tss = style.new(testimony_rss)

-- Deep equality check for tables
local function deep_equal(a, b, visited)
	if type(a) ~= type(b) then
		return false
	end
	if type(a) ~= "table" then
		return a == b
	end

	visited = visited or {}
	visited[a] = visited[a] or {}
	if visited[a][b] then
		return true
	end
	visited[a][b] = true

	for k, v in pairs(a) do
		if not deep_equal(v, b[k], visited) then
			return false
		end
	end
	for k, v in pairs(b) do
		if not deep_equal(v, a[k], visited) then
			return false
		end
	end
	return true
end

-- Format value for display
local function format_value(v, visited, depth)
	visited = visited or {}
	depth = depth or 0
	if depth > 10 then
		return "{...}"
	end -- Depth limit

	if type(v) == "string" then
		return '"' .. v .. '"'
	elseif type(v) == "table" then
		if visited[v] then
			return "{cyclic}"
		end
		visited[v] = true

		local items = {}
		local keys = {}
		for k in pairs(v) do
			table.insert(keys, k)
		end
		table.sort(keys, function(a, b)
			return tostring(a) < tostring(b)
		end)
		for _, k in ipairs(keys) do
			table.insert(items, tostring(k) .. "=" .. format_value(v[k], visited, depth + 1))
		end
		return "{" .. table.concat(items, ", ") .. "}"
	else
		return tostring(v)
	end
end

local assert_equal = function(expected, actual, msg)
	if not deep_equal(expected, actual) then
		local err = msg or ("expected " .. format_value(expected) .. " but got " .. format_value(actual))
		error(err, 2)
	end
end

local assert_true = function(value, msg)
	if not value then
		error(msg or "expected truthy value but got " .. tostring(value), 2)
	end
end

local assert_false = function(value, msg)
	if value then
		error(msg or "expected falsy value but got " .. tostring(value), 2)
	end
end

local assert_nil = function(value, msg)
	if value ~= nil then
		error(msg or "expected nil but got " .. tostring(value), 2)
	end
end

local assert_not_nil = function(value, msg)
	if value == nil then
		error(msg or "expected non-nil value but got nil", 2)
	end
end

local assert_error = function(fn, expected_pattern, msg)
	local success, err = pcall(fn)
	if success then
		error(msg or "expected function to throw error but it succeeded", 2)
	end
	local err_str = tostring(err)
	if expected_pattern and not string.match(err_str, expected_pattern) then
		error(msg or ("expected error matching '" .. expected_pattern .. "' but got: " .. err_str), 2)
	end
end

local assert_match = function(pattern, str, msg)
	local str_val = tostring(str)
	if not string.match(str_val, pattern) then
		error(msg or ("expected '" .. str_val .. "' to match pattern '" .. pattern .. "'"), 2)
	end
end

local test = function(self, description, fn)
	self.tests.run = self.tests.run + 1
	local success, err = pcall(fn)

	if success then
		self.tests.passed = self.tests.passed + 1
	else
		self.tests.failed = self.tests.failed + 1
		table.insert(self.tests.failures, {
			name = description,
			error = err,
		})
	end
end

local conclude = function(self)
	print(tss:apply("title", tostring(self.description)).text)
	if self.tests.failed == 0 then
		print(tss:apply("passed").text .. " " .. self.tests.passed .. " tests passed.")
		os.exit(0)
	end
	print(tss:apply("passed").text .. " " .. self.tests.passed .. " tests passed.")
	print(tss:apply("failed").text .. " " .. self.tests.failed .. " tests failed.")
	for _, failure in ipairs(self.tests.failures) do
		print(tss:apply("failure", failure.name).text)
		print(tss:apply("error", failure.error).text)
	end
	os.exit(1)
end

local new = function(description)
	local obj = {
		description = description or "",
		tests = {
			run = 0,
			passed = 0,
			failed = 0,
			failures = {},
		},
		that = test,
		conclude = conclude,
	}
	return obj
end

return {
	new = new,
	assert_equal = assert_equal,
	assert_true = assert_true,
	assert_false = assert_false,
	assert_nil = assert_nil,
	assert_not_nil = assert_not_nil,
	assert_error = assert_error,
	assert_match = assert_match,
}
