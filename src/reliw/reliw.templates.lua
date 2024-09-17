local std = require("std")
local djot = require("djot")

local template = {
	head = [[
<!DOCTYPE html><html>
<head>
    <title>{{title}}</title>
    <meta charset="utf-8"/>
    <link rel="stylesheet" href="{{css_file}}" type="text/css" />
	<link rel="icon" href="{{favicon_file}}" />
</head>
]],
	body = [[
<body>
<header>
    <section class="{{class}}" id="title">{{title}}</section>
</header>
]],
	footer = "</body></html>",
	error_section = [[
<section id="error">
    <h3>{{error_code}}</h3>
    <p class="error">{{error_message}}</p>
    <h3>{{error_code}}</h3>
</section>
<section id="home">Take me <a href="/">home</a>, country roads...</section>
]],
	error_404_footer = [[<footer><p class="error">You are amongst the <span>{{hit_count}}</span> digital nomads who have sought for this page. None have found it, but the hope lives on.</p></footer>]],
	errors = {
		[401] = { title = "Unauthorized", msg = "Authorized personnel only." },
		[403] = { title = "Forbidden", msg = "You are too ugly to get in." },
		[404] = {
			title = "Page Not Found",
			msg = {
				"You must be coming from AltaVista, right?",
				"Elvis has left the building, baby.",
				"The train has long been gone.",
				"Oh, this overwhelming sense of loss...",
				"I think I saw that page somewhere...Might be over the sofa...",
				"Oops. No page found. That's sad.",
			},
		},
		[405] = { title = "Method Not Allowed", msg = { "Hey! Looky, no touchy.", "This ain't a Post Office, mate." } },
		[429] = { title = "Too Many Requests", msg = "Slow down, speedy rider. It might get bumpy along the way." },
		[503] = { title = "Service Unavailable", msg = "Sad days." },
		[501] = { title = "Not Implemented", msg = "You can't implement everything, can you?" },
		[500] = { title = "Internal Server Error", msg = "It's always something in the childhood..." },
	},
}

local error_page = function(code, hit_count, user_tmpl)
	local user_tmpl = user_tmpl or {}
	local vars = {
		title = "Uknown error",
		css_file = "/css/default.css",
		favicon_file = "/images/error/favicon.svg",
		hit_count = hit_count or 0,
		error_message = "Never seen such a thing in my life!",
		error_code = code,
		class = "error",
	}
	local tmpl = std.tbl.copy(template)
	tmpl = std.tbl.merge(tmpl, user_tmpl)

	if tmpl.errors[code] then
		local msg
		if type(tmpl.errors[code].msg) == "table" then
			math.randomseed(os.time())
			msg = tmpl.errors[code].msg[math.random(1, #tmpl.errors[code].msg)]
		else
			msg = tmpl.errors[code].msg
		end
		vars.title = tmpl.errors[code].title
		vars.error_message = msg
	end
	if code == 404 then
		return std.txt.template(
			tmpl.head .. tmpl.body .. tmpl.error_section .. tmpl.error_404_footer .. tmpl.footer,
			vars
		)
	end
	return std.txt.template(tmpl.head .. tmpl.body .. tmpl.error_section .. tmpl.footer, vars)
end

local djot_to_html = function(djot_content)
	local doc = djot.parse(djot_content)
	local html = djot.render_html(doc)
	return html
end

local render_page = function(content, vars, user_tmpl)
	local vars = vars or {}
	local user_tmpl = user_tmpl or {}
	local tmpl = std.tbl.copy(template)
	tmpl = std.tbl.merge(tmpl, user_tmpl)

	local page_header = tmpl.head .. tmpl.body
	if not vars.css_file then
		page_header = page_header:gsub('%s+<link rel="stylesheet".+/>', "")
	end
	if not vars.favicon_file then
		page_header = page_header:gsub('%s+<link rel="icon" .+/>', "")
	end
	return std.txt.template(page_header, vars) .. content .. std.txt.template(tmpl.footer, vars)
end

local _M = { error_page = error_page, djot_to_html = djot_to_html, render_page = render_page }

return _M
