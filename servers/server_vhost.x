module main

// server_vhost <listen_port> <workers> <route1> <route2> ...
//   each route is "<url-prefix>=<host>:<port>"  (or just "<host>:<port>" = "/")
//
// Path-routing reverse proxy — nginx `location {}` style. Each worker keeps a
// pool of upstream connections (Vec<i32>, one keepalive fd per route). Per
// request it reads the first chunk, parses the request path + Content-Length,
// picks the route whose prefix is the LONGEST match (empty prefix = catch-all),
// opens/reuses that upstream, forwards the first chunk + any remaining body,
// and relays the response (binary-safe). SIGPIPE ignored.
//
// Example: server_vhost 8080 16  /api=127.0.0.1:9001  /=127.0.0.1:9002

// Position just past the first "\r\n\r\n", or -1.
fn find_header_end(buf: String): i32 {
    let i: i32 = str_find(buf, "\r\n\r\n")
    if i < 0 { return -1 }
    return i + 4
}

fn parse_host(s: String): String {
    let c: i32 = str_find(s, ":")
    if c < 0 { return s }
    return str_slice(s, 0, c)
}

fn parse_port(s: String): i32 {
    let c: i32 = str_find(s, ":")
    if c < 0 { return 80 }
    return str_to_int(str_slice(s, c + 1, str_len(s)))
}

// Parse "Content-Length:" from the header block (within first hdrlen bytes).
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
    return str_to_int(str_slice(buf, p, ve))
}

// Request path = token between the first and second space of the request line.
fn extract_path(buf: String): String {
    let sp1: i32 = str_find(buf, " ")
    if sp1 < 0 { return "/" }
    let rest: String = str_slice(buf, sp1 + 1, str_len(buf))
    let sp2: i32 = str_find(rest, " ")
    if sp2 < 0 { return rest }
    return str_slice(rest, 0, sp2)
}

// Longest-matching-prefix route selection. Empty prefix matches anything
// (catch-all). Returns the route index (default 0 if nothing matches).
fn find_route(path: String, prefixes: Vec<String>, nroutes: i32): i32 {
    let mut best: i32 = -1
    let mut bestlen: i32 = -1
    let mut i: i32 = 0
    while i < nroutes {
        let pfx: String = prefixes[i]
        let plen: i32 = str_len(pfx)
        if str_starts_with(path, pfx) {
            if plen > bestlen {
                bestlen = plen
                best = i
            }
        }
        i = i + 1
    }
    if best < 0 { best = 0 }
    return best
}

// Relay the full upstream response to the client, BINARY-SAFE.
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
                if total - hdrlen >= cl { done = 1 }
            } else {
                done = 1
            }
        }
    }
    if cl >= 0 {
        if done == 0 { return -1 }
    }
    return total
}

fn worker(index: i32, listen_fd: i32): i32 {
    let nroutes: i32 = argc() - 3
    let prefixes: Vec<String> = vec_new()
    let hosts: Vec<String> = vec_new()
    let ports: Vec<i32> = vec_new()
    let pool: Vec<i32> = vec_new()
    let mut k: i32 = 0
    while k < nroutes {
        let arg: String = argv(3 + k)
        let eq: i32 = str_find(arg, "=")
        if eq >= 0 {
            prefixes.push(str_slice(arg, 0, eq))
            let upspec: String = str_slice(arg, eq + 1, str_len(arg))
            hosts.push(parse_host(upspec))
            ports.push(parse_port(upspec))
        } else {
            prefixes.push("")
            hosts.push(parse_host(arg))
            ports.push(parse_port(arg))
        }
        pool.push(-1)
        k = k + 1
    }

    while true {
        let client: i32 = accept(listen_fd)
        if client < 0 { continue }
        set_nodelay(client)
        while true {
            // Read the first chunk; the request line + headers are in it.
            let n: i32 = recv_n(client)
            if n == 0 { break }
            let buf: String = rbuf_str()
            let path: String = extract_path(buf)
            let he: i32 = str_find(buf, "\r\n\r\n")
            let mut hdrlen: i32 = n
            if he >= 0 { hdrlen = he + 4 }
            let cl: i32 = parse_content_length(buf, hdrlen)

            let route: i32 = find_route(path, prefixes, nroutes)
            let mut upfd: i32 = pool[route]
            if upfd < 0 {
                upfd = tcp_connect(hosts[route], ports[route])
                if upfd >= 0 { set_nodelay(upfd) }
                pool[route] = upfd
            }
            if upfd < 0 {
                send_str(client, "HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
                break
            }

            // Forward the first chunk, then any remaining request body.
            send_rbuf(upfd, n)
            if cl >= 0 {
                let mut need: i32 = hdrlen + cl - n
                while need > 0 {
                    let m: i32 = recv_n(client)
                    if m == 0 { break }
                    send_rbuf(upfd, m)
                    need = need - m
                }
            }

            let r: i32 = relay(client, upfd)
            if r < 0 {
                close_fd(upfd)
                pool[route] = -1
                break
            }
        }
        close_fd(client)
    }
    return 0
}

fn main(): i32 {
    let listen_port: i32 = str_to_int(argv(1))
    let workers: i32 = str_to_int(argv(2))
    let listen_fd: i32 = tcp_listen(listen_port)
    ignore_sigpipe()
    print_raw("xlang server_vhost: ")
    print_raw(int_to_str(workers))
    print_raw(" workers, :")
    print_raw(int_to_str(listen_port))
    print_raw(", ")
    print_raw(int_to_str(argc() - 3))
    print_raw(" route(s)\n")

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
