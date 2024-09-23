# RELIW -- A Redis-centric HTTP Web Server/Framework for Lua

Based on real Lua code.

## Configuration

| Env var name          | Default                              | Description                                            |
|-----------------------|--------------------------------------|--------------------------------------------------------|
| `RELIW_SERVER_IP`     | *127.0.0.1*                          | IP to listen on                                        |
| `RELIW_SERVER_PORT`   | *8080*                               | Port to listen on                                      |
| `RELIW_LOG_LEVEL`     | *10*                                 | Log level (0 = debug, 10 = access, 50 = error)         |
| `RELIW_METRICS_HOST`  | *reliw.stats*                        | Virtual host for Prometheus metrics                    |
| `RELIW_LOG_HEADERS`   | *referer,x-forwarded-for,user-agent* | Request headers that shall be logged                   |
| `RELIW_REDIS_PREFIX`  | *RLW*                                | Prefix to use for Reliw's redis keys                   |
| `RELIW_REDIS_URL`     | *127.0.0.1:6379/13*                  | Redis IP, Port and database                            |
| `RELIW_CACHE_MAX`     | *5242880*                            | Size in bytes. Assets bigger than this are not cached. |
