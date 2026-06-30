import socket, sys
s = socket.socket(); s.connect(("127.0.0.1", 28082))
s.settimeout(5)
req = b"GET / HTTP/1.1\r\nHost: x\r\nConnection: keep-alive\r\n\r\n"
for i in range(4):
    try:
        s.sendall(req)
    except Exception as e:
        print(f"req {i+1}: send failed {e}"); break
    buf = b""
    ok = False
    try:
        while True:
            c = s.recv(4096)
            if not c:
                print(f"req {i+1}: server CLOSED connection"); break
            buf += c
            if b"\r\n\r\n" in buf and len(buf.split(b"\r\n\r\n",1)[1]) >= 52:
                ok = True; break
    except socket.timeout:
        print(f"req {i+1}: TIMEOUT waiting for body (got {len(buf)} bytes)"); break
    if ok:
        print(f"req {i+1}: OK got {len(buf)} bytes")
    else:
        break
s.close()
print("done")
