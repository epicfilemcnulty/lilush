-- SPDX-FileCopyrightText: © 2023 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: GPL-3.0-or-later

-- See https://platform.openai.com/docs/api-reference/introduction for details on the OpenAI API
local json = require("cjson.safe")
local web = require("web")
local std = require("std")

local pricing_per_1k_tokens = {
	["gpt-3.5-turbo"] = 0.002,
	["gpt-4"] = 0.06,
	["gpt-4-32k"] = 0.12,
	["mistral-small-latest"] = 0.006,
	["mistral-medium-latest"] = 0.0081,
	["mistral-large-lastest"] = 0.024,
}

local sanitize = function(messages)
	local sanitized = {}
	for i, v in ipairs(messages) do
		table.insert(sanitized, { role = v.role, content = v.content })
	end
	return sanitized
end

local request = function(url, json_data, api_key, backend, timeout)
	local headers = {
		["Authorization"] = "Bearer " .. api_key,
		["Content-Type"] = "application/json",
	}
	local start = os.time()
	local resp, err = web.request(url, { method = "POST", body = json_data, headers = headers }, timeout)
	if resp then
		if resp.status == 200 then
			local duration = os.time() - start
			local resp_json = json.decode(resp.body)
			local answer = {}
			if resp_json then
				answer.tokens = resp_json.usage.completion_tokens or 0
				answer.ctx = resp_json.usage.total_tokens or 0
				answer.model = resp_json.model
				answer.rate = answer.tokens / duration
				local cost = 0
				for mod, price in pairs(pricing_per_1k_tokens) do
					if answer.model:match("^" .. std.escape_magic_chars(mod)) then
						cost = price
						break
					end
				end
				answer.price = (answer.tokens / 1000) * cost
				if resp_json.choices[1].message then
					answer.text = resp_json.choices[1].message.content
				else
					answer.text = resp_json.choices[1].text
				end
				answer.text = answer.text:gsub("^\n+", "") -- remove leading newlines, for some reason OpenAI API prepends them to the response...
				answer.backend = backend
				return answer
			end
			return nil, "failed to decode response"
		end
		return nil, "bad response status: " .. resp.status .. "\n" .. resp.body
	end
	return nil, "request failed: " .. tostring(err)
end

local not_openai_or_mistral = function(backend)
	if backend == "OpenAI" or backend == "MistralAI" then
		return false
	end
	return true
end

local models = function(self)
	local headers = {
		["Authorization"] = "Bearer " .. self.api_key,
		["Content-Type"] = "application/json",
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
	local data = {
		model = model,
		max_tokens = sampler.tokens,
		messages = sanitize(messages),
		temperature = sampler.temperature,
		top_p = sampler.top_p,
		frequency_penalty = sampler.repetition_penalty,
	}
	if self.backend == "MistralAI" then
		data.frequency_penalty = nil
		data.top_k = nil
	end
	-- If it's not OpenAI or MistralAI, then it's probably able to handle top_k and min_p :-)
	if not self.backend:match("^%u") then
		data.min_p = sampler.min_p
		data.top_k = sampler.top_k
	end
	return request(self.api_url .. "/chat/completions", json.encode(data), self.api_key, self.backend, self.timeout)
end

local new = function(backend, api_key, api_url)
	local openai = {
		timeout = tonumber(os.getenv("OPENAI_API_TIMEOUT")) or tonumber(os.getenv("LLM_API_TIMEOUT")) or 600,
		api_key = api_key or os.getenv("OPENAI_API_KEY") or "n/a",
		api_url = api_url or os.getenv("OPENAI_API_URL") or "https://api.openai.com/v1",
		complete = complete,
		models = models,
		backend = backend,
	}
	return openai
end

return { new = new, pricing = pricing_per_1k_tokens }
