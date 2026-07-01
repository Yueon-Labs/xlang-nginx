module main

// server_proxy <listen_port> <workers> <upstream1> [<upstream2> ...]
//
// HTTP reverse proxy + load balancer (nginx `proxy_pass` + `upstream {}`).
// Forwards each client request to an upstream and relays the response. With 2+
// upstreams, workers are spread across them (worker i -> upstream[i % N]) so
// accept distribution load-balances requests (round-robin equivalent).
//
// Model: prefork N workers (nginx/apache prefork), each running a blocking
// accept-loop on the shared listen socket. Each worker keeps ONE persistent
// upstream connection and reuses it for every request it handles (upstream
// keepalive — avoids a tcp_connect per request, like nginx). Per request:
//   1. (lazily) ensure the upstream connection is open,
//   2. forward the request bytes,
//   3. relay the response binary-safe: forward each recv'd chunk raw via
//      send_rbuf while Content-Length-framing from the header text view,
//   4. keep the upstream open for the next request. If the upstream dies
//      mid-response (relay returns -1), drop it and reconnect on the next request.
// SIGPIPE is ignored so a dead-peer send doesn't crash a worker.
//
// Limitations:
//   - a worker reuses ONE upstream conn (not a pool); fine for the prefork model
//     where each worker handles requests serially;
//   - no retry on mid-response upstream death (the client already got a partial
//     response); needs response buffering to retry cleanly;
//   - request body assumed to fit in one recv (GET/small POST); binary REQUEST
//     bodies would still be truncated by the text send_str(up, req) forward.
//
// Response relay IS binary-safe: the relay() helper forwards raw chunks via
// send_rbuf (length-aware), so images / compressed / arbitrary binary response
// bodies pass through uncorrupted.

// Position of the byte just past the first "\r\n\r\n", or -1 if not present.
fn find_header_end(buf: String): i32 {
    let i: i32 = str_find(buf, "\r\n\r\n")
    if i < 0 { return -1 }
    return i + 4
}

// Parse "Content-Length:" value from the header block (only within the first
// hdrlen bytes). Returns the integer, or -1 if absent.
fn parse_content_length(buf: String, hdrlen: i32): i32 {
    let k: i32 = str_find(buf, "Content-Length:")
    if k < 0 { return -1 }
    if k >= hdrlen { return -1 }
    let n: i32 = str_len(buf)
    let mut p: i32 = k + 16
    while p < n {
        let c: i32 = str_char_at(buf, p)
        if c == 32 { p = p + 1 } else { break }
    }
    let mut ve: i32 = p
    while ve < n {
        let c: i32 = str_char_at(buf, ve)
        if c == 13 { break }
        if c == 10 { break }
        ve = ve + 1
    }
    if ve <= p { return -1 }
    let numstr: String = str_slice(buf, p, ve)
    return str_to_int(numstr)
}

// Relay the full upstream response to the client, BINARY-SAFE. Forwards each
// recv'd chunk raw via send_rbuf (length-aware, so NUL bytes in images/etc. are
// preserved), while parsing Content-Length from the NUL-free header region (via
// the shared string-builder, which only ever sees header text) to know when the
// body is complete. Reads exactly headers + Content-Length body bytes, or until
// upstream closes. Returns total bytes relayed.
fn relay(client: i32, upstream: i32): i32 {
    sb_new()
    let mut total: i32 = 0
    let mut hdrlen: i32 = -1
    let mut cl: i32 = -1
    let mut done: i32 = 0
    while done == 0 {
        let n: i32 = recv_n(upstream)
        if n == 0 { break }
        send_rbuf(client, n)
        total = total + n
        if hdrlen < 0 {
            // Header region is NUL-free, so sb_push (strlen-based) faithfully
            // accumulates it for parsing; body bytes past the first NUL are
            // already forwarded raw above and are invisible here — which is fine,
            // we only need the headers.
            sb_push(rbuf_str())
            let buf: String = sb_str()
            let he: i32 = find_header_end(buf)
            if he >= 0 {
                hdrlen = he
                cl = parse_content_length(buf, hdrlen)
            }
        }
        if hdrlen >= 0 {
            if cl >= 0 {
                let body_seen: i32 = total - hdrlen
                if body_seen >= cl { done = 1 }
            }
        }
    }
    // If we had a Content-Length but exited via upstream EOF (n==0) before the
    // body completed, the upstream closed mid-response — signal failure so the
    // worker can drop the (now-desynced) upstream connection. With no
    // Content-Length, read-to-EOF is the correct termination, so total is fine.
    if cl >= 0 {
        if done == 0 { return -1 }
    }
    return total
}

