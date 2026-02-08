return {
	binary = "reliw",
	luamods = {
		"luasocket",
		"web",
		"std",
		"crypto",
		"markdown",
		"redis",
		"reliw",
	},
	c_libs = {
		"cjson",
		"luasocket",
		"std",
		"crypto",
	},
	start_code = {
		START_CODE = "reliw/start.lua",
	},
}
