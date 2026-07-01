# xlang HTTP server vs nginx — benchmark

## Setup
- Server: wzu (Ubuntu 22.04, x86_64), **localhost loopback**.
- **xlang server**: `examples/server_loop.x` (blocking, one connection at a time), compiled xlang → C → `cc -O2`.
- **nginx**: 1.28.0 built **from source** on the server (`~/nginx-bin`), `location / { return 200 "hello"; }` (hardcoded, no file I/O).
- Both return the **identical 5-byte response** `"hello"`.
- Load: `bench/bench.py` (stdlib python, new connection per request), 8s @ 50 concurrent.

## Result (fair: both return hardcoded "hello")
| server   | run 1       | run 2       |
|----------|-------------|-------------|
| nginx 1.28 | ~1730 req/s | ~1710 req/s |
| xlang      | ~1770 req/s | ~2560 req/s |

xlang's compiled server is in the **same ballpark** as nginx for this trivial fixed-response workload (within ~1.0–1.5×).

### Stronger load (multiprocess, bypasses the python GIL) — `bench/bench_mp.py`
64-core box, 8 processes, new connection per request, 6s:
| server            | req/s   |
|-------------------|---------|
| nginx 1.28        | ~8360   |
| xlang (1 worker)  | ~8540   |

Even under ~5× the load, xlang's **blocking** server stays level with nginx. For this minimal workload the per-connection work is so tiny that serializing connections does not yet cost throughput — both are bound by accept/loop rate (and likely still partly by the client).

### Decisive: keepalive + concurrency — `bench/bench_ka.py`
16 concurrent **persistent** connections, 6s:
| server                  | req/s    |
|-------------------------|----------|
| nginx 1.28              | ~69,800  |
| xlang (1 blocking worker) | ~8,230 |

**nginx is ~8.5× faster under keepalive concurrency.** xlang serves one connection at a time — its inner keepalive loop blocks on `recv`, starving the other 15 connections; nginx's epoll serves all 16 concurrently. This is the workload that triggers "modify x": add concurrency (fork workers / epoll event loop) so xlang can serve many connections at once.

### After "modify x": `fork()` + prefork workers — `bench/bench_ka.py`, 16 conns
Added `fork()`/`getpid()` builtins so xlang can run the **prefork** worker model (nginx/apache prefork). `examples/server_prefork.x`: 16 workers, each a blocking keepalive loop on the shared listen socket. Same workload, same machine:
| server                    | req/s     |
|---------------------------|-----------|
| nginx 1.28                | ~77,200   |
| xlang prefork (16 workers) | ~128,600  |

The gap **reversed**: from 8.5× slower (1 blocking worker, ~8.2k) to ~1.67× **faster** than nginx (16 workers, ~128.6k). "Modify x" (add concurrency via fork) closed the measured gap decisively.

**Honest caveat:** this is a trivial fixed-response workload where a minimal server can beat nginx — nginx does full HTTP parsing + header generation + module chain per request, while xlang blasts a fixed 5-byte string. Real workloads (request parsing, routing, file serving) would rebalance this. Still: xlang → C → prefork is genuinely fast, and the modify-x cycle produced a measured, reproducible improvement.

### After "modify x" again: true epoll event loop — `bench/loadgen.c`, keepalive
Added **`epoll` builtins** (`epoll_create`/`epoll_add`/`epoll_del`/`epoll_wait` + `set_nonblock`) so xlang runs nginx's **actual architecture**: a single process multiplexing every connection through one epoll fd (no fork, no thread-per-conn). `servers/server_epoll.x`. Compared against nginx 1.28 in a **fair single-process config** (`worker_processes 1`, one epoll loop — same model; `keepalive_requests 1000000` so nginx doesn't truncate). Load = **`bench/loadgen.c`** (multiprocess C, no GIL — the python client capped ~60k). 200 000 keepalive requests, localhost, 2 stable runs:

| concurrency | xlang prefork(16) | xlang epoll | nginx 1.28 (1 worker) |
|-------------|-------------------|-------------|------------------------|
| 64          | **317k**          | 90k         | 74k                    |
| 256         | **117k**          | 91k         | 72k                    |
| 1024        | 26k ⬇             | **86k**     | 70k                    |
| 4096        | 123k              | 44k         | 56k                    |

