module main

// server_http <docroot> [port] [-w N] [-c <conf>] — HTTP/1.1 file server with
// method routing, Range/partial-content (206), HEAD, POST/PUT upload, DELETE,
// keep-alive. `-w N` runs an N-process prefork worker pool (SO_REUSEPORT, the
// nginx multi-worker model — kernel load-balances connections across workers).
// `-c <conf>` is config-driven (nginx-style directives: root/listen/index;);
// otherwise the positional <docroot> [port] form is used.
//
// Beyond server_pro:
//   - Parses the request line into METHOD / PATH / VERSION.
//   - Header lookup (Host, Connection, Range) via header_value().
//   - GET serves the body; HEAD serves headers only (Content-Length correct, no body).
//   - POST writes the request body to docroot+path (201 Created) — a minimal upload.
//   - PUT idempotently writes (create/replace, 200 OK); DELETE removes a file (200/404).
//   - Range: bytes=... → 206 Partial Content + Content-Range (sendfile_range).
//   - Conditional requests: ETag (size-mtime) + If-None-Match → 304 Not Modified.
//   - GET/HEAD/POST/PUT/DELETE allowed → otherwise 405 Method Not Allowed.
//   - OPTIONS → 204 No Content with CORS preflight headers (browser fetch support).
//   - Access-Control-Allow-Origin: * on data responses, so browser frontends can
//     fetch cross-origin.
//   - Directory redirect: GET /dir → 301 Moved Permanently → /dir/ (so relative
//     links in an index/ listing resolve correctly — standard nginx/httpd).
//   - 404 Not Found, 403 Forbidden (path traversal), 416-style → 200 full on bad range.
//   - Access log to stdout: "METHOD PATH STATUS BYTES" (redirect to /dev/null when benching).

struct Range {
    start: i32
    length: i32
    ok: i32
}

// ETag from size + mtime (changes when content or modification time changes).
// Unquoted for simple round-trip comparison against If-None-Match.
fn etag_of(fpath: String): String {
    let sz: i32 = stat_field(fpath, 4)
    let mt: i32 = stat_field(fpath, 5)
    return int_to_str(sz) + "-" + int_to_str(mt)
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

// First whitespace-delimited token of the request line = method.
fn parse_method(req: String): String {
    let sp: i32 = str_find(req, " ")
    if sp < 0 { return "" }
    return str_slice(req, 0, sp)
}

// Request body = everything after the blank line ("\r\n\r\n") separating
// headers from body. recv_str reads one recv() (up to 64 KiB), so for small
// POST bodies (headers + body in one packet) this captures the full body.
fn parse_body(req: String): String {
    let idx: i32 = str_find(req, "\r\n\r\n")
    if idx < 0 { return "" }
    return str_slice(req, idx + 4, str_len(req))
}

// Path = token between first and second space; "/<index_file>" for "/".
fn parse_path(req: String, index_file: String): String {
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
        path = "/" + index_file
    }
    return path
}

fn sanitize_path(path: String): i32 {
    let n: i32 = str_len(path)
    let mut i: i32 = 0
    while i + 2 < n {
        if str_char_at(path, i) == 46 {
            if str_char_at(path, i + 1) == 46 {
                return -1
            }
        }
        i = i + 1
    }
    return 0
}

// Look up a header by its full key including the colon (e.g. "Range:").
// Case-sensitive (matches common client casing). Returns the trimmed value,
// or "" if absent. Callers pass the colon-suffixed key to avoid a per-request
// str_concat allocation on the hot path.
fn header_value(req: String, key: String): String {
    let k: i32 = str_find(req, key)
    if k < 0 { return "" }
    let n: i32 = str_len(req)
    let mut v: i32 = k + str_len(key)
    while v < n {
        let c: i32 = str_char_at(req, v)
        if c == 32 { v = v + 1 } else { break }
    }
    let mut ve: i32 = v
    while ve < n {
        let c: i32 = str_char_at(req, ve)
        if c == 13 { break }
        if c == 10 { break }
        ve = ve + 1
    }
    return str_slice(req, v, ve)
}

