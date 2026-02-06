local std = require("std")
local ws = require("web_server")
local json = require("cjson.safe")
local handle = require("reliw.handle")
local storage = require("reliw.store")

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

local track_child_pid = function(self, pid, name)
	if not pid or pid <= 0 then
		return
	end
	if not self.child_pids then
		self.child_pids = {}
	end
	self.child_pids[pid] = name or "child"
end

local untrack_child_pid = function(self, pid)
	if not self.child_pids or not pid or pid <= 0 then
		return false
	end
	if not self.child_pids[pid] then
		return false
	end
	self.child_pids[pid] = nil
	return true
end

local drain_exited_children = function(self)
	while true do
		local pid = std.ps.waitpid(-1)
		if not pid or pid <= 0 then
			break
		end
		untrack_child_pid(self, pid)
	end
end

local wait_for_primary_exit = function(self)
	if not self.reliw_pid then
		return
	end
	local primary_pid = self.reliw_pid
	while true do
		local pid = std.ps.wait(-1)
		if not pid or pid <= 0 then
			break
		end
		local is_primary = pid == primary_pid
		untrack_child_pid(self, pid)
		if is_primary then
			break
		end
	end
	drain_exited_children(self)
end

local spawn_metrics_server = function(self)
	local cfg, err = get_server_config()
	if not cfg then
		return nil, err
	end
	if not cfg.metrics or cfg.metrics.disabled then
		return nil, "metrics are disabled"
	end
	cfg.ip = cfg.metrics.ip
	cfg.port = cfg.metrics.port
	cfg.process = "metrics"
	cfg.ssl = nil
	cfg.log_level = 100
	local metrics = require("reliw.metrics")
	local srv, err = ws.new(cfg, metrics.show)
	if not srv then
		return nil, err
	end
	local metrics_pid = std.ps.fork()
	if metrics_pid < 0 then
		self.logger:log({ msg = "metrics server spawn failed", process = "manager" }, "error")
		return nil
	end
	if metrics_pid == 0 then
		srv:serve()
	end
	self.logger:log({ msg = "metrics server spawned", process = "manager", pid = metrics_pid })
	self.metrics_pid = metrics_pid
	track_child_pid(self, metrics_pid, "metrics")
	return true
end

local spawn_server = function(self, srv_cfg)
	srv_cfg.process = "server_ipv4"
	local reliw_srv, err = new_server(srv_cfg)
	if not reliw_srv then
		return nil, err
	end
	local reliw_pid = std.ps.fork()
	if reliw_pid < 0 then
		self.logger:log({ msg = "IPv4 server spawn failed", process = "manager" }, "error")
		return nil
	end
	if reliw_pid == 0 then
		reliw_srv:serve()
	end
	self.logger:log({ msg = "IPv4 server spawned", process = "manager", pid = reliw_pid })
	self.reliw_pid = reliw_pid
	track_child_pid(self, reliw_pid, "server_ipv4")

	if not srv_cfg.ipv6 then
		return true
	end

	local srv_cfg_ipv6 = std.tbl.copy(srv_cfg)
	srv_cfg_ipv6.ip = srv_cfg_ipv6.ipv6
	srv_cfg_ipv6.process = "server_ipv6"
	local reliw6_srv, err = new_server(srv_cfg_ipv6)
	if not reliw6_srv then
		return nil, err
	end
	local reliw6_pid = std.ps.fork()
	if reliw6_pid < 0 then
		self.logger:log({ msg = "IPv6 server spawn failed", process = "manager" }, "error")
		return nil
	end
	if reliw6_pid == 0 then
		reliw6_srv:serve()
	end
	self.logger:log({ msg = "IPv6 server spawned", process = "manager", pid = reliw6_pid })
	self.reliw6_pid = reliw6_pid
	track_child_pid(self, reliw6_pid, "server_ipv6")
	return true
end

local run = function(self)
	local cfg = self.cfg
	if cfg.metrics then
		self:spawn_metrics_server()
	end
	if not self:spawn_server(cfg) then
		os.exit(1)
	end
	wait_for_primary_exit(self)
end

local new = function()
	local cfg, err = get_server_config()
	if not cfg then
		return nil, "failed to get reliw server config: " .. err
	end
	local store, err = storage.new(cfg)
	if not store then
		return nil, "failed to init store: " .. err
	end

	return {
		logger = std.logger.new(cfg.log_level),
		cfg = cfg,
		store = store,
		child_pids = {},
		run = run,
		spawn_server = spawn_server,
		spawn_metrics_server = spawn_metrics_server,
	}
end

return { new = new }
