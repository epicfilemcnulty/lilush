------------------------------------------------------------------------------
-- LuaSec 1.2.0
--
-- Copyright (C) 2006-2022 Bruno Silvestre
--
------------------------------------------------------------------------------

local core = require("ssl.core")
local context = require("ssl.context")
local std = require("std")
local unpack = table.unpack or unpack

-- We must prevent the contexts to be collected before the connections,
-- otherwise the C registry will be cleared.
local registry = setmetatable({}, { __mode = "k" })

-- Default SSL config
local config = {
	mode = "client",
	cafile = "/etc/ssl/certs/ca-certificates.crt",
	no_verify_mode = false,
}

--
local function newcontext(cfg)
	local succ, msg, ctx
	-- Create the context
	ctx, msg = context.create()
	if not ctx then
		return nil, msg
	end
	-- Mode
	succ, msg = context.setmode(ctx, cfg.mode)
	if not succ then
		return nil, msg
	end
	-- Load the CA certificates
	if cfg.cafile or cfg.capath then
		succ, msg = context.locations(ctx, cfg.cafile, cfg.capath)
		if not succ then
			return nil, msg
		end
	end
	if cfg.server_name then
		context.sni(ctx, cfg.server_name)
	end
	if cfg.no_verify_mode then
		context.no_verify_mode(ctx, cfg.no_verify_mode)
	end
	return ctx
end

--
--
local function wrap(sock, cfg)
	local c = cfg or {}
	c = std.merge_tables(c, config)

	local ctx, msg = newcontext(c)
	local s, msg = core.create(ctx)
	if s then
		core.setfd(s, sock:getfd())
		sock:setfd(core.SOCKET_INVALID)
		registry[s] = ctx
		return s
	end
	return nil, msg
end

--------------------------------------------------------------------------------
-- Export module
--

local _M = {
	config = config,
	newcontext = newcontext,
	wrap = wrap,
}

return _M