// Parse "bytes=start-end" / "bytes=start-" / "bytes=-suffix" against file size.
// Returns Range { ok:1, start, length } or { ok:0 } if not a single byte-range.
fn parse_range(range_hdr: String, size: i32): Range {
    let mut r: Range = Range { start: 0, length: size, ok: 0 }
    let eq: i32 = str_find(range_hdr, "=")
    if eq < 0 { return r }
    let spec: String = str_slice(range_hdr, eq + 1, str_len(range_hdr))
    let dash: i32 = str_find(spec, "-")
    if dash < 0 { return r }
    let left: String = str_slice(spec, 0, dash)
    let right: String = str_slice(spec, dash + 1, str_len(spec))
    if str_len(left) == 0 {
        let n: i32 = str_to_int(right)
        if n <= 0 { return r }
        if n >= size {
            r.start = 0
            r.length = size
        } else {
            r.start = size - n
            r.length = n
        }
        r.ok = 1
        return r
    }
    let s: i32 = str_to_int(left)
    if s < 0 { return r }
    if s >= size { return r }
    if str_len(right) == 0 {
        r.start = s
        r.length = size - s
    } else {
        let e: i32 = str_to_int(right)
        if e < s { return r }
        if e >= size - 1 {
            r.length = size - s
        } else {
            r.length = e - s + 1
        }
        r.start = s
    }
    r.ok = 1
    return r
}

fn log_line(method: String, path: String, status: i32, bytes: i32): i32 {
    print_raw(method)
    print_raw(" ")
    print_raw(path)
    print_raw(" ")
    print_raw(int_to_str(status))
    print_raw(" ")
    print_raw(int_to_str(bytes))
    print_raw("\n")
    return 0
}

// Serve a file: full (200) or partial (206) if range_hdr is satisfiable.
// head_only=1 → send headers with correct Content-Length, no body.
// Builds the entire header block in ONE sb pass (sb_str() returns a pointer
// into the shared buffer, so we must consume it before any sb_new()/sb_push()).
fn serve_file(fd: i32, fpath: String, mpath: String, head_only: i32, range_hdr: String, inm: String, ims: String): i32 {
    let ffd: i32 = cache_open(fpath)
    if ffd < 0 { return -1 }
    let size: i32 = cache_size(fpath)
    let mime: String = mime_of(mpath)
    let etag: String = etag_of(fpath)
    let lastmod: String = fmt_http_date(stat_field(fpath, 5))
    // Conditional request: If-None-Match (ETag) → 304.
    if str_len(inm) > 0 {
        if str_eq(inm, etag) == 1 {
            send_str(fd, "HTTP/1.1 304 Not Modified\r\nETag: ")
            send_str(fd, etag)
            send_str(fd, "\r\nAccess-Control-Allow-Origin: *\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n")
            return -2
        }
    }
    // Conditional request: If-Modified-Since (Last-Modified) → 304.
    if str_len(ims) > 0 {
        if str_eq(ims, lastmod) == 1 {
            send_str(fd, "HTTP/1.1 304 Not Modified\r\nETag: ")
            send_str(fd, etag)
            send_str(fd, "\r\nLast-Modified: ")
            send_str(fd, lastmod)
            send_str(fd, "\r\nAccess-Control-Allow-Origin: *\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n")
            return -2
        }
    }
    let mut off: i32 = 0
    let mut send_len: i32 = size
    let mut is_206: i32 = 0
    if str_len(range_hdr) > 0 {
        let rg: Range = parse_range(range_hdr, size)
        if rg.ok == 1 {
            is_206 = 1
            off = rg.start
            send_len = rg.length
        }
    }
    sb_new()
    if is_206 == 1 {
        sb_push("HTTP/1.1 206 Partial Content")
    } else {
        sb_push("HTTP/1.1 200 OK")
    }
    sb_push("\r\nContent-Type: ")
    sb_push(mime)
    sb_push("\r\nContent-Length: ")
    sb_push(int_to_str(send_len))
    sb_push("\r\nETag: ")
    sb_push(etag)
    sb_push("\r\nLast-Modified: ")
    sb_push(lastmod)
    if is_206 == 1 {
        sb_push("\r\nContent-Range: bytes ")
        sb_push(int_to_str(off))
        sb_push("-")
        sb_push(int_to_str(off + send_len - 1))
        sb_push("/")
        sb_push(int_to_str(size))
    }
    sb_push("\r\nAccess-Control-Allow-Origin: *")
    sb_push("\r\nConnection: keep-alive\r\n\r\n")
    send_str(fd, sb_str())
    if head_only == 0 {
        if off == 0 {
            sendfile_fd(fd, ffd, send_len)
        } else {
            sendfile_range(fd, ffd, off, send_len)
        }
    }
    return send_len
}

