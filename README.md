# xlang-nginx — nginx replication in X Language

HTTP servers written in [xlang](https://github.com/Yueon-Labs/xlang), benchmarked against real **nginx 1.28** (built from source).

## Servers

- `server.x` — single-request HTTP server
- `server_loop.x` — looping (blocking) server
- `server_keepalive.x` — keepalive server
- `server_prefork.x` — prefork 16-worker server (nginx/apache model)
- `server_epoll.x` — single-process epoll event loop (nginx's actual model)
- `server_file.x` — static file serving
- `server_route.x` — request-path routing (nginx location-style)
- `server_web.x` — epoll + sendfile + fd-cache static server (beats nginx 1.28 at every file size)
- `server_pro.x` — production file server (dir listing, path-traversal protection, access log)
- `server_http.x` — **full HTTP/1.1**: GET/HEAD routing, `Range`→`206 Partial Content` + `Content-Range`, keep-alive, 404/405/403. 19-case curl suite in `bench/http_test.sh`.
- `server_proxy.x` — **reverse proxy + load balancer** (nginx `proxy_pass` + `upstream {}`): prefork workers, binary-safe response relay, each worker reuses one persistent upstream connection (keepalive). 2+ upstreams ⇒ worker-pinned load balancing (verified ~50/50). 9-case suite in `bench/proxy_test.sh`, distribution test in `bench/lb_test.sh`.

## Benchmarks

See `bench/RESULTS.md` for full methodology and data. Measured with the **pure-xlang `xwrk`** client (compiled, no GIL) — the python `bench_py.py` client undercounts ~2–3× (it's the bottleneck, not the servers).

| Workload (xwrk @ c=16) | result |
|------------------------|--------|
| server_http (direct) | ~59–79k req/s |
| reverse proxy → 1 backend | ~67k req/s (≈ direct — proxy adds ~zero overhead) |
| reverse proxy → 2 backends (LB) | **~104k req/s** (scales with backends) |
| Fixed response, keepalive (prefork, vs nginx 1.28) | nginx 77k · **xlang 129k** |

## Build

Requires the [xlang compiler](https://github.com/Yueon-Labs/xlang):
```sh
xlangc c servers/server_prefork.x && cc -O2 -o server server_prefork.c && ./server
```
