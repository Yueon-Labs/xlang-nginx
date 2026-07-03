module main

// server_tls <docroot> <port> <cert> <key> [-w N] — minimal HTTPS file server
// (GET only). Each worker runs a blocking accept → TLS handshake → read → serve
// → close loop. `-w N` preforks N workers (SO_REUSEPORT) so N concurrent TLS
// connections are handled in parallel (one per worker) — concurrent HTTPS
// WITHOUT non-blocking TLS (SSL_WANT_READ/WRITE) complexity. Verified with:
// curl -k https://127.0.0.1:<port>/index.html

fn mime_of(path: String): String {
    if str_find(path, ".html") >= 0 { return "text/html" }
    if str_find(path, ".css") >= 0 { return "text/css" }
    if str_find(path, ".js") >= 0 { return "application/javascript" }
    if str_find(path, ".json") >= 0 { return "application/json" }
    if str_find(path, ".txt") >= 0 { return "text/plain" }
    if str_find(path, ".png") >= 0 { return "image/png" }
    if str_find(path, ".jpg") >= 0 { return "image/jpeg" }
    return "application/octet-stream"
}

// Path = token between the first two spaces; "/index.html" for "/". Query stripped.
fn parse_path(req: String): String {
    let sp1: i32 = str_find(req, " ")
    if sp1 < 0 { return "/" }
    let rest: String = str_slice(req, sp1 + 1, str_len(req))
    let sp2: i32 = str_find(rest, " ")
    let mut path: String = "/"
    if sp2 < 0 {
        path = rest
    } else {
        path = str_slice(rest, 0, sp2)
    }
    let q: i32 = str_find(path, "?")
    if q >= 0 {
        path = str_slice(path, 0, q)
    }
    if str_eq(path, "/") {
        path = "/index.html"
    }
    return path
}

// Reject path traversal ("..").
fn sanitize_path(path: String): i32 {
    let n: i32 = str_len(path)
    let mut i: i32 = 0
    while i + 1 < n {
        if str_char_at(path, i) == 46 {
            if str_char_at(path, i + 1) == 46 {
                return -1
            }
        }
        i = i + 1
    }
    return 0
}

fn main(): i32 {
    // Positional: docroot port cert key. Flag: -w N (worker pool, default 1).
    let pos: Vec<String> = vec_new()
    let mut workers: i32 = 1
    let mut ai: i32 = 1
    while ai < argc() {
        if argv(ai) == "-w" {
            if ai + 1 < argc() {
                workers = str_to_int(argv(ai + 1))
                ai += 1
            }
        } else {
            pos.push(argv(ai))
        }
        ai += 1
    }
    if vec_len(pos) < 4 {
        print_str("usage: server_tls <docroot> <port> <cert> <key> [-w N]\n")
        return 1
    }
    let docroot: String = pos[0]
    let port: i32 = str_to_int(pos[1])
    let cert: String = pos[2]
    let key: String = pos[3]
    print_raw("xlang server_tls (HTTPS) on port ")
    print_raw(int_to_str(port))
    if workers > 1 {
        print_raw(", workers=")
        print_raw(int_to_str(workers))
    }
    print_raw("\n")
    // Prefork worker pool: each worker creates its own listen socket (SO_REUSEPORT)
    // and loads its own SSL_CTX, then runs the blocking accept->TLS->serve loop.
    // N blocking workers handle up to N concurrent TLS connections (one each).
    if workers > 1 {
        let mut wi: i32 = 1
        while wi < workers {
            let pid: i32 = fork()
            if pid == 0 {
                break
            }
            wi += 1
        }
    }
    let mut listen_fd: i32 = 0
    if workers > 1 {
        listen_fd = tcp_listen_reuseport(port)
    } else {
        listen_fd = tcp_listen(port)
    }
    let ctx: i32 = tls_ctx_new(cert, key)
    if ctx < 0 {
        print_str("server_tls: failed to load cert/key\n")
        return 1
    }
    while true {
        let fd: i32 = accept(listen_fd)
        if fd < 0 {
            // accept on a blocking socket blocks until a connection; -1 is an
            // error — just retry.
            continue
        }
        let ssl: i32 = tls_accept(ctx, fd)
        if ssl >= 0 {
            let req: String = tls_read(ssl)
            if sanitize_path(parse_path(req)) < 0 {
                tls_write(ssl, "HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n")
            } else {
                if str_starts_with(req, "GET ") == 0 {
                    tls_write(ssl, "HTTP/1.1 405 Method Not Allowed\r\nContent-Length: 0\r\n\r\n")
                } else {
                    let mpath: String = parse_path(req)
                    let full: String = str_concat(docroot, mpath)
                    if file_exists(full) {
                        let body: String = read_file(full)
                        let mime: String = mime_of(mpath)
                        let blen: i32 = str_len(body)
                        tls_write(ssl, "HTTP/1.1 200 OK\r\nContent-Type: ")
                        tls_write(ssl, mime)
                        tls_write(ssl, "\r\nContent-Length: ")
                        tls_write(ssl, int_to_str(blen))
                        tls_write(ssl, "\r\nConnection: close\r\n\r\n")
                        tls_write(ssl, body)
                    } else {
                        tls_write(ssl, "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n")
                    }
                }
            }
            tls_close(ssl)
        }
        close_fd(fd)
    }
    return 0
}
