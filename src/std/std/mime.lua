-- SPDX-FileCopyrightText: © 2022—2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: LicenseRef-OWL-1.0-or-later OR GPL-3.0-or-later
-- Dual-licensed under OWL v1.0+ and GPLv3+. See LICENSE and LICENSE-GPL3.

local ps = require("std.ps")
local fs = require("std.fs")

local MIME_TYPES = {
	["text/html"] = { html = true, htm = true, shtml = true },
	["text/css"] = { css = true },
	["text/plain"] = {
		txt = true,
		c = true,
		cpp = true,
		rs = true,
		go = true,
		h = true,
		sh = true,
		lsh = true,
	},
	["text/calendar"] = { ics = true },
	["text/xml"] = { xml = true },
	["text/csv"] = { csv = true },
	["text/markdown"] = { md = true, markdown = true },
	["text/djot"] = { dj = true, djot = true },
	["text/javascript"] = { js = true },

	["font/woff"] = { woff = true },
	["font/woff2"] = { woff2 = true },
	["font/otf"] = { otf = true },
	["font/ttf"] = { ttf = true },

	["image/gif"] = { gif = true },
	["image/png"] = { png = true },
	["image/heic"] = { heic = true, HEIC = true },
	["image/jpeg"] = { jpg = true, jpeg = true },
	["image/tiff"] = { tif = true, tiff = true },
	["image/x-icon"] = { ico = true },
	["image/svg+xml"] = { svg = true, svgz = true },
	["image/webp"] = { webp = true },

	["audio/mpeg"] = { mp3 = true },
	["audio/ogg"] = { ogg = true },
	["audio/wav"] = { wav = true },

	["video/x-msvideo"] = { avi = true },
	["video/mpeg"] = { mpeg = true },
	["video/mp4"] = { mp4 = true },
	["video/x-matroska"] = { mkv = true },
	["video/webm"] = { webm = true },

	["application/atom+xml"] = { atom = true },
	["application/rss+xml"] = { rss = true },
	["application/json"] = { json = true },
	["application/lua"] = { lua = true },
	["application/pdf"] = { pdf = true },
	["application/zip"] = { zip = true },
	["application/x-tar"] = { tar = true },
	["application/x-bzip"] = { bz = true },
	["application/x-bzip2"] = { bz2 = true },
	["application/gzip"] = { gz = true, gzip = true },
	["application/epub+zip"] = { epub = true },

	["application/octet-stream"] = { bin = true, exe = true, dll = true, iso = true, img = true, dmg = true },
}

local mime_type = function(filename)
	filename = filename or ""
	local extension = filename:match("%.(%w+)$")
	if extension then
		for t, exts in pairs(MIME_TYPES) do
			if exts[extension] then
				return t
			end
		end
	end
	return "application/octet-stream"
end

local mime_default_app = function(m_type)
	m_type = m_type or ""
	local home = os.getenv("HOME") or ""
	local mime_apps_xdg_system = fs.read_file("/etc/xdg/mimeapps.list") or ""
	local mime_apps_usr_share = fs.read_file("/usr/share/applications/mimeapps.list") or ""
	local mime_apps_usr_local = fs.read_file("/usr/local/share/applications/mimeapps.list") or ""
	local mime_apps_user = fs.read_file(home .. "/.config/mimeapps.list") or ""
	m_type = m_type:gsub("[+%%%.%$[%]%(%)-]", "%%%1")
	local app = mime_apps_user:match("\n" .. m_type .. "=(.-);?\n")
	if not app then
		app = mime_apps_usr_local:match("\n" .. m_type .. "=(.-);?\n") or ""
	end
	if not app then
		app = mime_apps_usr_share:match("\n" .. m_type .. "=(.-);?\n") or ""
	end
	if not app then
		app = mime_apps_xdg_system:match("\n" .. m_type .. "=(.-);?\n") or ""
	end
	return app
end

local mime_info = function(filename)
	local m_type = mime_type(filename)
	local default_app = mime_default_app(m_type)
	local info = {
		type = m_type,
		default_app = default_app,
		cmdline = "xdg-open",
	}
	local home = os.getenv("HOME") or ""
	local content
	if fs.file_exists(home .. "/.local/share/applications/" .. default_app) then
		content = fs.read_file(home .. "/.local/share/applications/" .. default_app)
	elseif fs.file_exists("/usr/local/share/applications/" .. default_app) then
		content = fs.read_file("/usr/local/share/applications/" .. default_app)
	elseif fs.file_exists("/usr/share/applications/" .. default_app) then
		content = fs.read_file("/usr/share/applications/" .. default_app)
	end
	if content then
		info.cmdline = content:match("\nExec=(.-)\n") or ""
	end
	return info
end

return { type = mime_type, application = mime_default_app, info = mime_info }
