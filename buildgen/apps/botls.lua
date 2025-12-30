local start_code = [[
static const char START_CODE[] =  "local botls = require('botls')\n"
                                  "math.randomseed(os.time())\n"
                                  "local bot, err = botls.new()\n"
                                  "if not bot then print('failed to init "
                                  "BOTLS: ' .. tostring(err)) os.exit(-1) end\n"
                                  "bot:manage()\n";
]]

return {
	binary = "botls",
	luamods = {
		"luasocket",
		"std",
		"crypto",
		"acme",
		"botls",
	},
	c_libs = {
		"cjson",
		"luasocket",
		"std",
		"crypto",
	},
	install_path = "/usr/local/bin/botls",
	start_code = start_code,
}
