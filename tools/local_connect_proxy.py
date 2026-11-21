import socket, threading, sys

UPSTREAM_IP = sys.argv[2] if len(sys.argv) > 2 else "140.82.112.4"
PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8899


def pipe(src, dst):
    try:
        while True:
            data = src.recv(65536)
            if not data:
                break
            dst.sendall(data)
    except Exception:
        pass
    finally:
        for s in (src, dst):
            try:
                s.close()
            except Exception:
                pass


def handle(client):
    try:
        request = b""
        while b"\r\n\r\n" not in request:
            chunk = client.recv(4096)
            if not chunk:
                client.close()
                return
            request += chunk
            if len(request) > 8192:
                break

        line = request.split(b"\r\n")[0].decode("latin-1")
        method, target = line.split(" ")[0], line.split(" ")[1]
        if method.upper() != "CONNECT":
            client.sendall(b"HTTP/1.1 405 Method Not Allowed\r\n\r\n")
            client.close()
            return

        host, _, port = target.partition(":")
        port = int(port or 443)

        upstream = socket.create_connection((UPSTREAM_IP, port), timeout=15)
        client.sendall(b"HTTP/1.1 200 Connection Established\r\n\r\n")

        threading.Thread(target=pipe, args=(client, upstream), daemon=True).start()
        threading.Thread(target=pipe, args=(upstream, client), daemon=True).start()
    except Exception:
        try:
            client.close()
        except Exception:
            pass


def main():
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(("127.0.0.1", PORT))
    server.listen(32)
    print("proxy listening on 127.0.0.1:%d -> %s" % (PORT, UPSTREAM_IP), flush=True)
    while True:
        client, _ = server.accept()
        threading.Thread(target=handle, args=(client,), daemon=True).start()


if __name__ == "__main__":
    main()
