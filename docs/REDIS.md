# Redis Client Contract

This document defines the public contract for `src/redis/redis.lua`.

## Connection config

`redis.connect` accepts either:

1. String form: `"<host>:<port>"` or `"<host>:<port>/<db>"`
2. Table form:

```lua
{
	host = "127.0.0.1", -- required
	port = 6379, -- optional, defaults to 6379
	db = 13, -- optional
	timeout = 2, -- optional socket timeout
	ssl = true, -- optional TLS mode
	auth = { user = "u", pass = "p" }, -- optional AUTH
	-- extra fields are ignored by redis client callers may keep module-specific metadata here
}
```

Validation rules:

- `host` must be a non-empty string.
- `port` must be an integer in range `1..65535`.
- `db` when set must be a non-negative integer.
- `timeout` when set must be a positive number.
- `auth` when set must be a table with non-empty string fields `user` and `pass`.
- Unknown/extra table fields are ignored by the Redis client.

Invalid configs return `nil, err` with a clear validation error message.

## Client object API

Connection object contract used by callers:

- `client:cmd(...)` executes a Redis command and returns decoded RESP payload
- `client:read()` reads one raw RESP value (`{ type = "...", value = ... }`)
- `client:close(no_keepalive)` closes or returns socket to internal keepalive pool
