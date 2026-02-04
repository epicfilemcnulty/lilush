-- SPDX-FileCopyrightText: © 2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: OWL-1.0 or later
-- Licensed under the Open Weights License v1.0. See LICENSE for details.

local testimony = require("testimony")
local std = require("std")

local testify = testimony.new("== std.mime functions ==")

testify:that("mime.type detects common text types", function()
	testimony.assert_equal("text/html", std.mime.type("index.html"))
	testimony.assert_equal("text/html", std.mime.type("page.htm"))
	testimony.assert_equal("text/css", std.mime.type("style.css"))
	testimony.assert_equal("text/javascript", std.mime.type("app.js"))
	testimony.assert_equal("text/plain", std.mime.type("readme.txt"))
	testimony.assert_equal("text/markdown", std.mime.type("readme.md"))
	testimony.assert_equal("text/djot", std.mime.type("doc.djot"))
end)

testify:that("mime.type detects image types", function()
	testimony.assert_equal("image/png", std.mime.type("photo.png"))
	testimony.assert_equal("image/jpeg", std.mime.type("photo.jpg"))
	testimony.assert_equal("image/jpeg", std.mime.type("photo.jpeg"))
	testimony.assert_equal("image/gif", std.mime.type("animation.gif"))
	testimony.assert_equal("image/svg+xml", std.mime.type("icon.svg"))
	testimony.assert_equal("image/webp", std.mime.type("image.webp"))
end)

testify:that("mime.type detects font types", function()
	testimony.assert_equal("font/woff", std.mime.type("font.woff"))
	testimony.assert_equal("font/woff2", std.mime.type("font.woff2"))
	testimony.assert_equal("font/ttf", std.mime.type("font.ttf"))
	testimony.assert_equal("font/otf", std.mime.type("font.otf"))
end)

testify:that("mime.type detects video types", function()
	testimony.assert_equal("video/mp4", std.mime.type("video.mp4"))
	testimony.assert_equal("video/webm", std.mime.type("video.webm"))
	testimony.assert_equal("video/x-matroska", std.mime.type("movie.mkv"))
end)

testify:that("mime.type detects audio types", function()
	testimony.assert_equal("audio/mpeg", std.mime.type("song.mp3"))
	testimony.assert_equal("audio/ogg", std.mime.type("sound.ogg"))
	testimony.assert_equal("audio/wav", std.mime.type("audio.wav"))
end)

testify:that("mime.type detects application types", function()
	testimony.assert_equal("application/json", std.mime.type("data.json"))
	testimony.assert_equal("application/lua", std.mime.type("script.lua"))
	testimony.assert_equal("application/pdf", std.mime.type("document.pdf"))
	testimony.assert_equal("application/zip", std.mime.type("archive.zip"))
	testimony.assert_equal("application/gzip", std.mime.type("file.gz"))
end)

testify:that("mime.type detects source code as text/plain", function()
	testimony.assert_equal("text/plain", std.mime.type("main.c"))
	testimony.assert_equal("text/plain", std.mime.type("main.cpp"))
	testimony.assert_equal("text/plain", std.mime.type("main.rs"))
	testimony.assert_equal("text/plain", std.mime.type("main.go"))
	testimony.assert_equal("text/plain", std.mime.type("script.sh"))
end)

testify:that("mime.type returns octet-stream for unknown types", function()
	testimony.assert_equal("application/octet-stream", std.mime.type("file.xyz"))
	testimony.assert_equal("application/octet-stream", std.mime.type("unknown"))
	testimony.assert_equal("application/octet-stream", std.mime.type("noextension"))
end)

testify:that("mime.type handles empty or nil input", function()
	testimony.assert_equal("application/octet-stream", std.mime.type(""))
	testimony.assert_equal("application/octet-stream", std.mime.type(nil))
end)

testify:that("mime.application returns string or empty string", function()
	local result = std.mime.application("text/html")
	testimony.assert_true(type(result) == "string")
end)

testify:that("mime.info returns table with expected fields", function()
	local info = std.mime.info("test.html")
	testimony.assert_true(type(info) == "table")
	testimony.assert_equal("text/html", info.type)
	testimony.assert_true(type(info.default_app) == "string")
	testimony.assert_true(type(info.cmdline) == "string")
end)

testify:conclude()
