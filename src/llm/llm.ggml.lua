-- SPDX-FileCopyrightText: © 2023 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: GPL-3.0-or-later
local json = require("cjson.safe")
local web = require("web")

local models = function(self)
	local res, err = web.request(self.api_url .. "/v1/models")
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

local complete = function(self, model, query, sampler, sc, uuid)
	local sc = sc or {}
	local body = {
		n_predict = sampler.max_new_tokens,
		temperature = sampler.temperature,
		min_p = sampler.min_p,
		top_k = sampler.top_k,
		top_p = sampler.top_p,
		threads = self.threads,
		prompt = query,
		stop = sc,
	}
	local resp, err = web.request(
		self.api_url .. "/completion",
		{ method = "POST", body = json.encode(body), headers = { ["Content-Type"] = "application/json" } },
		self.timeout
	)
	if resp then
		if resp.status == 200 then
			local body, err = json.decode(resp.body)
			if body then
				local answer = {}
				answer.text = body.content
				answer.tokens = body.tokens_predicted
				answer.ctx = body.tokens_cached
				answer.price = 0
				answer.rate = body.timings.predicted_per_second
				answer.model = body.model or "unknown"
				return answer
			end
			return nil, err
		end
		return nil, "bad response status: " .. resp.status .. "\n" .. resp.body
	end
	return nil, "request failed: " .. tostring(err)
end

local new = function(api_url, threads)
	local ggml = {
		threads = threads or tonumber(os.getenv("LLM_GGML_THREADS")) or 8,
		api_url = api_url or os.getenv("LLM_GGML_API_URL") or "http://127.0.0.1:8080",
		timeout = tonumber(os.getenv("LLM_API_TIMEOUT")) or 600, -- seconds
		complete = complete,
		models = models,
	}
	return ggml
end

return { new = new }
