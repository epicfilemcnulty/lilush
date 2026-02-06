# RELIW Operations and Development Guide

This guide documents the current RELIW behavior implemented in:

- `src/reliw/reliw.lua`
- `src/reliw/reliw/*.lua`
- `src/luasocket/web_server.lua`

It is intended for both operators (deployment and troubleshooting) and developers (schema, routing, and failure semantics).

## 1. Quick Start

### 1.1 Runtime entry point

The standalone RELIW app entry point is defined in `buildgen/apps/reliw.lua` and runs:

```lua
local reliw = require("reliw")
math.randomseed(os.time())
local reliw_srv, err = reliw.new()
if not reliw_srv then
	print("failed to init RELIW: " .. tostring(err))
	os.exit(-1)
end
reliw_srv:run()
```

### 1.2 Config file location

RELIW reads config JSON from:

1. `RELIW_CONFIG_FILE` environment variable, if set
2. `/etc/reliw/config.json` otherwise

### 1.3 Minimal HTTP config

```json
{
  "ip": "127.0.0.1",
  "port": 8080
}
```

### 1.4 Minimal Redis data for one host

Example below serves `/` for `example.com` from `data_dir/example.com/index.md`.

```bash
redis-cli -n 13 SET RLW:API:example.com '[["/","home",true]]'
redis-cli -n 13 SET RLW:API:example.com:home '{"methods":{"GET":true,"HEAD":true},"index":"index.md"}'
```

Create content file:

```bash
mkdir -p /www/example.com
printf '# Hello\n' > /www/example.com/index.md
```

Request:

```bash
curl -H 'Host: example.com' http://127.0.0.1:8080/
```

## 2. Full Configuration Reference

RELIW combines defaults from `src/reliw/reliw.lua` and `src/luasocket/web_server.lua`.

### 2.1 Top-level server config

| Key | Default | Notes |
|---|---|---|
| `ip` | `127.0.0.1` | IPv4 bind address |
| `port` | `8080` | Bind port |
| `ipv6` | unset | If set, manager spawns IPv6 server process |
| `data_dir` | `/www` | Static/dynamic content root |
| `cache_max_size` | `5242880` | Max bytes for cached file content in Redis |
| `backlog` | `256` | Listen backlog |
| `fork_limit` | `64` | Max concurrent request worker children per listener process |
| `requests_per_fork` | `512` | Requests handled by one request worker before close |
| `max_body_size` | `5242880` | Request body cap for content-length and chunked uploads |
| `request_line_limit` | `8192` | Max request line or header line bytes |
| `keepalive_idle_timeout` | `15` | Keep-alive idle timeout (seconds) |
| `request_header_timeout` | `10` | Header read timeout (seconds) |
| `request_body_timeout` | `30` | Body read timeout (seconds) |
| `tls_handshake_timeout` | `10` | Server-side TLS handshake timeout (seconds) |
| `log_level` | `access` | Logger level passed to `std.logger` |
| `log_headers` | `["referer","x-real-ip","user-agent"]` | Request headers copied into access logs |
| `compression` | enabled | Compression policy object (currently parsed but response compression is not active yet) |
| `redis` | object | Redis connection and namespace config |
| `metrics` | object | Metrics listener + SCAN tuning |
| `ssl` | unset | Enable HTTPS listener (see TLS section) |

Compression defaults:

- `compression.enabled = true`
- `compression.min_size = 4096`
- `compression.types` includes `text/html`, `text/plain`, `text/css`, `text/javascript`, `image/svg+xml`, `application/json`, `application/rss+xml`
- Current runtime status: no deflate/gzip output is emitted yet; the compression block is a placeholder in `web_server.lua` pending implementation.

### 2.2 Redis config (`redis`)

| Key | Default | Notes |
|---|---|---|
| `host` | `127.0.0.1` | Redis host |
| `port` | `6379` | Redis port |
| `db` | `13` | Selected DB |
| `prefix` | `RLW` | Key namespace prefix |
| `timeout` | unset | Optional socket timeout |
| `ssl` | unset | Optional Redis TLS mode |
| `auth` | unset | Optional auth object for Redis `AUTH` |

### 2.3 Metrics config (`metrics`)

| Key | Default | Notes |
|---|---|---|
| `ip` | `127.0.0.1` | Metrics listener bind IP |
| `port` | `9101` | Metrics listener bind port |
| `disabled` | false | If true, metrics process is not spawned |
| `scan_count` | `100` | Redis SCAN count hint; clamped to `1..1000` |
| `scan_limit` | `2000` | Max keys inspected per scrape; clamped to `1..10000` |

Metrics process behavior:

- spawned by manager as a dedicated process
- uses `reliw.metrics.show`
- forces `ssl = nil` and `log_level = 100`

### 2.4 TLS config (`ssl`)

Server-side TLS config shape:

