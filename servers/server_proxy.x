module main

// server_proxy <upstream_host> <upstream_port> <listen_port> [workers]
//
// HTTP reverse proxy (nginx `proxy_pass` equivalent). Forwards each client
// request to an upstream and relays the response.
//
// Model: prefork N workers (nginx/apache prefork), each running a blocking
// accept-loop on the shared listen socket. Per request a worker:
//   1. opens a fresh upstream connection (tcp_connect),
//   2. forwards the request bytes,
//   3. relays the response: accumulates headers + Content-Length body (or reads
//      until upstream close when no Content-Length), then sends it whole to the
//      client in one write (no Nagle split),
//   4. closes the upstream (client<->proxy keepalive is preserved).
//
// v1 limitations:
//   - fresh upstream connection per request (no keepalive pool) — the main
//     throughput overhead vs nginx (which reuses upstream conns);
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
    return total
}

// Proxy a single request: forward req to a fresh upstream, relay the response.
// Returns 0 on success, -1 if the client closed (caller drops the connection).
fn proxy_one(client: i32, req: String, upstream_host: String, upstream_port: i32): i32 {
    let up: i32 = tcp_connect(upstream_host, upstream_port)
    if up < 0 {
        send_str(client, "HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n")
        return 0
    }
    set_nodelay(up)
    send_str(up, req)
    relay(client, up)
    close_fd(up)
    return 0
}

fn worker(listen_fd: i32, upstream_host: String, upstream_port: i32): i32 {
    while true {
        let client: i32 = accept(listen_fd)
        if client < 0 { continue }
        set_nodelay(client)
        while true {
            let req: String = recv_str(client)
            if str_len(req) == 0 { break }
            proxy_one(client, req, upstream_host, upstream_port)
        }
        close_fd(client)
    }
    return 0
}

fn main(): i32 {
    let mut upstream_host: String = "127.0.0.1"
    let mut upstream_port: i32 = 28084
    let mut listen_port: i32 = 28090
    let mut workers: i32 = 16
    if argc() >= 2 { upstream_host = argv(1) }
    if argc() >= 3 { upstream_port = str_to_int(argv(2)) }
    if argc() >= 4 { listen_port = str_to_int(argv(3)) }
    if argc() >= 5 { workers = str_to_int(argv(4)) }

    let listen_fd: i32 = tcp_listen(listen_port)
    print_raw("xlang server_proxy: ")
    print_raw(int_to_str(workers))
    print_raw(" workers, :")
    print_raw(int_to_str(listen_port))
    print_raw(" -> ")
    print_raw(upstream_host)
    print_raw(":")
    print_raw(int_to_str(upstream_port))
    print_raw("\n")

    let mut i: i32 = 0
    while i < workers - 1 {
        let pid: i32 = fork()
        if pid == 0 {
            break
        }
        i = i + 1
    }
    worker(listen_fd, upstream_host, upstream_port)
    return 0
}
