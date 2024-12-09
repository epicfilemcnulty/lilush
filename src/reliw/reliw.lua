local std = require("std")
local ws = require("web_server")
local json = require("cjson.safe")
local handle = require("reliw.handle")
local acme_manager = require("reliw.acme")
local store = require("reliw.store")

local default_reliw_config = {
	ip = "127.0.0.1",
	port = 8080,
	data_dir = "/www",
	cache_max_size = 5242880, -- 5 megabyte by default
	redis = {
		host = "127.0.0.1",
		port = 6379,
		db = 13,
		prefix = "RLW",
	},
	metrics = {
		ip = "127.0.0.1",
		port = 9101,
	},
}

local configure = function(srv_cfg)
	local cfg = std.tbl.copy(default_reliw_config)
	return std.tbl.merge(cfg, srv_cfg)
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
	return configure(config)
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

local spawn_metrics_server = function(self)
	local cfg = get_server_config()
	if not cfg.metrics then
		return nil, "metrics are disabled"
	end
	cfg.ip = cfg.metrics.ip
	cfg.port = cfg.metrics.port
	cfg.ssl = nil
	cfg.log_level = 100
	local metrics = require("reliw.metrics")
	local srv, err = ws.new(cfg, metrics.show)
	if err then
		return nil, err
	end
	local metrics_pid = std.ps.fork()
	if metrics_pid < 0 then
		self.logger:log({ msg = "metrics server spawn failed", process = "manager" }, "error")
	end
	if metrics_pid == 0 then
		srv:serve()
	end
	self.logger:log({ msg = "metrics server spawned", process = "manager", pid = metrics_pid })
	self.metrics_pid = metrics_pid
	return true
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
	if cfg.metrics then
		self:spawn_metrics_server()
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
	self.store.red:cmd("SUBSCRIBE", cfg.redis.prefix .. ":CTL")
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
	local store, err = store.new(cfg)
	if err then
		return nil, "failed to init store: " .. err
	end

	return {
		logger = std.logger.new(cfg.log_level),
		cfg = cfg,
		store = store,
		run = run,
		spawn_server = spawn_server,
		spawn_metrics_server = spawn_metrics_server,
		spawn_acme_manager = spawn_acme_manager,
	}
end

return { new = new }
