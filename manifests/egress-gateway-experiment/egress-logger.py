#!/usr/bin/env python3
# File: manifests/egress-gateway-experiment/egress-logger.py
# Purpose: Beautiful, lightweight egress-demo-control VM HTTP server to log incoming client egress IPs

import http.server
import socketserver

class LoggerHandler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        client_ip = self.client_address[0]
        # Highlight our expected egress IPs
        if client_ip == "192.168.105.70":
            colored_ip = f"\033[1;32m{client_ip} (🟢 Tenant A Egress)\033[0m"
        elif client_ip == "192.168.105.80":
            colored_ip = f"\033[1;36m{client_ip} (🔵 Tenant B Egress)\033[0m"
        else:
            colored_ip = f"\033[1;33m{client_ip} (Default VM IP / Host)\033[0m"

        # Parse query parameters for pod name and local IP
        from urllib.parse import urlparse, parse_qs
        query = parse_qs(urlparse(self.path).query)
        pod_name = query.get("pod", [""])[0]
        pod_ip = query.get("ip", [""])[0]

        pod_info = ""
        if pod_name or pod_ip:
            pod_info = f" | Pod: \033[1;35m{pod_name}\033[0m (Local IP: \033[1;34m{pod_ip}\033[0m)"

        print(f"[📥 EGRESS CONNECTION] client_address: {colored_ip}{pod_info}")
        
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.end_headers()
        
        resp_msg = f"Hello from egress-demo-control VM! Your egress IP is {client_ip}"
        if pod_name:
            resp_msg += f" (Hello, {pod_name}!)"
        resp_msg += "\n"
        self.wfile.write(resp_msg.encode())

    def log_message(self, format, *args):
        pass # Suppress default noisy http.server logs

socketserver.TCPServer.allow_reuse_address = True
try:
    with socketserver.TCPServer(("0.0.0.0", 8888), LoggerHandler) as httpd:
        print("\033[1;35m====================================================================\033[0m")
        print("\033[1;35m          EGRESS-DEMO-CONTROL VM IP VERIFICATION SERVER LOGS        \033[0m")
        print("\033[1;35m====================================================================\033[0m")
        print("Listening on port 8888... Press Ctrl+C to terminate.")
        print("--------------------------------------------------------------------")
        httpd.serve_forever()
except KeyboardInterrupt:
    print("\nServer shutting down. Goodbye!")
