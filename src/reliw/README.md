# RELIW -- A Redis-centric HTTP Web Server/Framework for Lua

## Configuration

RELIW requires a configuration file in JSON format. The location of
the file can be set by `RELIW_CONFIG_FILE` environment variable. If it's absent,
RELIW will try to load `/etc/reliw/config.json` file if there is any.

### A minimal config of a plain HTTP server

```json
{
  "ip": "127.0.0.1",
  "port": 8080
}
```

### A more complex one, with metrics server

```json
{
    "ip": "127.0.0.1",
    "port": 8080,
    "data_dir": "/var/www",
    "keepalive_idle_timeout": 15,
    "request_header_timeout": 10,
    "request_body_timeout": 30,
    "metrics": {
        "ip": "127.0.0.1",
        "port": 9101
    },
    "log_headers": [ "user-agent", "x-real-ip" ]
}
```

### HTTPS server with externally provisioned SSL certificates

```json
{
    "ip": "127.0.0.1",
    "port": 443,
    "tls_handshake_timeout": 10,
    "ssl": {
        "default": { "cert": "/var/www/certs/example.com.crt", "key": "/var/www/certs/example.com.key" },
        "hosts": {
            "example2.com": { "cert": "/var/www/certs/example2.com.crt", "key": "/var/www/certs/example2.com.key" }
        }
    }
}
```

### Connection timeout options

The server supports phase-specific timeouts (all values are in seconds):

- `keepalive_idle_timeout`: max idle time while waiting for the next request on a keep-alive connection (default: `15`)
- `request_header_timeout`: max time to receive request headers after first request line was received (default: `10`)
- `request_body_timeout`: max time to receive request body (default: `30`)
- `tls_handshake_timeout`: max time allowed for TLS handshake (default: `10`)
