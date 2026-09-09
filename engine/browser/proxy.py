"""HTTPS CONNECT proxy that pins every connection to a validated public address."""
import select
import socket
import socketserver
import threading
from engine.integrations.web import destination

class Tunnel(socketserver.StreamRequestHandler):
    def handle(self):
        remote=None
        try:
            self.connection.settimeout(15)
            method,target,_=self.rfile.readline(8192).decode('ascii').split()
            for _ in range(100):
                if self.rfile.readline(8192) in (b'\r\n',b'\n',b''):break
            else:raise ValueError('Headers too long')
            if method!='CONNECT':raise ValueError('HTTPS only')
            _,_,port,address=destination('https://'+target)
            if port!=443:raise ValueError('HTTPS only')
            remote=socket.create_connection((address,port),10)
            self.wfile.write(b'HTTP/1.1 200 Connection established\r\n\r\n');self.wfile.flush()
            while True:
                readable,_,_=select.select([self.connection,remote],[],[],60)
                if not readable:break
                for source in readable:
                    data=source.recv(65536)
                    if not data:return
                    (remote if source is self.connection else self.connection).sendall(data)
        except Exception:
            try:self.wfile.write(b'HTTP/1.1 403 Forbidden\r\nConnection: close\r\n\r\n')
            except OSError:pass
        finally:
            if remote:remote.close()

class Proxy(socketserver.ThreadingTCPServer):
    allow_reuse_address=True
    daemon_threads=True
    def __init__(self):
        super().__init__(('127.0.0.1',0),Tunnel)
        threading.Thread(target=self.serve_forever,daemon=True).start()
    @property
    def url(self):return 'http://127.0.0.1:'+str(self.server_address[1])