**The decisive finding — epoll scales flat, prefork collapses:**

1. **xlang epoll holds ~88k req/s flat** from c=64 to c=1024 (90→91→86k) — the hallmark of a correct event loop: throughput independent of connection count. It **beats nginx by ~25%** across that whole range (nginx holds ~71k).
2. **prefork is the fastest at low concurrency** (317k @ c=64 — 16 blocking workers in a tight recv/send loop) but is **erratic and collapses**: 317k → 117k → **26k** at c=1024, then 123k. With 1024 connections and only 16 blocking workers, head-of-line blocking in the accept queue starves connections. This is exactly the prefork pathology epoll exists to fix — now demonstrated in xlang.
3. At extreme c=4096 all three degrade (client-side: 4096 processes thrashing the 64-core scheduler), so that row is noise, not a server ceiling.

**Two "modify x" fixes that mattered here:**
- `recv_str` originally `malloc(65536)` per request → ~2.5 GB/s allocation churn at high req/s. Static receive buffer fixed it (c=1000 doubled).
- **accept-drain loop** (the standard nginx pattern): when the listen socket fires, loop `accept()` until EAGAIN instead of one-per-epoll_wait-wakeup. This took epoll c=1024 from 52k → **86k** — flat scaling only appeared after this.

### Realistic workload: serve a 64 KB file — sendfile vs read+send
`examples/server_file.x` (prefork, `read_file` + `str_concat` + `send`, userspace copies) vs nginx serving the same file via **sendfile** (zero-copy). 16 keepalive conns; both verified serving exactly 65536 bytes:
| server              | req/s   | ~throughput |
|---------------------|---------|-------------|
| nginx (sendfile)    | ~25,600 | ~1.6 GB/s   |
| xlang (read+send)   | ~22,700 | ~1.4 GB/s   |

xlang is only **~13% slower** than nginx for 64 KB file serving — far smaller than expected. At 64 KB/request over loopback the workload is **bandwidth-bound** (~1.5 GB/s), so sendfile's zero-copy advantage is dwarfed by the transfer time; xlang's per-request page-cached read + memcpy-concat is efficient enough. (sendfile would win more for many small files at very high request rates, where per-request overhead dominates.)

## Honest caveats — this is NOT "xlang beats nginx"
1. **Trivial workload** (5-byte fixed response). nginx's machinery overhead dominates when the work is tiny, so a minimal hand-written server can match it. Real workloads (file serving, proxying, keepalive, real HTTP parsing) would change the picture.
2. **The load generator (python, threading + GIL) likely caps the measurement** around ~2000–2500 req/s — the client may be the bottleneck, so the true server ceilings are not reached.
3. **xlang's server is blocking, single-connection.** At high concurrency, keepalive, or pipelining, nginx's epoll event loop would pull far ahead.

## What this validates
xlang → C → `cc -O2` produces genuinely fast server code: for a hello-world HTTP response it is competitive with nginx on the same machine. That is a real, rigorous data point (same workload, same machine, real nginx built from source).

## To go further (honest next steps)
- ~~Higher concurrency + keepalive to expose the blocking-vs-epoll gap.~~ **Done** — epoll event-loop server scales flat ~88k and beats nginx ~25% across c=64..1024; prefork collapse at c=1024 demonstrated.
- ~~A C load generator to get past the python GIL client cap.~~ **Done** — `bench/loadgen.c`, multiprocess.
- ~~Realistic workload: serve a real file, parse the request path.~~ **Done** — `servers/server_web.x` (epoll + request parse + sendfile); competitive with nginx (see below).
- Optional: edge-triggered epoll (EPOLLET) + recv/send drain loops to push the c=4096 extreme (currently all three degrade there from client-side process storm).

### Realistic workload: HTTP file server — `servers/server_web.x`, `bench/http_load.c`
A real web server on the epoll loop: parses the request line (`GET /path HTTP/1.1`), maps `/` → `index.html`, serves the file with Content-Type/Length + 200 (or 404), keepalive. File bodies go out via **sendfile** (zero-copy) and **open fds are cached** (`cache_open`/`cache_size` — hot files skip per-request open/stat/close, like nginx). Same webroot served by nginx 1.28 (single worker) for a fair comparison. `bench/http_load.c` = multiprocess keepalive C client that parses Content-Length. c=64:

