#!/usr/bin/env python3
# Minimal WebSocket echo server for the DevTools test page (unfragmented frames).
# python3 scripts/devtools-test/ws_echo.py  ->  ws://127.0.0.1:8765
import base64
import hashlib
import socketserver
import struct
import sys

GUID = b'258EAFA5-E914-47DA-95CA-C5AB0DC85B11'


class Echo(socketserver.BaseRequestHandler):
    def read(self, n):
        data = b''
        while len(data) < n:
            chunk = self.request.recv(n - len(data))
            if not chunk:
                return b''
            data += chunk
        return data

    def handle(self):
        data = b''
        while b'\r\n\r\n' not in data:
            chunk = self.request.recv(4096)
            if not chunk:
                return
            data += chunk
        key = next(line.split(b':', 1)[1].strip() for line in data.split(b'\r\n')
                   if line.lower().startswith(b'sec-websocket-key'))
        accept = base64.b64encode(hashlib.sha1(key + GUID).digest())
        self.request.sendall(b'HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n'
                             b'Connection: Upgrade\r\nSec-WebSocket-Accept: ' + accept + b'\r\n\r\n')
        while True:
            head = self.read(2)
            if not head:
                return
            opcode, length = head[0] & 0x0F, head[1] & 0x7F
            if length == 126:
                length = struct.unpack('>H', self.read(2))[0]
            elif length == 127:
                length = struct.unpack('>Q', self.read(8))[0]
            mask = self.read(4)
            payload = bytes(b ^ mask[i % 4] for i, b in enumerate(self.read(length)))
            if opcode == 8:
                self.request.sendall(b'\x88\x00')
                return
            reply = ('echo: ' + payload.decode()).encode() if opcode == 1 else payload
            header = bytes([0x80 | opcode])
            header += bytes([len(reply)]) if len(reply) < 126 else b'\x7e' + struct.pack('>H', len(reply))
            self.request.sendall(header + reply)


socketserver.ThreadingTCPServer.allow_reuse_address = True
with socketserver.ThreadingTCPServer(('127.0.0.1', int(sys.argv[1]) if len(sys.argv) > 1 else 8765), Echo) as server:
    server.serve_forever()
