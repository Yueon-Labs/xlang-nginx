module main

// server_gzip <docroot> [port] — HTTP/1.1 file server with gzip negotiation.
// Reads Accept-Encoding and adds Vary: Accept-Encoding to text responses.
// This is the infrastructure for gzip compression; the actual deflate step
// would call zlib (future). Without zlib, responses are served uncompressed
// but with the negotiation headers in place, so adding compression is just
// one call away.

struct Range {
    start: i32
    length: i32
    ok: i32
}

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
    if q >= 0 { path = str_slice(path, 0, q) }
    if str_eq(path, "/") { path = "/index.html" }
    return path
}

fn sanitize_path(path: String): i32 {
    let n: i32 = str_len(path)
    let mut i: i32 = 0
    while i + 2 < n {
        if path[i] == '.' {
            if path[i + 1] == '.' { return -1 }
        }
        i += 1
    }
    return 0
}

fn header_value(req: String, key: String): String {
    let k: i32 = str_find(req, key)
    if k < 0 { return "" }
    let n: i32 = str_len(req)
    let mut v: i32 = k + str_len(key)
    while v < n {
        let c: i32 = str_char_at(req, v)
        if c == ' ' { v += 1 } else { break }
    }
    let mut ve: i32 = v
    while ve < n {
        let c: i32 = str_char_at(req, ve)
        if c == '\r' { break }
        if c == '\n' { break }
        ve += 1
    }
    return str_slice(req, v, ve)
}

fn is_text_mime(mime: String): i32 {
    if str_find(mime, "text/") >= 0 { return 1 }
    if str_find(mime, "javascript") >= 0 { return 1 }
    if str_find(mime, "json") >= 0 { return 1 }
    return 0
}

fn handle(fd: i32, docroot: String, req: String): i32 {
    let mpath: String = parse_path(req)
    let is_get: i32 = str_starts_with(req, "GET ")
    let is_head: i32 = str_starts_with(req, "HEAD ")
    if is_get == 0 {
        if is_head == 0 {
            send_str(fd, "HTTP/1.1 405 Method Not Allowed\r\nAllow: GET, HEAD\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n")
            return 0
        }
    }
    if sanitize_path(mpath) < 0 {
        send_str(fd, "HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n")
        return 0
    }
    let full: String = str_concat(docroot, mpath)
    if file_exists(full) == 0 {
        send_str(fd, "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n")
        return 0
    }
    let mime: String = mime_of(mpath)
    let accept_enc: String = header_value(req, "Accept-Encoding:")
    let mut wants_gzip: i32 = 0
    if str_find(accept_enc, "gzip") >= 0 { wants_gzip = 1 }
    let mut should_compress: i32 = 0
    if wants_gzip == 1 {
        if is_text_mime(mime) == 1 { should_compress = 1 }
    }
    let data: String = read_file(full)
    let dlen: i32 = str_len(data)
    let mut head_only: i32 = 0
    if is_head == 1 { head_only = 1 }
    sb_new()
    sb_push("HTTP/1.1 200 OK")
    sb_push("\r\nContent-Type: ")
    sb_push(mime)
    sb_push("\r\nContent-Length: ")
    sb_push(int_to_str(dlen))
    if should_compress == 1 {
        sb_push("\r\nVary: Accept-Encoding")
    }
    sb_push("\r\nConnection: keep-alive\r\n\r\n")
    send_str(fd, sb_str())
    if head_only == 0 {
        send_str(fd, data)
    }
    return 0
}

fn main(): i32 {
    let mut docroot: String = "webroot"
    if argc() >= 2 { docroot = argv(1) }
    let mut port: i32 = 28099
    if argc() >= 3 { port = str_to_int(argv(2)) }
    let listen_fd: i32 = tcp_listen(port)
    set_nonblock(listen_fd)
    epoll_create()
    epoll_add(listen_fd)
    print_raw("xlang server_gzip on port ")
    print_raw(int_to_str(port))
    print_raw(", docroot=")
    print_raw(docroot)
    print_raw("\n")
    while true {
        let fd: i32 = epoll_wait(-1)
        if fd == listen_fd {
            while true {
                let client: i32 = accept(listen_fd)
                if client < 0 { break }
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
                handle(fd, docroot, req)
            }
        }
    }
    return 0
}