```json
{
  "ssl": {
    "default": { "cert": "/path/default.crt", "key": "/path/default.key" },
    "hosts": {
      "example.org": { "cert": "/path/example.org.crt", "key": "/path/example.org.key" }
    }
  }
}
```

Notes:

- `ssl.default` is required when TLS is enabled.
- `ssl.hosts` adds SNI contexts for additional hostnames.
- RELIW validates that configured cert/key files exist before startup.

## 3. Redis Data Model

All keys are prefixed with `redis.prefix` (default `RLW`).

### 3.1 Routing and entry metadata

- `${PREFIX}:API:<host>`
  - JSON array of route entries: `[pattern, entry_id, exact_match?]`
  - `exact_match` (`true`) means strict equality; otherwise `query:match(pattern)` is used
- `${PREFIX}:API:<host>:<entry_id>`
  - JSON object containing entry metadata

Common metadata fields:

- Required:
  - `methods` map, for example `{ "GET": true, "POST": true }`
- Optional:
  - `file`: explicit file path
  - `index`: appended when query ends with `/`
  - `try_extensions`: try `.lua`, `.dj`, `.md` if file is missing
  - `gsub`: `{ "pattern": "...", "replacement": "..." }` query remap
  - `title`, `css_file`, `favicon_file`
  - `cache_control` (for example `max-age=3600`)
  - `auth`: see auth section
  - `rate_limit`: see rate-limiting section
  - `error`: status-specific image/html override map

### 3.2 Content and templates

- `${PREFIX}:FILES:<host>:<filename>` (hash)
  - fields: `content`, `hash`, `size`, `mime`, `title`
  - cache TTL: 3600 seconds
- `${PREFIX}:TITLES:<host>` (hash)
  - optional per-file title override
- `${PREFIX}:DATA:<host>:<name>` (string)
  - user data; fallback key: `${PREFIX}:DATA:__:<name>`
  - `template.lua` is used as page template override if present

### 3.3 Auth/session keys

- `${PREFIX}:USERS:<host>` (hash)
  - field: username
  - value: JSON `{ "pass": "<hex_hmac>", "salt": "<salt>" }`
- `${PREFIX}:SESSIONS:<host>:<token>` (string with TTL)
  - value: username

### 3.4 Proxy metadata schema

- `${PREFIX}:PROXY:<host>` (JSON object)
  - `target` (required): upstream host
  - `scheme` (optional): `http` (default) or `https`
  - `port` (optional): defaults to `80`/`443` by scheme
  - `tls_cafile`, `tls_capath`, `tls_handshake_timeout` (optional)
  - `tls_insecure`, `tls_no_verify`, `no_verify_mode` (optional bools; any true enables no-verify mode)

### 3.5 WAF and control channels

- `${PREFIX}:WAF` (hash)
  - field `__`: global rule set JSON
  - field `<host>`: per-host rule set JSON
- `${PREFIX}:WAFFERS` (Pub/Sub channel)
  - receives blocked IP value from WAF branch
- `${PREFIX}:CTL` (Pub/Sub channel)
  - generic control messages from `store:send_ctl_msg`

### 3.6 Metrics and rate-limit keys

- `${PREFIX}:METRICS:<host>:total` (hash: status_code -> count)
- `${PREFIX}:METRICS:<host>:by_method` (hash: method -> count)
- `${PREFIX}:METRICS:<host>:by_request` (hash: query -> count; internal)
- `${PREFIX}:LIMITS:<host>:<method>:<query>:<ip>` (string counter with TTL)

## 4. WAF Behavior

Rule document format (global or per-host):

```json
{
  "ip_header": "x-forwarded-for",
  "query": ["^/admin", "drop%stable"],
  "headers": {
    "user-agent": ["badbot", "sqlmap"],
    "x-custom": ["evil"]
  }
}
```

Semantics:

- Matching uses Lua pattern matching (`string.match`), not PCRE.
- Evaluation order:
  1. global query rules
  2. global header rules
  3. per-host query rules
  4. per-host header rules
- Default blocked-IP header source is `x-forwarded-for` if `ip_header` is missing.
- On match:
  - publishes IP to `${PREFIX}:WAFFERS`
  - logs blocked event with rule and host
  - returns `301` to `http://127.0.0.1/Fuck_Off`

## 5. Request Handling Semantics

Main handler: `src/reliw/reliw/handle.lua`.

Order of operations:

1. Initialize Redis-backed store for request.
2. Normalize/validate host and query.
3. Evaluate WAF.
4. Check host-level proxy config.
5. Resolve route metadata.
6. Apply auth, method checks, and rate limits.
7. Load/render content.
8. Apply ETag/cache semantics and update metrics.

Client IP normalization at request ingress:

- `x-client-ip` is always set from socket peer IP.
- `x-real-ip` is only auto-filled from peer IP when request does not provide it.
- Downstream RELIW logic prefers `x-client-ip`.

