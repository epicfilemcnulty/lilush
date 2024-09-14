# RELIW -- Redis-centric HTTP Web Server/Framework

Based on real Lua code.

## Configuration

| Env var name          | Default                              | Description                          |
|-----------------------|--------------------------------------|--------------------------------------|
| `RELIW_SERVER_IP`     | *127.0.0.1*                          | IP to listen on                      |
| `RELIW_SERVER_PORT`   | *8080*                               | Port to listen on                    |
| `RELIW_LOG_LEVEL`     | *10*                                 | Log level (0 = debug)                |
| `RELIW_METRICS_HOST`  | *reliw.stats*                        | Virtual host for Prometheus metrics  |
| `RELIW_LOG_HEADERS`   | *referer,x-forwarded-for,user-agent* | Request headers that shall be logged |
