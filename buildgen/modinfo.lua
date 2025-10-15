local luamods = {
	luasocket = {
		{ "socket", "mod_lua_socket" },
		{ "socket.headers", "mod_lua_headers" },
		{ "socket.http", "mod_lua_http" },
		{ "socket.url", "mod_lua_url" },
		{ "ssl", "mod_lua_ssl" },
		{ "ssl.https", "mod_lua_https" },
		{ "web", "mod_lua_web" },
		{ "web_server", "mod_lua_web_server" },
		{ "ltn12", "mod_lua_ltn12" },
		{ "mime", "mod_lua_mime" },
	},
	std = { "std", "std.fs", "std.ps", "std.txt", "std.tbl", "std.conv", "std.mime", "std.logger", "std.utf" },
	acme = { "acme", "acme.dns.vultr", "acme.http.reliw", "acme.store.file" },
	argparser = { "argparser" },
	crypto = { "crypto" },
	term = {
		"term",
		"term.widgets",
		"term.tss",
		"term.gfx",
		"term.input",
		"term.input.history",
		"term.input.prompt",
		"term.input.completion",
	},
	text = { "text" },
	dns = { "dns.resolver", "dns.parser", "dns.dig" },
	djot = { "djot", "djot.ast", "djot.attributes", "djot.block", "djot.filter", "djot.html", "djot.inline" },
	redis = { "redis" },
	reliw = {
		"reliw",
		"reliw.api",
		"reliw.auth",
		"reliw.handle",
		"reliw.metrics",
		"reliw.store",
		"reliw.proxy",
		"reliw.templates",
	},
	botls = { "botls" },
	shell = {
		"shell",
		"shell.theme",
		"shell.store",
		"shell.utils",
		"shell.builtins",
		"shell.mode.shell",
		"shell.mode.shell.prompt",
		"shell.completion.shell",
		"shell.completion.source.bin",
		"shell.completion.source.builtins",
		"shell.completion.source.cmds",
		"shell.completion.source.env",
		"shell.completion.source.fs",
	},
	vault = { "vault" },
}

local c_libs = {
	luasocket = {
		{ "socket.core", "luaopen_socket_core" },
		{ "socket.unix", "luaopen_socket_unix" },
		{ "socket.serial", "luaopen_socket_serial" },
		{ "mime.core", "luaopen_mime_core" },
		{ "ssl.context", "luaopen_ssl_context" },
		{ "ssl.core", "luaopen_ssl_core" },
	},
	cjson = {
		{ "cjson", "luaopen_cjson" },
		{ "cjson.safe", "luaopen_cjson_safe" },
	},
	std = {
		{ "std.core", "luaopen_deviant_core" },
	},
	crypto = {
		{ "crypto.core", "luaopen_crypto_core" },
	},
	term = {
		{ "term.core", "luaopen_term_core" },
	},
	wireguard = {
		{ "wireguard", "luaopen_wireguard" },
	},
}

return { c_libs = c_libs, luamods = luamods }
