-- SPDX-FileCopyrightText: © 2022—2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: LicenseRef-OWL-1.0-or-later OR GPL-3.0-or-later
-- Dual-licensed under OWL v1.0+ and GPLv3+. See LICENSE and LICENSE-GPL3.

local markdown = require("markdown")
local theme = require("theme").get("shell")

local error = function(err, opts)
	local cfg = opts or {}
	local msg
	if err then
		msg = "`[ERROR]` " .. tostring(err)
		if cfg.status ~= nil then
			msg = msg .. " **(" .. tostring(cfg.status) .. ")**"
		end
	elseif cfg.status ~= nil then
		msg = "`[ERROR]` exit **(" .. tostring(cfg.status) .. ")**"
	else
		msg = "`[ERROR]` unknown error"
	end
	local out = markdown.render(msg, { rss = theme.errors.builtin_markdown })
	io.stderr:write(out.rendered)
	io.stderr:flush()
end

local warning = function(msg)
	io.stderr:write("warning: " .. tostring(msg) .. "\n")
	io.stderr:flush()
end

local report = function(msg)
	local out = markdown.render(tostring(msg), { rss = theme.errors.builtin_markdown })
	io.stderr:write(out.rendered)
	io.stderr:flush()
end

local help = function(msg)
	local out = "\n" .. markdown.render(msg).rendered .. "\n"
	io.stderr:write(out)
	io.stderr:flush()
end

return { error = error, warning = warning, report = report, help = help }