fn serve_dir_listing(fd: i32, fpath: String, mpath: String, head_only: i32): i32 {
    let count: i32 = dir_count(fpath)
    sb_new()
    sb_push("<html><head><title>Index of ")
    sb_push(mpath)
    sb_push("</title></head><body><h1>Index of ")
    sb_push(mpath)
    sb_push("</h1><ul>")
    let mut i: i32 = 0
    while i < count {
        let name: String = dir_entry(fpath, i)
        if str_len(name) > 0 {
            if str_char_at(name, 0) != 46 {
                sb_push("<li><a href=\"")
                sb_push(name)
                sb_push("\">")
                sb_push(name)
                sb_push("</a></li>")
            }
        }
        i = i + 1
    }
    sb_push("</ul></body></html>")
    let body: String = sb_str()
    let blen: i32 = str_len(body)
    send_str(fd, "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nAccess-Control-Allow-Origin: *\r\nContent-Length: ")
    send_str(fd, int_to_str(blen))
    send_str(fd, "\r\nConnection: keep-alive\r\n\r\n")
    if head_only == 0 {
        send_str(fd, body)
    }
    return blen
}

fn handle(fd: i32, docroot: String, req: String, index_file: String): i32 {
    let mpath: String = parse_path(req, index_file)
    // Prefix-check the method (avoids a per-request str_slice for routing).
    let is_get: i32 = str_starts_with(req, "GET ")
    let is_head: i32 = str_starts_with(req, "HEAD ")
    let is_post: i32 = str_starts_with(req, "POST ")
    let is_put: i32 = str_starts_with(req, "PUT ")
    let is_del: i32 = str_starts_with(req, "DELETE ")
    let is_options: i32 = str_starts_with(req, "OPTIONS ")
    // POST: write the request body to docroot+path → 201 Created (upload).
    // Path traversal blocked by sanitize_path (same as GET).
    if is_post == 1 {
        if sanitize_path(mpath) < 0 {
            send_str(fd, "HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n")
            log_line("POST", mpath, 403, 0)
            return 0
        }
        let body: String = parse_body(req)
        let target: String = str_concat(docroot, mpath)
        write_file(target, body)
        let blen: i32 = str_len(body)
        send_str(fd, "HTTP/1.1 201 Created\r\nContent-Type: text/plain\r\nContent-Length: ")
        send_str(fd, int_to_str(blen))
        send_str(fd, "\r\nConnection: keep-alive\r\n\r\n")
        send_str(fd, body)
        log_line("POST", mpath, 201, blen)
        return 0
    }
    // PUT: idempotent write → 200 OK (create/replace).
    if is_put == 1 {
        if sanitize_path(mpath) < 0 {
            send_str(fd, "HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n")
            log_line("PUT", mpath, 403, 0)
            return 0
        }
        let body: String = parse_body(req)
        let target: String = str_concat(docroot, mpath)
        write_file(target, body)
        let blen: i32 = str_len(body)
        send_str(fd, "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: ")
        send_str(fd, int_to_str(blen))
        send_str(fd, "\r\nConnection: keep-alive\r\n\r\n")
        send_str(fd, body)
        log_line("PUT", mpath, 200, blen)
        return 0
    }
    // DELETE: remove the file (404 if absent). Directories are not removed.
    if is_del == 1 {
        if sanitize_path(mpath) < 0 {
            send_str(fd, "HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n")
            log_line("DELETE", mpath, 403, 0)
            return 0
        }
        let target: String = str_concat(docroot, mpath)
        if file_exists(target) {
            if is_dir(target) {
                send_str(fd, "HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n")
                log_line("DELETE", mpath, 403, 0)
                return 0
            }
            remove_file(target)
            send_str(fd, "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 8\r\nConnection: keep-alive\r\n\r\ndeleted\n")
            log_line("DELETE", mpath, 200, 0)
        } else {
            send_str(fd, "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n")
            log_line("DELETE", mpath, 404, 0)
        }
        return 0
    }
    // OPTIONS: CORS preflight — advertise allowed methods/headers so browser
    // frontends can fetch cross-origin. 204 No Content, no body, handled before
    // any resource lookup (a preflight is about the resource's capabilities).
    if is_options == 1 {
        send_str(fd, "HTTP/1.1 204 No Content\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Methods: GET, HEAD, POST, PUT, DELETE, OPTIONS\r\nAccess-Control-Allow-Headers: *\r\nAccess-Control-Max-Age: 86400\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n")
        log_line("OPTIONS", mpath, 204, 0)
        return 0
    }
    if is_get == 0 {
        if is_head == 0 {
            let m: String = parse_method(req)
            send_str(fd, "HTTP/1.1 405 Method Not Allowed\r\nAllow: GET, HEAD, POST, PUT, DELETE, OPTIONS\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n")
            log_line(m, mpath, 405, 0)
            return 0
        }
    }
    let mut head_only: i32 = 0
    let mut mlabel: String = "GET"
    if is_head == 1 {
        head_only = 1
        mlabel = "HEAD"
    }
    if sanitize_path(mpath) < 0 {
        send_str(fd, "HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n")
        log_line(mlabel, mpath, 403, 0)
        return 0
    }
    let full: String = str_concat(docroot, mpath)
    let range_hdr: String = header_value(req, "Range:")
    let inm: String = header_value(req, "If-None-Match:")
    let ims: String = header_value(req, "If-Modified-Since:")
    if is_dir(full) {
        // Redirect "/dir" -> "/dir/" (301) so relative links in an index or
        // listing resolve against the directory — standard nginx/httpd behavior.
        // Skip when the path already ends in "/".
        if str_char_at(mpath, str_len(mpath) - 1) != 47 {
            send_str(fd, "HTTP/1.1 301 Moved Permanently\r\nLocation: ")
            send_str(fd, mpath)
            send_str(fd, "/\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n")
            log_line(mlabel, mpath, 301, 0)
            return 0
        }
        let idx: String = str_concat(full, str_concat("/", index_file))
        if file_exists(idx) {
            let n: i32 = serve_file(fd, idx, mpath, head_only, range_hdr, inm, ims)
            if n == -2 {
                log_line(mlabel, mpath, 304, 0)
                return 0
            }
            let mut code: i32 = 200
            if str_len(range_hdr) > 0 { code = 206 }
            log_line(mlabel, mpath, code, n)
            return 0
        }
        let n: i32 = serve_dir_listing(fd, full, mpath, head_only)
        log_line(mlabel, mpath, 200, n)
        return 0
    }
    if file_exists(full) {
        let n: i32 = serve_file(fd, full, mpath, head_only, range_hdr, inm, ims)
        if n == -1 {
            send_str(fd, "HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\n\r\n")
            log_line(mlabel, mpath, 500, 0)
            return 0
        }
        if n == -2 {
            log_line(mlabel, mpath, 304, 0)
            return 0
        }
        let mut code: i32 = 200
        if str_len(range_hdr) > 0 { code = 206 }
        log_line(mlabel, mpath, code, n)
        return 0
    }
    send_str(fd, "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n")
    log_line(mlabel, mpath, 404, 0)
    return 0
}

