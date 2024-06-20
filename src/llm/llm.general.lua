-- SPDX-FileCopyrightText: © 2023-2024 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: GPL-3.0-or-later

--[[ 

    This is a client library for interacting with a simple HTTP API for LLM inference.

    The API service itself generally should be implemented and provisioned by the user,
    but there is a [reference](add link here) implementation of such a service.

    There are many backends for running inference on LLMs: vanilla HF transformers, CTranslate2, ExLLaMA, llamacpp, etc.
    The idea is that you build your own wrapper for the backends you need, and this wrapper should
    conform to the following API:

    HTTP API:

        /models [GET]
            Response is a JSON array with the names of currently loaded models.

        /load [POST], expects a JSON object in the response body with the following fields:

            * model_dir
            * model_type
            * model_alias
            * lora_dir
            * context_length

        /complete [POST], expects body in JSON with the following fields:

            * model                 -- model name to query
            * temperature           -- temperature for the query
            * top_k                 -- top_k
            * top_p                 -- top_p
            * min_p                 -- min_p
            * max_new_tokens        -- the maximum number of new tokens to generate
            * query                 -- user's query
            * uuid                  -- UUID of the conversation, optional.
            * add_bos               -- whether to prepend the query with the special BOS token
            * add_eos               -- whether to append the special EOS token to the query
            * repetition_penalty    -- duh,
            * hide_special_tokens   -- whether to remove special tokens from the response
            * stop_conditions       -- an array of tokens which serve as stop conditions, i.e. we end
                                       generation when we get one of these tokens

            This endpoint must respond with a JSON object with the following fields:
                * uuid    -- UUID of the conversation
                * text    -- model's response
                * tokens  -- amount of tokens generated
                * rate    -- generation rate, tokens per second
                * model   -- model name or alias
                * ctx     -- amount of context tokens used so far in the conversation
                * type    -- model type, i.e. ggml, ct2, exllama

]]
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
		context_length = options.context_length,
		cache_size = options.cache_size,
		dynamic = options.dynamic,
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

local unload_model = function(self, model_alias)
	local resp, err = web.request(self.api_url .. "/unload", {
		method = "DELETE",
		body = json.encode({ model_alias = model_alias }),
		headers = { ["Content-Type"] = "application/json" },
	}, self.timeout)
	if resp then
		if resp.status == 200 then
			return true
		end
		return "failed to unload the model: " .. resp.status .. "\n" .. resp.body
	end
	return nil, "failed to unload the model: " .. tostring(err)
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
		query = query,
		uuid = uuid,
	}
	if sc and #sc > 0 then
		data.stop_conditions = sc
	end
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
		timeout = timeout,
		complete = complete,
		models = models,
		load_model = load_model,
		unload_model = unload_model,
	}
	return client
end

return { new = new }
