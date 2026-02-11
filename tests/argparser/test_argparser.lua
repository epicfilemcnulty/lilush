-- SPDX-FileCopyrightText: © 2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: OWL-1.0 or later
-- Licensed under the Open Weights License v1.0. See LICENSE for details.

local testimony = require("testimony")
local std = require("std")
local argparser = require("argparser")

local testify = testimony.new("== argparser ==")

testify:that("parses GNU long and short value forms", function()
	local parser = argparser
		.command("demo")
		:option("count", { short = "c", type = "number", default = 1 })
		:option("verbose", { short = "v", type = "boolean" })
		:argument("name", { type = "string" })
		:build()

	local args, err = parser:parse({ "--count=7", "-v", "alice" })
	testimony.assert_nil(err)
	testimony.assert_equal(7, args.count)
	testimony.assert_equal(true, args.verbose)
	testimony.assert_equal("alice", args.name)

	args, err = parser:parse({ "-c9", "--no-verbose", "bob" })
	testimony.assert_nil(err)
	testimony.assert_equal(9, args.count)
	testimony.assert_equal(false, args.verbose)
	testimony.assert_equal("bob", args.name)
end)

testify:that("supports short option bundles and value-taking final option", function()
	local parser = argparser
		.command("demo")
		:option("force", { short = "f", type = "boolean" })
		:option("recursive", { short = "r", type = "boolean" })
		:option("output", { short = "o", type = "string" })
		:build()

	local args, err = parser:parse({ "-froresult.txt" })
	testimony.assert_nil(err)
	testimony.assert_equal(true, args.force)
	testimony.assert_equal(true, args.recursive)
	testimony.assert_equal("result.txt", args.output)
end)

testify:that("supports variadic args and end-of-options marker", function()
	local parser = argparser
		.command("files")
		:option("all", { short = "a", type = "boolean" })
		:argument("paths", { type = "string", nargs = "+" })
		:build()

	local args, err = parser:parse({ "-a", "--", "-weird", "normal" })
	testimony.assert_nil(err)
	testimony.assert_equal(true, args.all)
	testimony.assert_equal("-weird", args.paths[1])
	testimony.assert_equal("normal", args.paths[2])
end)

testify:that("validates file and dir argument types", function()
	local tmp_dir = string.format("/tmp/argparser_%d_%d", os.time(), math.random(100000, 999999))
	testimony.assert_true(std.fs.mkdir(tmp_dir))
	local tmp_file = tmp_dir .. "/demo.txt"
	testimony.assert_true(std.fs.write_file(tmp_file, "ok"))

	local parser =
		argparser.command("fs"):argument("file_path", { type = "file" }):argument("dir_path", { type = "dir" }):build()

	local args, err = parser:parse({ tmp_file, tmp_dir })
	testimony.assert_nil(err)
	testimony.assert_equal(tmp_file, args.file_path)
	testimony.assert_equal(tmp_dir, args.dir_path)

	local bad, bad_err = parser:parse({ tmp_dir, tmp_file })
	testimony.assert_nil(bad)
	testimony.assert_equal("parse_error", bad_err.kind)

	testimony.assert_true(std.fs.remove(tmp_dir, true))
end)

testify:that("handles subcommands and default subcommand", function()
	local parser = argparser
		.command("job")
		:command("list", function(sub)
			sub:option("json", { type = "boolean" })
		end)
		:command("start", function(sub)
			sub:argument("cmd", { type = "string" })
			sub:argument("args", { type = "string", nargs = "*", default = {} })
		end)
		:build()
	parser.cfg.default_subcommand = "list"

	local parsed, err = parser:parse({})
	testimony.assert_nil(err)
	testimony.assert_equal("list", parsed.__sub)

	parsed, err = parser:parse({ "start", "echo", "hello" })
	testimony.assert_nil(err)
	testimony.assert_equal("start", parsed.__sub)
	testimony.assert_equal("echo", parsed.__args.cmd)
	testimony.assert_equal("hello", parsed.__args.args[1])
end)

testify:that("returns rich parse errors with suggestions", function()
	local parser = argparser.command("demo"):option("color", { type = "boolean" }):build()

	local parsed, err = parser:parse({ "--colro" })
	testimony.assert_nil(parsed)
	testimony.assert_equal("parse_error", err.kind)
	testimony.assert_equal("unknown_option", err.code)
	testimony.assert_true(#(err.suggestions or {}) >= 1)
	testimony.assert_match("%-%-color", err.suggestions[1])
end)

testify:that("returns help as structured error and formats it", function()
	local parser = argparser
		.command("demo")
		:summary("Demo parser")
		:option("verbose", { short = "v", type = "boolean", note = "Verbose output" })
		:option("count", { short = "c", type = "number", default = 3, note = "Items count" })
		:argument("path", { type = "string", nargs = "?" })
		:argument("inputs", { type = "file", nargs = "+", note = "Input files" })
		:command("run", function(sub)
			sub:summary("Run command")
		end)
		:build()
	parser.cfg.default_subcommand = "run"

	local parsed, err = parser:parse({ "--help" })
	testimony.assert_nil(parsed)
	testimony.assert_equal("help", err.kind)
	local out = argparser.format_error(err)
	testimony.assert_match("^# demo", out)
	testimony.assert_match("## Usage", out)
	testimony.assert_match("## Options", out)
	testimony.assert_match("## Arguments", out)
	testimony.assert_match("## Subcommands", out)
	testimony.assert_match("|", out)
	testimony.assert_match("%-%-no%-verbose", out)
	testimony.assert_match("%.flag", out)
	testimony.assert_match("{%.def", out)
	testimony.assert_match("%.multi", out)
	testimony.assert_match("Demo parser", out)
	testimony.assert_true(not out:match("^Usage:"))
end)

testify:conclude()
