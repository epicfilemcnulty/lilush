#!/bin/lilush

local web = require("web")
local json = require("cjson.safe")
local std = require("deviant")

local repo = os.getenv("GITHUB_REPOSITORY")
local tag = os.getenv("GITHUB_REF_NAME")
local sha = os.getenv("GITHUB_SHA")
local assets_dir = os.getenv("CI_ASSETS_DIR")
local token = os.getenv("CI_TOKEN")

local base_url = "https://git.deviant.guru/api/v1/repos/" .. repo

local body = { draft = false, prerelease = true, tag_name = tag, target_commitish = sha, name = tag, body = "" }
local headers = {
	["accept"] = "application/json",
	["authorization"] = "token " .. token,
	["content-type"] = "application/json",
}

local res, err = web.request(base_url .. "/releases", { method = "POST", headers = headers, body = json.encode(body) })
if res and res.status < 300 then
	local resp = json.decode(res.body)
	local release_id = resp.id

	local header, content = web.make_form_data({ { name = "attachment", path = assets_dir .. "/lilush" } })
	headers["content-type"] = header

	res, err = web.request(
		base_url .. "/releases/" .. release_id .. "/assets?name=lilush",
		{ method = "POST", headers = headers, body = content }
	)
	if res and res.status < 300 then
		print("All done")
		os.exit(0)
	end
end

print("Something went wrong")
std.print(res)
std.print(err)
os.exit(-1)