### 5.1 Host and query hardening

Host validation:

- accepts DNS name, `localhost`, IPv4, bracketed IPv6
- rejects malformed ports, comma-separated host lists, control chars, unbracketed IPv6

Query validation:

- requires leading `/`
- rejects control chars and backslashes
- rejects encoded traversal separators (`%2e`, `%2f`, `%5c`)
- percent-decodes and rejects `..` segments

### 5.2 Auth flow

`metadata.auth` supports three paths:

- login endpoint mode (`metadata.auth.login == true`)
  - `GET`: returns login form
  - `POST`: parses body form fields `login` and `password`
  - successful auth: sets `rlw_session_token=<token>; secure; HttpOnly` and `303` redirect
  - failed/malformed auth body: deterministic `401`
- logout endpoint mode (`metadata.auth.logout == true`)
  - clears `rlw_session_token` and `rlw_redirect`, returns `303` to `/`
- allowlist mode (`metadata.auth` is a username list)
  - unauthenticated request: `302` to `/login` and sets `rlw_redirect=<query>`

### 5.3 Proxy routing behavior

If `${PREFIX}:PROXY:<host>` exists, RELIW proxies request and skips local content flow.

Current proxy behavior:

- upstream connect over TCP; TLS wrap+handshake when `scheme == "https"`
- rewrites:
  - `Host` -> upstream host
  - `Origin`/`Referer` -> upstream origin
  - adds `X-Forwarded-Host`, `X-Forwarded-Proto`, `X-Forwarded-For`
- response handling:
  - supports chunked responses with chunk extensions
  - normalizes content length
  - rewrites CORS allow-origin to original origin/host
  - ensures proxied `Set-Cookie` includes `Secure`

### 5.4 ETag and method semantics

- For content responses, ETag is generated from SHA-256 of content.
- Conditional behavior:
  - `GET` + matching `If-None-Match` -> `304` with empty body
  - `HEAD` -> `200` with empty body, includes ETag/content-length
  - non-`GET`/`HEAD` does not use ETag short-circuit

## 6. Failure-Mode Responses

Common status outcomes:

| Status | Trigger |
|---|---|
| `400` | Invalid host header or invalid query |
| `401` | Login failure (wrong creds or malformed body) |
| `404` | Route/content missing; non-`/metrics` on metrics listener |
| `405` | Method not allowed by entry metadata |
| `429` | Rate limit exceeded |
| `500` | Metadata/content/Lua content execution failures |
| `502` | Upstream proxy failures |
| `503` | Store initialization failure (main handler or metrics handler) |

Additional behavior:

- WAF block returns `301` with redirect to local sink URL.
- Unauthorized protected content returns `302` to `/login`.
- Logout returns `303` to `/`.

## 7. Observability

### 7.1 Logs

Main listener and metrics process both emit structured logs via `std.logger`.

Access-style request logs include:

- `vhost`, `method`, `query`, `status`, `process`, `size`, `time`
- `client_ip` (always present; socket peer address)
- plus configured `log_headers` if present in request
- optional forwarded context when present:
  - `forwarded_for` (from request `x-forwarded-for`)
  - `forwarded_real_ip` (from request `x-real-ip` when different from `client_ip`)

Important explicit log events:

- `store init failed`
- `invalid host header`
- `invalid query`
- `blocked by WAF`
- proxy startup/errors and metrics store init failures

### 7.2 Metrics endpoint

Metrics listener:

- `GET /metrics` -> Prometheus text format
- any other path -> `404`

Exported families:

- `http_requests_total{host="<host>",code="<status>"} <count>`
- `http_requests_by_method{host="<host>",method="<method>"} <count>`

## 8. Regression Suite (RELIW)

Current RELIW regression tests:

- `tests/reliw/test_store_init_failure.lua`
- `tests/reliw/test_metrics_connection_close.lua`
- `tests/reliw/test_proxy_upstream_failure.lua`
- `tests/reliw/test_proxy_https.lua`
- `tests/reliw/test_chunked_body_limits.lua`
- `tests/reliw/test_path_sanitization.lua`
- `tests/reliw/test_etag_method_semantics.lua`
- `tests/reliw/test_manager_reaping.lua`
- `tests/reliw/test_metrics_scan.lua`
- `tests/reliw/test_auth_malformed_body.lua`

Examples covered by tests:

- upstream TLS proxying and chunk-extension parsing (`test_proxy_https.lua`)
- ETag semantics for `GET`/`HEAD`/`POST` (`test_etag_method_semantics.lua`)
- chunked request body size enforcement (`test_chunked_body_limits.lua`)
- host/query/path traversal hardening (`test_path_sanitization.lua`)
- manager child reaping lifecycle (`test_manager_reaping.lua`)
- metrics SCAN behavior and bounds (`test_metrics_scan.lua`)
- malformed login body handling (`test_auth_malformed_body.lua`)
