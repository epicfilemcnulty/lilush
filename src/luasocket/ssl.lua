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

--
local function newcontext(cfg)
	local succ, msg, ctx
	-- Create the context
	local mode = cfg.mode or "client"
	ctx, msg = context.create(mode)
	if not ctx then
		return nil, msg
	end

	succ, msg = context.setmode(ctx, mode)
	-- Load the CA certificates
	if cfg.cafile or cfg.capath or cfg.certfile or cfg.keyfile then
		succ, msg = context.locations(ctx, cfg.cafile, cfg.capath, cfg.certfile, cfg.keyfile)
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

local function wrap(sock, cfg)
	local cfg = cfg
		or {
			mode = "client",
			cafile = "/etc/ssl/certs/ca-certificates.crt",
			no_verify_mode = false,
		}
	local ctx, msg = newcontext(cfg)
	if not ctx then
		return nil, msg
	end

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
	newcontext = newcontext,
	wrap = wrap,
}

return _M
