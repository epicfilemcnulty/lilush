-- SPDX-FileCopyrightText: © 2023 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: GPL-3.0-or-later

local mime_types = {
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
	local filename = filename or ""
	local extension = filename:match("%.(%w+)$")
	if extension then
		for t, exts in pairs(mime_types) do
			if exts[extension] then
				return t
			end
		end
	end
	return "application/octet-stream"
end

return { type = mime_type }