// Is `req` a complete HTTP/1.1 request — full headers AND Content-Length bytes
// of body? 1 = complete (ready to handle), 0 = need more data, 2 = too large
// (Content-Length exceeds the 16 MiB cap → caller sends 413). Drives the
// per-connection accumulation loop in main: a POST body can arrive in a TCP
// segment AFTER the headers, so we buffer per fd until this returns 1.
fn request_complete(req: String): i32 {
    let sep: i32 = str_find(req, "\r\n\r\n")
    if sep < 0 { return 0 }
    let cl: String = header_value(req, "Content-Length:")
    if str_len(cl) == 0 { return 1 }
    let need: i32 = str_to_int(cl)
    if need > 16777216 { return 2 }
    let body: i32 = str_len(req) - (sep + 4)
    if body >= need { return 1 }
    return 0
}

// Server configuration parsed from a -c <conf> file (nginx-style, one
// "directive value;" per line, '#' comments). Unset directives keep defaults.
struct Config {
    root: String
    listen: i32
    index: String
}

// Parse a config file into a Config. Directives: `root <dir>;`, `listen <port>;`,
// `index <file>;`. Lines starting with '#' are comments. Whitespace and a
// trailing ';' on the value are tolerated. Pure (no sockets) — testable locally.
fn parse_conf(path: String): Config {
    let mut c: Config = Config { root: ".", listen: 8080, index: "index.html" }
    let s: String = read_file(path)
    let lines: Vec<String> = str_split(str_trim(s), "\n")
    let n: i32 = vec_len(lines)
    let mut i: i32 = 0
    while i < n {
        let line: String = str_trim(lines[i])
        if str_len(line) > 0 {
            if str_char_at(line, 0) != 35 {
                let sp: i32 = str_find(line, " ")
                if sp > 0 {
                    let key: String = str_slice(line, 0, sp)
                    let mut val: String = str_trim(str_slice(line, sp + 1, str_len(line)))
                    if str_len(val) > 0 {
                        if str_char_at(val, str_len(val) - 1) == 59 {
                            val = str_slice(val, 0, str_len(val) - 1)
                        }
                    }
                    if key == "root" { c.root = val }
                    if key == "listen" { c.listen = str_to_int(val) }
                    if key == "index" { c.index = val }
                }
            }
        }
        i += 1
    }
    return c
}

