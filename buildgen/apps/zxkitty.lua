return {
	binary = "zxkitty",
	luamods = {
		"std",
		"term",
		"luasocket",
		"crypto",
		"zx",
	},
	c_libs = {
		"cjson",
		"std",
		"crypto",
		"luasocket",
		"term",
		"zx",
	},
	start_code = {
		START_CODE = "zxkitty/start.lua",
	},
	custom_main = "zxkitty/main.c",
}
