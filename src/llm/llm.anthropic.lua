-- SPDX-FileCopyrightText: © 2023 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: GPL-3.0-or-later

-- API docs:
-- https://docs.anthropic.com/claude/reference/
-- https://docs.mistral.ai/api/
-- https://platform.openai.com/docs/api-reference/chat

local json = require("cjson.safe")
local web = require("web")
local std = require("std")

local pricing_per_1k_tokens = {
	["claude-3-opus-20240229"] = { input = 0.015, output = 0.075 },
	["claude-3-5-sonnet-20240620"] = { input = 0.003, output = 0.015 },
	["claude-3-5-sonnet-20241022"] = { input = 0.003, output = 0.015 },
	["claude-3-haiku-20240307"] = { input = 0.00025, output = 0.00125 },
}

local sanitize = function(messages)
	local sanitized = {}
	for i, v in ipairs(messages) do
		table.insert(sanitized, { role = v.role, content = v.content })
	end
	return sanitized
end

local request = function(url, json_data, api_key, timeout, backend)
	local headers = {
		["x-api-key"] = api_key,
		["Content-Type"] = "application/json",
		["anthropic-version"] = "2023-06-01",
	}
	local start = os.time()
	local resp, err = web.request(url, { method = "POST", body = json_data, headers = headers }, timeout)
	if resp then
		if resp.status == 200 then
			local duration = os.time() - start
			local resp_json = json.decode(resp.body)
			local answer = {}
			if resp_json then
				answer.tokens = resp_json.usage.completion_tokens
				if not answer.tokens then
					answer.tokens = resp_json.usage.output_tokens or 0
				end
				answer.ctx = resp_json.usage.total_tokens
				if not answer.ctx then
					answer.ctx = resp_json.usage.input_tokens + answer.tokens
				end
				answer.model = resp_json.model
				answer.rate = answer.tokens / duration
				local input_cost = 0
				local output_cost = 0
				for mod, price in pairs(pricing_per_1k_tokens) do
					if answer.model:match("^" .. std.escape_magic_chars(mod)) then
						input_cost = price.input
						output_cost = price.output
						break
					end
				end
				local prompt_tokens = answer.ctx - answer.tokens
				answer.price = (answer.tokens / 1000) * output_cost + (prompt_tokens / 1000) * input_cost
				if resp_json.choices then
					if resp_json.choices[1].message then
						answer.text = resp_json.choices[1].message.content
					else
						answer.text = resp_json.choices[1].text
					end
				elseif resp_json.content then
					answer.text = resp_json.content[1].text
				end
				answer.text = answer.text:gsub("^\n+", "") -- remove any leading newlines
				answer.backend = backend
				return answer
			end
			return nil, "failed to decode response"
		end
		return nil, "bad response status: " .. resp.status .. "\n" .. resp.body
	end
	return nil, "request failed: " .. tostring(err)
end

local models = function(self)
	local headers = {
		["x-api-key"] = self.api_key,
		["Content-Type"] = "application/json",
		["anthropic-version"] = "2023-06-01",
	}
	local res, err = web.request(self.api_url .. "/models", { method = "GET", headers = headers })
	if res and res.status == 200 then
		local res_json, err = json.decode(res.body)
		if res_json then
			local models = {}
			for i, model in ipairs(res_json.data) do
				table.insert(models, model.id)
			end
			return models
		end
		return nil, "failed to decode response JSON: " .. tostring(err)
	end
	return nil, "request failed: " .. tostring(err)
end

--[[ 
    messages shold be a table of the following format:
    { 
        { role = "system", content = "You are a helpful chatGPT chat assistant, humorous and a little whimsical." },
        { role = "user", content = "What's up bro?" },
        { role = "assistant", content = "Not much, you?" },
        { role = "user", content = "Fine. What time is it on the moon now?" },
    }
]]
local complete = function(self, model, messages, sampler)
	local sys_prompt = ""
	if messages[1].role == "system" then
		sys_prompt = messages[1].content
		table.remove(messages, 1)
	end
	local data = {
		model = model,
		max_tokens = sampler.max_new_tokens,
		messages = sanitize(messages),
		temperature = sampler.temperature,
		top_p = sampler.top_p,
		top_k = sampler.top_k,
	}
	if sys_prompt ~= "" then
		data.system = sys_prompt
	end
	return request(self.api_url .. "/messages", json.encode(data), self.api_key, self.timeout, self.backend)
end

local new = function(api_url)
	local api_url = api_url
	if not api_url then
		api_url = os.getenv("ANTHROPIC_API_URL") or "https://api.anthropic.com/v1"
	end
	local api_key = os.getenv("ANTHROPIC_API_KEY") or "n/a"
	local timeout = tonumber(os.getenv("ANTHROPIC_API_TIMEOUT")) or tonumber(os.getenv("LLM_API_TIMEOUT")) or 600
	local client = {
		backend = "AnthropicAI",
		timeout = timeout,
		api_key = api_key,
		api_url = api_url,
		complete = complete,
		models = models,
	}
	return client
end

return { new = new, pricing = pricing_per_1k_tokens }
