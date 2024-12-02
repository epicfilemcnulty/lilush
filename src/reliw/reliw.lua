local std = require("std")
local ws = require("web_server")
local json = require("cjson.safe")
local handle = require("reliw.handle")

local configure = function(server_config)
	std.ps.setenv("RELIW_DATA_DIR", server_config.data_dir or "/www")
	std.ps.setenv("RELIW_REDIS_PREFIX", server_config.redis_prefix or "RLW")
	std.ps.setenv("RELIW_REDIS_URL", server_config.redis_url or "127.0.0.1:6379/13")
	std.ps.setenv("RELIW_CACHE_MAX", server_config.cache_max or 5242880)
end

local new = function()
	local config_file = os.getenv("RELIW_CONFIG_FILE") or "/etc/reliw/config.json"
	if not std.fs.file_exists(config_file) then
		return nil, "no config file found"
	end
	local config = json.decode(std.fs.read_file(config_file))
	if not config then
		return nil, "failed to read/decode config file"
	end
	local srv = ws.new(config, handle.func)
	configure(srv.__config)
	return srv
end

return { new = new }
