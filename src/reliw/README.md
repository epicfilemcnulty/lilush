# RELIW -- Redis-centric HTTP Server/Framework for Lua

RELIW is a standalone app built from this repo (`buildgen/apps/reliw.lua`).

For full operator/developer documentation, see:

- `docs/RELIW.md`

That guide includes:

- complete configuration reference and defaults
- Redis data schema and proxy metadata model
- WAF semantics and request handling flow
- failure-mode response matrix and troubleshooting
- rollout/rollback notes and observability guidance

## Quickstart

### Configure RELIW

RELIW reads config from:

1. `RELIW_CONFIG_FILE` (if set)
2. `/etc/reliw/config.json` (fallback)

Minimal HTTP config:

```json
{
  "ip": "127.0.0.1",
  "port": 8080
}
```

HTTPS + metrics example:

```json
{
  "ip": "127.0.0.1",
  "port": 443,
  "data_dir": "/var/www",
  "tls_handshake_timeout": 10,
  "metrics": {
    "ip": "127.0.0.1",
    "port": 9101,
    "scan_count": 100,
    "scan_limit": 2000
  },
  "ssl": {
    "default": {
      "cert": "/var/www/certs/example.com.crt",
      "key": "/var/www/certs/example.com.key"
    },
    "hosts": {
      "example2.com": {
        "cert": "/var/www/certs/example2.com.crt",
        "key": "/var/www/certs/example2.com.key"
      }
    }
  }
}
```

### Seed minimal Redis routing

```bash
redis-cli -n 13 SET RLW:API:example.com '[["/","home",true]]'
redis-cli -n 13 SET RLW:API:example.com:home '{"methods":{"GET":true,"HEAD":true},"index":"index.md"}'
```

### Add content

```bash
mkdir -p /var/www/example.com
printf '# Hello\n' > /var/www/example.com/index.md
```

### Run RELIW

```bash
RELIW_CONFIG_FILE=/etc/reliw/config.json /usr/local/bin/reliw
```
