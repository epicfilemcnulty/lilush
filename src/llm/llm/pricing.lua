-- SPDX-FileCopyrightText: © 2024 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: GPL-3.0-or-later

--[[
LLM Pricing module.

Provides pricing data for various LLM models and cost calculation functions.
Prices are in USD per 1 million tokens.

Default prices are from OpenCode Zen (https://opencode.ai/docs/zen/).
Users can override/extend prices via configuration.
]]

-- Default prices per 1M tokens (from OpenCode Zen docs)
-- Format: { input = $, output = $, cached = $ (optional) }
local default_prices = {
	-- Anthropic models via Zen
	["claude-sonnet-4"] = { input = 3.00, output = 15.00, cached = 0.30 },
	["claude-sonnet-4-5"] = { input = 3.00, output = 15.00, cached = 0.30 },
	["claude-haiku-4-5"] = { input = 1.00, output = 5.00, cached = 0.10 },
	["claude-3-5-haiku"] = { input = 0.80, output = 4.00, cached = 0.08 },
	["claude-opus-4-5"] = { input = 5.00, output = 25.00, cached = 0.50 },
	["claude-opus-4-1"] = { input = 15.00, output = 75.00, cached = 1.50 },

	-- OpenAI models via Zen
	["gpt-5.2"] = { input = 1.75, output = 14.00, cached = 0.175 },
	["gpt-5.2-codex"] = { input = 1.75, output = 14.00, cached = 0.175 },
	["gpt-5.1"] = { input = 1.07, output = 8.50, cached = 0.107 },
	["gpt-5.1-codex"] = { input = 1.07, output = 8.50, cached = 0.107 },
	["gpt-5.1-codex-max"] = { input = 1.25, output = 10.00, cached = 0.125 },
	["gpt-5.1-codex-mini"] = { input = 0.25, output = 2.00, cached = 0.025 },
	["gpt-5"] = { input = 1.07, output = 8.50, cached = 0.107 },
	["gpt-5-codex"] = { input = 1.07, output = 8.50, cached = 0.107 },
	["gpt-5-nano"] = { input = 0, output = 0, cached = 0 }, -- Free

	-- Other models via Zen
	["minimax-m2.1"] = { input = 0.30, output = 1.20, cached = 0.10 },
	["minimax-m2.1-free"] = { input = 0, output = 0, cached = 0 }, -- Free
	["glm-4.7"] = { input = 0.60, output = 2.20, cached = 0.10 },
	["glm-4.7-free"] = { input = 0, output = 0, cached = 0 }, -- Free
	["glm-4.6"] = { input = 0.60, output = 2.20, cached = 0.10 },
	["kimi-k2.5"] = { input = 0.60, output = 3.00, cached = 0.08 },
	["kimi-k2.5-free"] = { input = 0, output = 0, cached = 0 }, -- Free
	["kimi-k2-thinking"] = { input = 0.40, output = 2.50 },
	["kimi-k2"] = { input = 0.40, output = 2.50 },
	["qwen3-coder"] = { input = 0.45, output = 1.50 },
	["big-pickle"] = { input = 0, output = 0, cached = 0 }, -- Free

	-- Native Anthropic models (direct API, not via Zen)
	["claude-sonnet-4-20250514"] = { input = 3.00, output = 15.00, cached = 0.30 },
	["claude-3-5-sonnet-20241022"] = { input = 3.00, output = 15.00, cached = 0.30 },
	["claude-3-5-haiku-20241022"] = { input = 0.80, output = 4.00, cached = 0.08 },
	["claude-3-opus-20240229"] = { input = 15.00, output = 75.00, cached = 1.50 },
}

-- Custom prices (set by user, merged on top of defaults)
local custom_prices = {}

-- Get price for a model
-- Returns { input, output, cached } or nil if model not found
local function get_price(model)
	if custom_prices[model] then
		return custom_prices[model]
	end
	return default_prices[model]
end

-- Calculate cost for a request
-- Returns cost in dollars, or nil if model has no pricing
local function calculate_cost(model, input_tokens, output_tokens, cached_tokens)
	local prices = get_price(model)
	if not prices then
		return nil
	end

	input_tokens = input_tokens or 0
	output_tokens = output_tokens or 0
	cached_tokens = cached_tokens or 0

	local cost = 0
	cost = cost + (input_tokens * (prices.input or 0)) / 1000000
	cost = cost + (output_tokens * (prices.output or 0)) / 1000000
	cost = cost + (cached_tokens * (prices.cached or 0)) / 1000000

	return cost
end

-- Set custom prices (merges with existing)
-- prices_table: { ["model-name"] = { input = $, output = $, cached = $ }, ... }
local function set_custom_prices(prices_table)
	for model, prices in pairs(prices_table or {}) do
		custom_prices[model] = prices
	end
end

-- Clear custom prices
local function clear_custom_prices()
	custom_prices = {}
end

-- Format cost for display
-- Returns string like "$0.00", "$0.12", "$1.23"
local function format_cost(cost)
	if not cost or cost < 0 then
		return "$0.00"
	end

	if cost < 0.01 then
		-- Show more precision for very small amounts
		if cost < 0.001 then
			return string.format("$%.4f", cost)
		end
		return string.format("$%.3f", cost)
	elseif cost < 10 then
		return string.format("$%.2f", cost)
	else
		return string.format("$%.2f", cost)
	end
end

-- List all known models with pricing
local function list_models()
	local models = {}
	for model, _ in pairs(default_prices) do
		table.insert(models, model)
	end
	for model, _ in pairs(custom_prices) do
		if not default_prices[model] then
			table.insert(models, model)
		end
	end
	table.sort(models)
	return models
end

-- Check if a model is free
local function is_free(model)
	local prices = get_price(model)
	if not prices then
		return false
	end
	return (prices.input or 0) == 0 and (prices.output or 0) == 0
end

return {
	get_price = get_price,
	calculate_cost = calculate_cost,
	set_custom_prices = set_custom_prices,
	clear_custom_prices = clear_custom_prices,
	format_cost = format_cost,
	list_models = list_models,
	is_free = is_free,
}
