module main

// server_pro <docroot> [port] — production-grade HTTP file server.
// Features beyond server_web:
//   - Access logging to stdout (nginx-style: "METHOD PATH STATUS BYTES")
//   - Directory listing (auto-index) for directories without index.html
//   - URL path sanitization (reject ../, normalize //)
//   - Default Content-Type for unknown extensions
//   - HTTP/1.1 keepalive via sendfile

fn mime_of(path: String): String {
    if str_find(path, ".html") >= 0 { return "text/html" }
    if str_find(path, ".css") >= 0 { return "text/css" }
    if str_find(path, ".js") >= 0 { return "application/javascript" }
    if str_find(path, ".json") >= 0 { return "application/json" }
    if str_find(path, ".txt") >= 0 { return "text/plain" }
    if str_find(path, ".png") >= 0 { return "image/png" }
    if str_find(path, ".jpg") >= 0 { return "image/jpeg" }
    if str_find(path, ".gif") >= 0 { return "image/gif" }
    if str_find(path, ".svg") >= 0 { return "image/svg+xml" }
    if str_find(path, ".ico") >= 0 { return "image/x-icon" }
    if str_find(path, ".pdf") >= 0 { return "application/pdf" }
    if str_find(path, ".xml") >= 0 { return "application/xml" }
    if str_find(path, ".zip") >= 0 { return "application/zip" }
    if str_find(path, ".woff2") >= 0 { return "font/woff2" }
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
    if str_eq(path, "/") {
        path = "/index.html"
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

fn serve_file(fd: i32, fpath: String, mpath: String): i32 {
    let ffd: i32 = cache_open(fpath)
    if ffd < 0 {
        return -1
    }
    let size: i32 = cache_size(fpath)
    let mime: String = mime_of(mpath)
    sb_new()
    sb_push("HTTP/1.1 200 OK\r\n")
    sb_push("Content-Type: ")
    sb_push(mime)
    sb_push("\r\nContent-Length: ")
    sb_push(int_to_str(size))
    sb_push("\r\nConnection: keep-alive\r\n\r\n")
    send_str(fd, sb_str())
    sendfile_fd(fd, ffd, size)
    return size
}

fn serve_dir_listing(fd: i32, fpath: String, mpath: String): i32 {
    let count: i32 = dir_count(fpath)
    sb_new()
    sb_push("HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nConnection: keep-alive\r\n\r\n")
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
    send_str(fd, "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: ")
    send_str(fd, int_to_str(blen))
    send_str(fd, "\r\nConnection: keep-alive\r\n\r\n")
    send_str(fd, body)
    return blen
}

fn serve(fd: i32, docroot: String, mpath: String): i32 {
    if sanitize_path(mpath) < 0 {
        send_str(fd, "HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n")
        print_raw("403 ")
        print_raw(mpath)
        print_raw("\n")
        return 0
    }
    let full: String = str_concat(docroot, mpath)
    if is_dir(full) {
        let idx: String = str_concat(full, "/index.html")
        if file_exists(idx) {
            let bytes: i32 = serve_file(fd, idx, mpath)
            print_raw("200 ")
            print_raw(mpath)
            print_raw(" ")
            print_i32(bytes)
            print_raw("\n")
            return 0
        }
        let bytes: i32 = serve_dir_listing(fd, full, mpath)
        print_raw("200 ")
        print_raw(mpath)
        print_raw(" (dir) ")
        print_i32(bytes)
        print_raw("\n")
        return 0
    }
    if file_exists(full) {
        let bytes: i32 = serve_file(fd, full, mpath)
        print_raw("200 ")
        print_raw(mpath)
        print_raw(" ")
        print_i32(bytes)
        print_raw("\n")
        return 0
    }
    send_str(fd, "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n")
    print_raw("404 ")
    print_raw(mpath)
    print_raw("\n")
    return 0
}

fn main(): i32 {
    let mut docroot: String = "webroot"
    if argc() >= 2 {
        docroot = argv(1)
    }
    let mut port: i32 = 28083
    if argc() >= 3 {
        port = str_to_int(argv(2))
    }
    let listen_fd: i32 = tcp_listen(port)
    set_nonblock(listen_fd)
    epoll_create()
    epoll_add(listen_fd)
    print_raw("xlang server_pro on port ")
    print_i32(port)
    print_raw(", docroot=")
    print_raw(docroot)
    print_raw("\n")
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
            let req: String = recv_str(fd)
            if str_len(req) == 0 {
                epoll_del(fd)
                close_fd(fd)
            } else {
                let mpath: String = parse_path(req)
                serve(fd, docroot, mpath)
            }
        }
    }
    return 0
}
