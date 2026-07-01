# xlang-nginx — nginx replication in X Language

HTTP servers written in [xlang](https://github.com/dsadsasdaddas/xlang), benchmarked against real **nginx 1.28** (built from source).

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

## Benchmarks

See `bench/RESULTS.md` for full methodology and data.

| Workload | nginx | xlang |
|----------|-------|-------|
| Fixed response, keepalive 16-conc (prefork) | 77k req/s | **129k req/s** |
| 64KB file serving | 25.6k req/s | 22.7k req/s |

## Build

Requires the [xlang compiler](https://github.com/dsadsasdaddas/xlang):
```sh
xlangc c servers/server_prefork.x && cc -O2 -o server server_prefork.c && ./server
```