fn main(): i32 {
    let mut docroot: String = "webroot"
    let mut port: i32 = 28084
    let mut index_file: String = "index.html"
    // `-c <conf>`: config-driven (root/listen/index from a file). Otherwise the
    // positional `<docroot> [port]` form is used (backwards-compatible).
    let mut conf_path: String = ""
    let mut workers: i32 = 1
    let mut ai: i32 = 1
    while ai < argc() {
        if argv(ai) == "-c" {
            if ai + 1 < argc() {
                conf_path = argv(ai + 1)
                ai += 1
            }
        }
        if argv(ai) == "-w" {
            if ai + 1 < argc() {
                workers = str_to_int(argv(ai + 1))
                ai += 1
            }
        }
        ai += 1
    }
    if str_len(conf_path) > 0 {
        let c: Config = parse_conf(conf_path)
        docroot = c.root
        port = c.listen
        index_file = c.index
    } else {
        if argc() >= 2 { docroot = argv(1) }
        if argc() >= 3 { port = str_to_int(argv(2)) }
    }
    print_raw("xlang server_http on port ")
    print_raw(int_to_str(port))
    print_raw(", docroot=")
    print_raw(docroot)
    if workers > 1 {
        print_raw(", workers=")
        print_raw(int_to_str(workers))
    }
    print_raw("\n")
    // Prefork worker pool (nginx model). Fork BEFORE creating the listen socket
    // so each worker creates its OWN socket on the shared port — true SO_REUSEPORT
    // load-balancing (the kernel hashes each connection to one worker's socket,
    // no thundering herd of all workers waking per connection). The parent is
    // worker 0. workers==1 skips the fork (single process).
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
    // Each worker creates its own listen socket. With workers>1 every worker
    // sets SO_REUSEPORT and binds the same port, so the kernel spreads incoming
    // connections across the N sockets (one acceptor woken per connection).
    let mut listen_fd: i32 = 0
    if workers > 1 {
        listen_fd = tcp_listen_reuseport(port)
    } else {
        listen_fd = tcp_listen(port)
    }
    set_nonblock(listen_fd)
    // Each worker (parent + children) runs its own epoll loop on the shared port.
    epoll_create()
    epoll_add(listen_fd)
    // Per-fd request accumulation buffer, for multi-segment POSTs (body can
    // arrive in a TCP segment after the headers). Indexed by fd; fds are small
    // ints, so pre-fill a cap. Grow here if you raise ulimit -n past 4096.
    let bufs: Vec<String> = vec_new()
    let mut bi: i32 = 0
    while bi < 4096 {
        bufs.push("")
        bi += 1
    }
    while true {
        let fd: i32 = epoll_wait(-1)
        if fd == listen_fd {
            while true {
                let client: i32 = accept(listen_fd)
                if client < 0 {
                    break
                }
                set_nonblock(client)
                set_nodelay(client)
                epoll_add(client)
            }
        } else {
            if fd < 4096 {
                // Drain whatever is buffered now, append to this fd's buffer,
                // and handle only once the request is complete (headers +
                // Content-Length body). Incomplete → wait for the next epoll event.
                let chunk: String = recv_all(fd)
                if str_len(chunk) == 0 {
                    bufs[fd] = ""
                    epoll_del(fd)
                    close_fd(fd)
                } else {
                    bufs[fd] = str_concat(bufs[fd], chunk)
                    let rc: i32 = request_complete(bufs[fd])
                    if rc == 1 {
                        handle(fd, docroot, bufs[fd], index_file)
                        bufs[fd] = ""
                    } else {
                        // rc == 2 (Content-Length > 16 MiB cap) or the buffer
                        // itself overshot the cap (no/lying Content-Length) → 413
                        // Payload Too Large, drop the connection. Bounds memory
                        // against a client that claims a huge body.
                        if rc == 2 || str_len(bufs[fd]) > 16777216 {
                            send_str(fd, "HTTP/1.1 413 Payload Too Large\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
                            bufs[fd] = ""
                            epoll_del(fd)
                            close_fd(fd)
                        }
                    }
                }
            } else {
                let req: String = recv_str(fd)
                if str_len(req) == 0 {
                    epoll_del(fd)
                    close_fd(fd)
                } else {
                    handle(fd, docroot, req, index_file)
                }
            }
        }
    }
    return 0
}
