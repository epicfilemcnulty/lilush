-- SPDX-FileCopyrightText: © 2022—2026 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: LicenseRef-OWL-1.0-or-later OR GPL-3.0-or-later
-- Dual-licensed under OWL v1.0+ and GPLv3+. See LICENSE and LICENSE-GPL3.

local ensure_order = function(client, primary_domain, order_url)
	if not client.__state.orders[primary_domain] then
		client.__state.orders[primary_domain] = {
			url = order_url,
			challenges = {},
		}
	elseif order_url then
		client.__state.orders[primary_domain].url = order_url
	end
	return client.__state.orders[primary_domain]
end

local set_order_info = function(client, primary_domain, order_url, order_info)
	local order_state = ensure_order(client, primary_domain, order_url)
	order_state.info = order_info
	client.store:save_order_info(primary_domain, order_info)
	return order_state
end

local set_challenge_url = function(client, primary_domain, domain, challenge_url)
	local order_state = ensure_order(client, primary_domain)
	order_state.challenges[domain] = challenge_url
end

local get_challenge_url = function(client, primary_domain, domain)
	local order_state = client.__state.orders[primary_domain]
	if not order_state then
		return nil
	end
	return order_state.challenges[domain]
end

local get_order_info = function(client, primary_domain)
	local order_state = client.__state.orders[primary_domain]
	if not order_state then
		return nil
	end
	return order_state.info
end

local get_order_url = function(client, primary_domain)
	local order_state = client.__state.orders[primary_domain]
	if not order_state then
		return nil
	end
	return order_state.url
end

local clear_order = function(client, primary_domain)
	client.__state.orders[primary_domain] = nil
end

return {
	ensure_order = ensure_order,
	set_order_info = set_order_info,
	set_challenge_url = set_challenge_url,
	get_challenge_url = get_challenge_url,
	get_order_info = get_order_info,
	get_order_url = get_order_url,
	clear_order = clear_order,
}
