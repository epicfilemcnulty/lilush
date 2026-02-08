return {
	binary = "botls",
	luamods = {
		"luasocket",
		"web",
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
	start_code = {
		START_CODE = "botls/start.lua",
	},
}