// Split "host:port" → host (before the first ':'). For "127.0.0.1:8080" returns
// "127.0.0.1". (IPv6 not handled — multiple colons — but fine for IPv4/hostname.)
fn parse_host(s: String): String {
    let c: i32 = str_find(s, ":")
    if c < 0 { return s }
    return str_slice(s, 0, c)
}

// Split "host:port" → port (int after the first ':'). Defaults to 80 if none.
fn parse_port(s: String): i32 {
    let c: i32 = str_find(s, ":")
    if c < 0 { return 80 }
    return str_to_int(str_slice(s, c + 1, str_len(s)))
}

// Each worker is PINNED to one upstream — upstream[worker_index % N_upstreams]
// — and keeps ONE persistent connection to it (keepalive). With W workers and
// U upstreams, ~W/U workers pin to each upstream, so the kernel's accept
// distribution load-balances requests across backends (nginx `upstream {}`
// round-robin equivalent for the prefork model). If the upstream dies
// mid-response (relay returns -1), drop it and lazily reconnect. SIGPIPE is
// ignored (in main) so a dead-peer send doesn't kill the worker.
fn worker(index: i32, listen_fd: i32): i32 {
    let nup: i32 = argc() - 3
    let myidx: i32 = index % nup
    let up_arg: String = argv(3 + myidx)
    let upstream_host: String = parse_host(up_arg)
    let upstream_port: i32 = parse_port(up_arg)
    let mut up: i32 = -1
    while true {
        let client: i32 = accept(listen_fd)
        if client < 0 { continue }
        set_nodelay(client)
        while true {
            let req: String = recv_str(client)
            if str_len(req) == 0 { break }
            if up < 0 {
                up = tcp_connect(upstream_host, upstream_port)
                if up >= 0 { set_nodelay(up) }
            }
            if up < 0 {
                send_str(client, "HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n")
            } else {
                send_str(up, req)
                let r: i32 = relay(client, up)
                if r < 0 {
                    close_fd(up)
                    up = -1
                    break
                }
            }
        }
        close_fd(client)
    }
    return 0
}

fn main(): i32 {
    // CLI: server_proxy <listen_port> <workers> <upstream1> [<upstream2> ...]
    // each upstream is "host:port". >=2 upstreams => load balancing.
    let listen_port: i32 = str_to_int(argv(1))
    let workers: i32 = str_to_int(argv(2))
    let nup: i32 = argc() - 3

    let listen_fd: i32 = tcp_listen(listen_port)
    ignore_sigpipe()
    print_raw("xlang server_proxy: ")
    print_raw(int_to_str(workers))
    print_raw(" workers, :")
    print_raw(int_to_str(listen_port))
    print_raw(" -> ")
    print_raw(int_to_str(nup))
    print_raw(" upstream(s):")
    let mut ui: i32 = 0
    while ui < nup {
        print_raw(" ")
        print_raw(argv(3 + ui))
        ui = ui + 1
    }
    print_raw("\n")

    let mut i: i32 = 0
    while i < workers - 1 {
        let pid: i32 = fork()
        if pid == 0 {
            break
        }
        i = i + 1
    }
    worker(i, listen_fd)
    return 0
}
