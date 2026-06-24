import ssl
import json
from http.server import HTTPServer, BaseHTTPRequestHandler

class WebhookHandler(BaseHTTPRequestHandler):
    def do_POST(self):
        content_length = int(self.headers['Content-Length'])
        post_data = self.rfile.read(content_length)
        review = json.loads(post_data)
        
        uid = review['request']['uid']
        obj = review['request']['object']
        
        # Retrieve synchronized guest pod metadata from k3k annotations
        annotations = obj.get('metadata', {}).get('annotations', {})
        guest_ns = annotations.get('k3k.io/namespace')
        logical_switch = annotations.get('ovn.kubernetes.io/logical_switch')
        
        allowed = True
        msg = "Allowed"
        
        # Enforce Tenant Isolation:
        # Prevent tenant-a workloads from accessing tenant-b logical switches/VPCs, and vice versa.
        if guest_ns and logical_switch:
            if guest_ns == "tenant-a" and "tenant-b" in logical_switch:
                allowed = False
                msg = f"Security Policy Violation: Pod originating from guest namespace '{guest_ns}' is not authorized to bind to logical switch '{logical_switch}'."
            elif guest_ns == "tenant-b" and "tenant-a" in logical_switch:
                allowed = False
                msg = f"Security Policy Violation: Pod originating from guest namespace '{guest_ns}' is not authorized to bind to logical switch '{logical_switch}'."

        response = {
            "apiVersion": "admission.k8s.io/v1",
            "kind": "AdmissionReview",
            "response": {
                "uid": uid,
                "allowed": allowed,
                "status": {
                    "code": 200 if allowed else 403,
                    "message": msg
                }
            }
        }
        
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        self.wfile.write(json.dumps(response).encode('utf-8'))

def run():
    # Bind to stable host control plane IP
    server_address = ('192.168.106.2', 8443)
    httpd = HTTPServer(server_address, WebhookHandler)
    
    # Enable SSL/TLS with self-signed keys
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(certfile='/etc/webhook/certs/webhook.crt', keyfile='/etc/webhook/certs/webhook.key')
    httpd.socket = context.wrap_socket(httpd.socket, server_side=True)
    
    print("Admission Webhook running on https://192.168.106.2:8443...")
    httpd.serve_forever()

if __name__ == '__main__':
    run()
