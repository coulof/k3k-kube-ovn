#!/usr/bin/env bash
# File: manifests/egress-gateway-experiment/setup-webhook.sh
# Purpose: Generate TLS certificates, run python admission webhook as systemd service, and register k8s webhook
set -eux -o pipefail

# 1. Prepare directory structure inside the VM
mkdir -p /tmp/webhook-certs
cd /tmp/webhook-certs

# 2. Generate self-signed CA and Server Certificate
openssl genrsa -out ca.key 2048
openssl req -new -x509 -key ca.key -out ca.crt -subj "/CN=Tenant Admission Webhook CA" -days 3650

openssl genrsa -out webhook.key 2048
openssl req -new -key webhook.key -out webhook.csr -subj "/CN=192.168.106.2" -config <(cat <<EOF
[req]
req_extensions = v3_req
distinguished_name = req_distinguished_name
[req_distinguished_name]
[v3_req]
subjectAltName = IP:192.168.106.2
EOF
)

openssl x509 -req -in webhook.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out webhook.crt -days 3650 -extensions v3_req -extfile <(cat <<EOF
[v3_req]
subjectAltName = IP:192.168.106.2
EOF
)

# 3. Secure certificate folder
mkdir -p /etc/webhook/certs
cp ca.crt webhook.crt webhook.key /etc/webhook/certs/
chmod 600 /etc/webhook/certs/*

# 4. Copy the webhook python code into place
PROJECT_DIR=$(find /Users /home -maxdepth 6 -type d -not -path "*/.*" -name "k3k-kube-ovn" 2>/dev/null | head -n 1 || true)
cp "${PROJECT_DIR}/manifests/egress-gateway-experiment/webhook.py" /usr/local/bin/webhook.py
chmod +x /usr/local/bin/webhook.py

# 5. Define and start the systemd service
cat <<'EOF' > /etc/systemd/system/tenant-admission-webhook.service
[Unit]
Description=Tenant Admission Webhook for k3k + Kube-OVN
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 -u /usr/local/bin/webhook.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now tenant-admission-webhook.service

# 6. Generate the ValidatingWebhookConfiguration
CA_BUNDLE_B64=$(cat ca.crt | base64 | tr -d '\n')

cat <<EOF > /tmp/webhook-certs/webhook-config.yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingWebhookConfiguration
metadata:
  name: tenant-admission-webhook
webhooks:
  - name: tenant-validator.kube-system.svc
    rules:
      - apiGroups: [""]
        apiVersions: ["v1"]
        operations: ["CREATE", "UPDATE"]
        resources: ["pods"]
        scope: "Namespaced"
    clientConfig:
      url: "https://192.168.106.2:8443/validate"
      caBundle: "${CA_BUNDLE_B64}"
    admissionReviewVersions: ["v1"]
    sideEffects: None
    timeoutSeconds: 10
    failurePolicy: Fail
    namespaceSelector:
      matchLabels:
        kubernetes.io/metadata.name: "k3k-kube-ovn-cluster"
EOF

# 7. Apply the webhook configuration to the host RKE2 cluster
export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
export PATH=$PATH:/var/lib/rancher/rke2/bin

kubectl apply -f /tmp/webhook-certs/webhook-config.yaml

echo "Tenant Admission Webhook successfully configured and deployed!"
