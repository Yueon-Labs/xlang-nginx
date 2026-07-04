module main

// server_web <docroot> [port] [-w N] — epoll event-loop HTTP FILE server
// (nginx's real job). `-w N` runs an N-process prefork worker pool, each
// worker its own epoll loop on a SO_REUSEPORT socket (nginx's multi-worker
// model — the kernel load-balances connections across workers). Default: 1.
// Parses each request line (GET /path HTTP/1.1), maps /path -> docroot/path
// ("/" -> index.html), serves the file with Content-Length/Type + 200, or 404.
// Connection closed after each response. Built on the epoll builtins; tests
// xlang's string parsing (str_find/str_slice) and file I/O (read_file etc.).

fn mime_of(path: String): String {
    // Match by file EXTENSION (suffix), case-insensitive — not substring.
    // (str_find would wrongly map "foo.html.bak" → text/html.)
    let p: String = str_lower(path)
    if str_ends_with(p, ".html") { return "text/html" }
    if str_ends_with(p, ".htm") { return "text/html" }
    if str_ends_with(p, ".css") { return "text/css" }
    if str_ends_with(p, ".js") { return "application/javascript" }
    if str_ends_with(p, ".mjs") { return "application/javascript" }
    if str_ends_with(p, ".json") { return "application/json" }
    if str_ends_with(p, ".txt") { return "text/plain" }
    if str_ends_with(p, ".xml") { return "application/xml" }
    if str_ends_with(p, ".svg") { return "image/svg+xml" }
    if str_ends_with(p, ".png") { return "image/png" }
    if str_ends_with(p, ".jpg") { return "image/jpeg" }
    if str_ends_with(p, ".jpeg") { return "image/jpeg" }
    if str_ends_with(p, ".gif") { return "image/gif" }
    if str_ends_with(p, ".ico") { return "image/x-icon" }
    if str_ends_with(p, ".webp") { return "image/webp" }
    if str_ends_with(p, ".pdf") { return "application/pdf" }
    if str_ends_with(p, ".zip") { return "application/zip" }
    if str_ends_with(p, ".gz") { return "application/gzip" }
    if str_ends_with(p, ".tar") { return "application/x-tar" }
    if str_ends_with(p, ".mp4") { return "video/mp4" }
    if str_ends_with(p, ".webm") { return "video/webm" }
    if str_ends_with(p, ".mp3") { return "audio/mpeg" }
    if str_ends_with(p, ".wasm") { return "application/wasm" }
    if str_ends_with(p, ".woff") { return "font/woff" }
    if str_ends_with(p, ".woff2") { return "font/woff2" }
    return "application/octet-stream"
}

fn parse_path(req: String): String {
    let sp1: i32 = str_find(req, " ")
    if sp1 < 0 {
        return "/index.html"
    }
    let rest: String = str_slice(req, sp1 + 1, str_len(req))
    let sp2: i32 = str_find(rest, " ")
    let mut path: String = ""
    if sp2 < 0 {
        path = rest
    } else {
        path = str_slice(rest, 0, sp2)
    }
    if str_eq(path, "/") {
        path = "/index.html"
    }
    return path
}

fn serve(fd: i32, full: String, path: String): i32 {
    let ffd: i32 = cache_open(full)
    if ffd < 0 {
        send_str(fd, "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n")
        return 0
    }
    let size: i32 = cache_size(full)
    let mime: String = mime_of(path)
    sb_new()
    sb_push("HTTP/1.1 200 OK\r\n")
    sb_push("Content-Type: ")
    sb_push(mime)
    sb_push("\r\nContent-Length: ")
    sb_push(int_to_str(size))
    sb_push("\r\nConnection: keep-alive\r\n\r\n")
    send_str(fd, sb_str())
    sendfile_fd(fd, ffd, size)
    return 0
}

fn main(): i32 {
    let mut docroot: String = "webroot"
    let mut port: i32 = 28082
    let mut workers: i32 = 1
    let mut got_doc: i32 = 0
    let mut got_port: i32 = 0
    let mut ai: i32 = 1
    while ai < argc() {
        let a: String = argv(ai)
        if str_eq(a, "-w") {
            ai = ai + 1
            if ai < argc() {
                workers = str_to_int(argv(ai))
            }
        } else {
            if got_doc == 0 {
                docroot = a
                got_doc = 1
            } else {
                if got_port == 0 {
                    port = str_to_int(a)
                    got_port = 1
                }
            }
        }
        ai = ai + 1
    }
    if workers < 1 {
        workers = 1
    }
    // Prefork worker pool (nginx model): fork BEFORE listen so each worker
    // creates its OWN socket on the shared port (SO_REUSEPORT) — the kernel
    // spreads incoming connections across the N worker sockets (one acceptor
    // woken per connection, no thundering herd). The parent is worker 0.
    if workers > 1 {
        let mut wi: i32 = 1
        while wi < workers {
            let pid: i32 = fork()
            if pid == 0 {
                break
            }
            wi = wi + 1
        }
    }
    let listen_fd: i32 = tcp_listen_reuseport(port)
    set_nonblock(listen_fd)
    epoll_create()
    epoll_add(listen_fd)
    while true {
        let fd: i32 = epoll_wait(-1)
        if fd == listen_fd {
            while true {
                let client: i32 = accept(listen_fd)
                if client < 0 {
                    break
                }
                // Non-blocking client: fast event loop. Large file bodies go out
                // via sendfile_fd which retries on EAGAIN (completes in full), so
                // non-blocking no longer truncates responses. TCP_NODELAY avoids
                // the Nagle + delayed-ACK 40ms stall (headers + sendfile body are
                // two sends; without NODELAY the second waits for the first's ACK).
                set_nonblock(client)
                set_nodelay(client)
                epoll_add(client)
            }
        } else {
            let req: String = recv_str(fd)
            if str_len(req) == 0 {
                epoll_del(fd)
                close_fd(fd)
            } else {
                let path: String = parse_path(req)
                let full: String = str_concat(docroot, path)
                serve(fd, full, path)
            }
        }
    }
    return 0
}