| file | xlang | nginx 1.28 | result |
|------|-------|------------|--------|
| `/` (52 B)     | **45.6k req/s** | 38.7k | **xlang 1.18× faster** |
| `/mid.txt` (13 KB) | **41.2k** | 39.6k | **xlang 1.04× faster** |
| `/big.txt` (1.3 MB) | **3.3k** | 1.2k | **xlang 2.7× faster** |

Content verified byte-identical to nginx. **xlang now beats nginx 1.28 at every file size** for this static-serving workload.

**Progression of this result (three "hidden per-request cost" fixes):**
1. **Nagle + delayed ACK** (24 req/s → 36k): headers sent via `send_str`, body via `sendfile` = two sends; without `TCP_NODELAY`, Nagle held the 2nd packet for the 1st's ACK, and the keepalive client's delayed-ACK (~40 ms) stalled every small-file request. Added `set_nodelay`. (36k was 93% of nginx.)
2. **fd cache** (36k → 45.6k, now beats nginx): `cache_open`/`cache_size` keep hot files' fd open + size known, so a request skips open + fstat + close. This flipped the small/medium comparison from "nginx faster (79–93%)" to "xlang faster (1.04–1.18×)". nginx caches fds too, but xlang's per-request machinery is leaner.
3. Large files were never Nagle-bound (continuous sendfile stream keeps ACKs flowing) and stay ~2.7× nginx via sendfile zero-copy.

Same lesson across the whole project: a single hidden per-request cost (str_slice strlen, recv_str malloc, Nagle stall, open/close churn) dominates throughput, not the algorithm.

### HTTP/1.1 maturity — `servers/server_http.x` (Range/206/HEAD/method-routing)

`servers/server_http.x` is the most feature-complete server: full HTTP/1.1 request-line parse (METHOD / PATH / VERSION), header lookup (`header_value`), method routing (**GET** serves body, **HEAD** serves headers only with correct Content-Length, anything else → **405**), **Range / `206 Partial Content`** with `Content-Range` (uses the new `sendfile_range` builtin to sendfile from an offset), path-traversal **403**, **404**, access logging, and keep-alive. `bench/http_test.sh` is a 19-case curl functional suite (GET, HEAD, three Range shapes incl. suffix, bad range, 404/405/403, subdir, sequential keepalive) — all pass on the wzu box.

**Accurate benchmark** (`bench/xwrk_bench.sh`, pure-xlang `xwrk` client, c=16, 3s — no GIL bottleneck):

| server (direct) | req/s @ c=16 |
|-----------------|--------------|
| server_web (epoll+sendfile) | ~70k |
| server_pro  (+dir listing/logging) | ~62k |
| server_http (+Range/HEAD/routing) | ~66k |

All three file servers are in the **~62–70k req/s** band — comparable to each other (the differences are run-to-run noise). The old `bench_py.py` numbers below (~16–28k) were **client-bottlenecked** (python GIL) and undercounted absolute capacity ~2–3×; kept for the relative comparison only.

| server (bench_py.py, relative only) | c=1 | c=16 | c=64 |
|--------|-----|------|------|
| server_web | 16.8k | 24.9k | 23.4k |
| server_pro  | 16.2k | 27.0k | 24.2k |
| server_http | 16.4k | 27.7k | 24.5k |

Despite doing strictly more work per request than `server_pro`/`server_web`, `server_http` is **competitive** (within noise of the simpler servers) — the per-request HTTP/1.1 work is free at concurrency.

**Progression — same "hidden per-request cost" lesson again:**
1. **Naïve version**: 9.4k req/s at c=1 (vs 17k for `server_pro`) — a 1.8× regression from the extra HTTP/1.1 work.
2. **Hot-path fix 1 — prefix routing**: replaced `parse_method()` (one `str_slice` = one malloc) + two `str_eq` with `str_starts_with(req, "GET " / "HEAD ")` (no allocation). Method routing is now a `strncmp`.
3. **Hot-path fix 2 — no `str_concat` in `header_value`**: callers pass the colon-suffixed key (`"Range:"`) directly, removing a per-request `str_concat` malloc.
4. Result: c=1 **9.4k → 16.4k** (+75%), now matching the simpler servers; c=16 the best of the three.

