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
local default_config = {
	mode = "client",
	cafile = "/etc/ssl/certs/ca-certificates.crt",
	no_verify_mode = false,
}

local function newcontext(cfg)
	local config = std.tbl.copy(default_config)
	config = std.tbl.merge(config, cfg)

	local succ, msg, ctx
	-- Create the context
	ctx, msg = context.create(config.mode)
	if not ctx then
		return nil, msg
	end
	-- Load the CA certificates
	if config.cafile or config.capath or config.certfile or config.keyfile then
		succ, msg = context.locations(ctx, config.cafile, config.capath, config.certfile, config.keyfile)
		if not succ then
			return nil, msg
		end
	end
	if config.server_name then
		context.sni(ctx, config.server_name)
	end
	if config.no_verify_mode then
		context.no_verify_mode(ctx, config.no_verify_mode)
	end
	return ctx
end

local function wrap(sock, cfg)
	local config = std.tbl.copy(default_config)
	config = std.tbl.merge(config, cfg)
	local ctx, msg = newcontext(config)
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
