local std = require("std")
local ws = require("web_server")
local json = require("cjson.safe")
local handle = require("reliw.handle")
local acme_manager = require("reliw.acme")
local store = require("reliw.store")

local configure = function(srv_cfg)
	srv_cfg.data_dir = srv_cfg.data_dir or "/www"
	srv_cfg.redis_prefix = srv_cfg.redis_prefix or "RLW"
	srv_cfg.redis_url = srv_cfg.redis_url or "127.0.0.1:6379/13"
	srv_cfg.cache_max = srv_cfg.cache_max or 5242880
	std.ps.setenv("RELIW_DATA_DIR", srv_cfg.data_dir)
	std.ps.setenv("RELIW_REDIS_PREFIX", srv_cfg.redis_prefix)
	std.ps.setenv("RELIW_REDIS_URL", srv_cfg.redis_url)
	std.ps.setenv("RELIW_CACHE_MAX", srv_cfg.cache_max)
end

local get_server_config = function()
	local config_file = os.getenv("RELIW_CONFIG_FILE") or "/etc/reliw/config.json"
	if not std.fs.file_exists(config_file) then
		return nil, "no config file found"
	end
	local config = json.decode(std.fs.read_file(config_file))
	if not config then
		return nil, "failed to read/decode config file"
	end
	configure(config)
	return config
end

local new_server = function(srv_cfg)
	local srv, err = ws.new(srv_cfg, handle.func)
	if not srv then
		return nil, err
	end
	return srv
end

local ssl_config_from_acme = function(srv_cfg)
	local certs_dir = srv_cfg.data_dir .. "/.acme/certs/"
	local ssl = {}
	for i, cert in ipairs(srv_cfg.ssl.acme.certificates) do
		for j, name in ipairs(cert.names) do
			local primary = cert.names[1]:gsub("%*", "_")
			local name = name:gsub("%*", "_")
			if i == 1 and j == 1 then
				ssl.default = { cert = certs_dir .. name .. ".crt", key = certs_dir .. name .. ".key" }
			else
				if not ssl.hosts then
					ssl.hosts = {}
				end
				ssl.hosts[name] = { cert = certs_dir .. primary .. ".crt", key = certs_dir .. primary .. ".key" }
			end
		end
	end
	return ssl
end

local spawn_server = function(self, srv_cfg)
	local reliw_srv, err = new_server(srv_cfg)
	if err then
		return nil, err
	end
	local reliw_pid = std.ps.fork()
	if reliw_pid < 0 then
		self.logger:log({ msg = "server spawn failed", process = "manager" }, "error")
	end
	if reliw_pid == 0 then
		reliw_srv:serve()
	end
	self.logger:log({ msg = "server spawned", process = "manager", pid = reliw_pid })
	self.reliw_pid = reliw_pid
	return true
end

local spawn_acme_manager = function(self)
	local acme_manager, err = acme_manager.new(self.cfg, self.logger)
	if err then
		return nil, "failed to init ACME manager: " .. err
	end
	acme_pid = std.ps.fork()
	if acme_pid < 0 then
		self.logger:log({ msg = "ACME manager spawn failed", process = "manager" }, "error")
	end
	if acme_pid == 0 then
		acme_manager:manage()
	end
	self.logger:log({ msg = "ACME manager spawned", process = "manager", pid = acme_pid })
	self.acme_pid = acme_pid
	return true
end

local run = function(self)
	local cfg = self.cfg
	if cfg.ssl and cfg.ssl.acme then
		self:spawn_acme_manager()
	end
	if not cfg.ssl or not cfg.ssl.acme then
		self:spawn_server(cfg)
	end
	local pause = 60
	while not self.reliw_pid do
		local real_cfg = get_server_config()
		local ssl_config = ssl_config_from_acme(cfg)
		real_cfg.ssl = ssl_config
		local ok, err = self:spawn_server(real_cfg)
		if err then
			self.logger:log({
				process = "manager",
				msg = "RELIW failed to start, will try relaunch in " .. pause .. " seconds",
				err = err,
			}, "warn")
			std.sleep(pause)
			if pause < 300 then
				pause = pause + 60
			end
		end
	end
	self.store.red:cmd("SUBSCRIBE", cfg.redis_prefix .. ":CTL")
	while true do
		local resp, err = self.store.red:read()
		if resp and resp.value then
			local msg = resp.value[3]
			if msg == "RESTART" then
				-- TO DO:
				--
			end
		end
	end
end

local new = function()
	local cfg, err = get_server_config()
	if err then
		return nil, "failed to get reliw server config: " .. err
	end
	local store, err = store.new()
	if err then
		return nil, "failed to init store: " .. err
	end

	return {
		logger = std.logger.new(cfg.log_level),
		cfg = cfg,
		store = store,
		run = run,
		spawn_server = spawn_server,
		spawn_acme_manager = spawn_acme_manager,
	}
end

return { new = new }
