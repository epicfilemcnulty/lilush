local start_code = [[
static const char START_CODE[] = "local reliw = require('reliw')\n"
                                 "local reliw_srv, err = reliw.new()\n"
                                 "if not reliw_srv then print('failed to init "
                                 "RELIW: ' .. tostring(err)) os.exit(-1) end\n"
                                 "reliw_srv:run()\n";
]]

return {
	binary = "reliw",
	luamods = {
		"luasocket",
		"std",
		"crypto",
		"djot",
		"redis",
		"reliw",
	},
	c_libs = {
		"cjson",
		"luasocket",
		"std",
		"crypto",
	},
	install_path = "/usr/local/bin/reliw",
	start_code = start_code,
}