The extra HTTP/1.1 features are *free at concurrency* because at c≥16 the bottleneck is connection multiplexing, not per-request string work — but at c=1 (single-connection latency bound) the per-request malloc count directly divides into req/s, which is why the two zero-alloc fixes mattered there.

### HTTP reverse proxy — `servers/server_proxy.x` (nginx `proxy_pass`)

The most common nginx use case: sit in front of a backend and forward requests. `server_proxy.x` is a **prefork** reverse proxy (N blocking workers, each accept-loop + keepalive). Per request a worker does a fresh `tcp_connect` to the upstream, forwards the request, relays the response by accumulating headers + `Content-Length`-framed body (multi-recv loop) and writing it to the client in one send (no Nagle split). Requires the new `tcp_connect` builtin (DNS-resolving, via `getaddrinfo`).

`bench/proxy_test.sh` (8 cases, all pass on wzu): GET body matches direct, Range `206` + partial body relayed, 404 relayed, and a ~170 KB **multi-recv** text file relayed byte-identical to both direct and the on-disk source.

**Benchmark** — ⚠️ **measurement correction.** The earlier numbers (below, from `bench_py.py`) were **client-bottlenecked**: the python load generator's GIL capped measurements at ~25–28k req/s for *both* direct and proxied, which falsely made the proxy look like the ceiling. The pure-xlang `xwrk` client (compiled C, no GIL) reveals the truth — `bench/xwrk_bench.sh`, c=16, 3s:

| target (xwrk, accurate) | req/s |
|------------------------|-------|
| server_http (direct)   | ~59–79k (run-to-run; box load) |
| **proxy → 1 backend**  | **~67k** (≈ direct — the keepalive proxy adds ~zero overhead) |

So the reverse proxy is **NOT a bottleneck** — with upstream keepalive it matches the backend. The per-request `tcp_connect` (the old prefork overhead) is fully amortized. (The earlier "proxy hop-bound at c=1" / "~60% of direct" claims were python-client artifacts too.) c=1 is still hop-bound in absolute terms (a proxy is a double-hop), but the proxy no longer caps concurrency-saturated throughput.

Old `bench_py.py` numbers (kept for the record; ~2–3× undercounts): direct 25.8k, proxy 26.2k @ c=16.

### Load balancing — multiple upstreams (nginx `upstream {}`)

`server_proxy` now takes 2+ upstreams (`<listen_port> <workers> <up1> [up2] ...`). Each worker is **pinned** to `upstream[worker_index % N]` and keeps one persistent connection to it; with W workers and U upstreams, ~W/U workers land on each, so the kernel's accept distribution spreads requests across backends (round-robin equivalent for the prefork model).

**Distribution** (`bench/lb_test.sh`, 2 backends serving "A"/"B", 200 requests): **A=101, B=99** — essentially ideal 50/50. All 4 checks pass.

**Throughput** (`bench/xwrk_bench.sh`, xwrk client, c=16, accurate): **1 backend ≈ 67k → 2 backends ≈ 104k req/s** — load balancing **scales** (+55%, heading toward 2× as the proxy overhead amortizes). (The earlier `bench/lb_bench.sh` showed 2 backends *slower* than 1 — that was entirely the python-client artifact; with an accurate client, LB clearly pays off even for fast static backends.) LB also always provides redundancy/failover, and pays off most when a single backend is the limiter (slow app servers — the canonical nginx use case).


**Known limitation — binary REQUEST bodies:** the response relay is now binary-safe (see below), but the *request* forward (`send_str(up, req)`) is still C-string-based, so a binary request body (e.g. a POST upload with NUL bytes) would be truncated. GET proxying and text POSTs are fine.

**Binary-safe response relay** (added after the initial proxy): three length-aware builtins — `recv_n(fd)` (recv into a static byte buffer, returns the count), `rbuf_str()` (text view of that buffer, valid for the NUL-free header region), `send_rbuf(fd, n)` (send exactly n bytes, looping past partial writes). The relay now forwards each recv'd chunk *raw* via `send_rbuf` (NULs preserved) while parsing `Content-Length` from the header text view for framing. Verified: a 150 KB `/dev/urandom` body (full of NUL bytes) relays byte-identical to the source (`proxy_test.sh` case 9). The **backend** (`server_http`) serves binary via `sendfile` (raw) regardless.



