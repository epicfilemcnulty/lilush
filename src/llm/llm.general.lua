-- SPDX-FileCopyrightText: © 2023 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: GPL-3.0-or-later

--[[ 

    This is an API client for interacting with the general HTTP API of
    a language model. There are many backends for running inference on local LLaMA LLMs:
    vanilla HF transformers, CTranslate2, GPTQ, ExLLaMA, llamacpp, etc.
    
    The idea is that you build your own wrapper, which should provide the following
    HTTP API: 
    
        /prompt [PUT], expects body in JSON with the following fields:
            * prompt -- initial prompt, required
            * prefix -- prefix for the user queries, optional, defaults to 'USER:'
            * suffix -- suffix for the user queries, optional, defaults to 'ASSISTANT:'
            * uuid   -- Unique conversation ID, optional, will be generated if not provided.

            Resonse is JSON object with two fields, `message` and `uuid`.

        /chat [POST], expects body in JSON with the following fields:
            * temperature -- temperature for the query, optional, defaults to 0.7
            * max_length  -- max length of the response, optional, defaults to 2048
            * query       -- user's query
            * uuid        -- UUID of the conversation, required.

            Response is JSON object with the following fields:
                * uuid    -- UUID of the conversation
                * text    -- model's response
                * tokens  -- amount of tokens generated
                * rate    -- generation rate, tokens per second
                * model   -- model name or alias
                * ctx     -- amount of context tokens used so far in the conversation
                * type    -- model type, i.e. ggml, ct2, exllama

]]
--
local json = require("cjson.safe")
local web = require("web")

local models = function(self)
	local resp, err = web.request(self.api_url .. "/models")
	if resp then
		if resp.status == 200 then
			return json.decode(resp.body)
		end
		return nil, "bad response status: " .. resp.status .. "\n" .. resp.body
	end
	return nil, "request failed: " .. tostring(err)
end

local load_model = function(self, options)
	local data = {
		model_dir = options.model_dir,
		model_type = options.model_type,
		model_alias = options.model_alias,
		lora_dir = options.lora_dir,
		context_length = options.context.length,
	}
	local resp, err = web.request(
		self.api_url .. "/load",
		{ method = "POST", body = json.encode(data), headers = { ["Content-Type"] = "application/json" } },
		self.timeout
	)
	if resp then
		if resp.status == 200 then
			return json.decode(resp.body)
		end
		return nil, "bad response status: " .. resp.status .. "\n" .. resp.body
	end
	return nil, "request failed: " .. tostring(err)
end

local complete = function(self, model, query, sampler, sc, uuid)
	local data = {
		model = model,
		temperature = sampler.temperature,
		top_k = sampler.top_k,
		top_p = sampler.top_p,
		min_p = sampler.min_p,
		add_bos = sampler.add_bos,
		add_eos = sampler.add_eos,
		repetition_penalty = sampler.repetition_penalty,
		max_new_tokens = sampler.max_new_tokens,
		hide_special_tokens = sampler.hide_special_tokens,
		stop_conditions = sc,
		query = query,
		uuid = uuid,
	}
	local resp, err = web.request(
		self.api_url .. "/complete",
		{ method = "POST", body = json.encode(data), headers = { ["Content-Type"] = "application/json" } },
		self.timeout
	)
	if resp then
		if resp.status == 200 then
			return json.decode(resp.body)
		end
		return nil, "bad response status: " .. resp.status .. "\n" .. resp.body
	end
	return nil, "request failed: " .. tostring(err)
end

local new = function(api_url, timeout)
	local api_url = api_url or os.getenv("LLM_API_URL") or "http://127.0.0.1:8013"
	local timeout = timeout or tonumber(os.getenv("LLM_API_TIMEOUT")) or 600
	local client = {
		api_url = api_url,
		set_prompt = set_prompt,
		timeout = timeout,
		complete = complete,
		models = models,
		load_model = load_model,
	}
	return client
end

return { new = new }
