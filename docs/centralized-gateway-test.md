# Kube-OVN Centralized Gateway Test Guide

This guide describes how to run and verify a **Centralized Gateway** configuration using Kube-OVN on top of the host cluster VM.

---

## What is a Centralized Gateway?

In an overlay network:
1. **Distributed Gateway (Default):** Every host node acts as a gateway and forwards external-bound traffic (`natOutgoing: true`) independently using its own local network interface and routing table.
2. **Centralized Gateway:** Egress traffic from all pods mapped to the subnet is routed over OVS internal tunnels to a **single, specific host node** (designated as the `gatewayNode`). That designated node then translates and routes the traffic through its local interface.

### Why Use a Centralized Gateway?
- **Auditing & Whitelisting:** External networks only see a single, predictable host IP for all egress traffic originating from the subnet (the IP of the designated `gatewayNode`), rather than various random node IPs.
- **Controlled Egress Paths:** Restricts outbound paths to specific machines in the cluster.

---

## Test Manifests Layout

The centralized gateway test artifacts are located under:
```
manifests/centralized-gateway-test/
├── subnet.yaml           # Subnet CRD with gatewayType: centralized & gatewayNode mapping
├── namespace.yaml        # Target guest namespace on host with subnet annotation mapping
├── cluster.yaml          # k3k Virtual Cluster spec running on the isolated range
└── test-pod.yaml         # Lightweight Alpine testing container
```

---

## Execution & Verification Steps

### 1. Access the VM Shell
```bash
limactl shell k3k-kube-ovn
```

### 2. Apply the Centralized Gateway Infrastructure
Apply the subnet, namespace, and k3k virtual cluster resources:
```bash
# Deploy the centralized gateway resources
kubectl apply -f manifests/centralized-gateway-test/namespace.yaml
kubectl apply -f manifests/centralized-gateway-test/subnet.yaml
kubectl apply -f manifests/centralized-gateway-test/cluster.yaml
```

### 3. Verify Custom Subnet & Pod Ready States
Wait for k3k to spin up the virtual node control plane and confirm the active subnet mapping:
```bash
# Check that the custom centralized subnet is active (10.17.0.0/16)
kubectl get subnet k3k-kube-ovn-centralized-subnet

# Wait for k3k server and agent pods to be Running (takes ~60s)
kubectl get pods -n k3k-kube-ovn-centralized-cluster -o wide
```

### 4. Perform Egress Routing Verification

You can verify the egress routing using either Option A (applying directly on the host) or Option B (applying explicitly inside the virtual cluster itself).

---

#### Option A: Host-Level Verification
Deploy the alpine verification container directly under the guest's host namespace:

```bash
# 1. Deploy the test pod into the host-level guest namespace
kubectl apply -f manifests/centralized-gateway-test/test-pod.yaml -n k3k-kube-ovn-centralized-cluster

# 2. Check that it has been assigned an IP in the 10.17.0.0/16 range
kubectl get pod test-pod-centralized -n k3k-kube-ovn-centralized-cluster -o wide

# 3. Ping the host API server Gateway IP (10.43.0.1)
kubectl exec -it test-pod-centralized -n k3k-kube-ovn-centralized-cluster -- ping -c 3 10.43.0.1

# 4. Ping external WAN destination (8.8.8.8) to verify centralized SNAT egress
kubectl exec -it test-pod-centralized -n k3k-kube-ovn-centralized-cluster -- ping -c 3 8.8.8.8

# 5. Clean up the test workload
kubectl delete pod test-pod-centralized -n k3k-kube-ovn-centralized-cluster
```

---

#### Option B: Virtual Cluster Guest-Level Verification (Explicit)
Deploy the test pod directly **inside** the k3k virtual cluster, testing the translation and CNI mapping from the guest perspective.

```bash
# 1. Extract the centralized virtual cluster's kubeconfig from the host secret
kubectl get secret k3k-kube-ovn-centralized-cluster-kubeconfig -n k3k-kube-ovn-centralized-cluster -o jsonpath='{.data.kubeconfig\.yaml}' | base64 -d > /tmp/kubeconfig-centralized.yaml

# 2. Deploy the test pod explicitly inside the virtual cluster (default namespace)
KUBECONFIG=/tmp/kubeconfig-centralized.yaml kubectl apply -f manifests/centralized-gateway-test/test-pod.yaml

# 3. Check the pod status inside the virtual cluster
KUBECONFIG=/tmp/kubeconfig-centralized.yaml kubectl get pods -o wide

# 4. Verify that k3k has translated it to the host and Kube-OVN has assigned the 10.17.x.x IP
kubectl get pods -n k3k-kube-ovn-centralized-cluster -o wide

# 5. Perform the ping tests from WITHIN the virtual cluster pod
KUBECONFIG=/tmp/kubeconfig-centralized.yaml kubectl exec -it test-pod-centralized -- ping -c 3 10.43.0.1
KUBECONFIG=/tmp/kubeconfig-centralized.yaml kubectl exec -it test-pod-centralized -- ping -c 3 8.8.8.8

# 6. Clean up the virtual cluster workload and local kubeconfig file
KUBECONFIG=/tmp/kubeconfig-centralized.yaml kubectl delete pod test-pod-centralized
rm -f /tmp/kubeconfig-centralized.yaml
```

---

#### Option C: macOS-Native Verification (Using local k3kcli)
If you have `k3kcli` and `kubectl` installed on macOS, you can manage and verify the virtual cluster directly from your Mac without SSH-ing into the Lima VM (leveraging the forwarded port 6443).

##### 1. Copy Host Kubeconfig & Deploy Resources
First, copy the unprivileged host kubeconfig from the guest VM to your Mac and apply the centralized gateway manifests:
```bash
# Copy the host RKE2 kubeconfig to your Mac
limactl copy k3k-kube-ovn:.kube/config-mac /tmp/kubeconfig-host.yaml

# Deploy the centralized gateway resources from your Mac
KUBECONFIG=/tmp/kubeconfig-host.yaml kubectl apply -f manifests/centralized-gateway-test/namespace.yaml
KUBECONFIG=/tmp/kubeconfig-host.yaml kubectl apply -f manifests/centralized-gateway-test/subnet.yaml
KUBECONFIG=/tmp/kubeconfig-host.yaml kubectl apply -f manifests/centralized-gateway-test/cluster.yaml
```

##### 2. Establish Local Port-Forward
Since macOS cannot directly route to the RKE2 host cluster's internal `ClusterIP` network (`10.43.0.0/16`), establish a local port-forward to proxy the virtual cluster's API:
```bash
# Establish a local port-forward on port 7444 to the virtual cluster's API Service
KUBECONFIG=/tmp/kubeconfig-host.yaml kubectl port-forward -n k3k-kube-ovn-centralized-cluster svc/k3k-kube-ovn-centralized-cluster-service 7444:443 &
```

##### 3. Generate & Configure Virtual Kubeconfig
Generate the virtual cluster's kubeconfig on your Mac and point it to the local port-forward while allowing insecure TLS:
```bash
# Generate the centralized virtual cluster kubeconfig using your local k3kcli on macOS
KUBECONFIG=/tmp/kubeconfig-host.yaml k3kcli kubeconfig generate --name kube-ovn-centralized-cluster --namespace k3k-kube-ovn-centralized-cluster --config-name kubeconfig-centralized.yaml

# Point the virtual kubeconfig to your local forwarded port & allow insecure TLS
kubectl config set-cluster default --server=https://127.0.0.1:7444 --insecure-skip-tls-verify=true --kubeconfig=kubeconfig-centralized.yaml
```

##### 4. Deploy & Verify Test Pod inside Virtual Cluster
Deploy the test pod directly inside the virtual cluster, verify its status and OVN-assigned IP, and run the ping validation tests:
```bash
# Deploy the test pod inside the virtual cluster from macOS
KUBECONFIG=kubeconfig-centralized.yaml kubectl apply -f manifests/centralized-gateway-test/test-pod.yaml

# Check the pod status inside the virtual cluster
KUBECONFIG=kubeconfig-centralized.yaml kubectl get pods -o wide

# Verify that k3k has translated it to the host and Kube-OVN has assigned the 10.17.x.x IP
KUBECONFIG=/tmp/kubeconfig-host.yaml kubectl get pods -n k3k-kube-ovn-centralized-cluster -o wide

# Perform the ping tests from WITHIN the virtual cluster pod
KUBECONFIG=kubeconfig-centralized.yaml kubectl exec -it test-pod-centralized -- ping -c 3 10.43.0.1
KUBECONFIG=kubeconfig-centralized.yaml kubectl exec -it test-pod-centralized -- ping -c 3 8.8.8.8
```

*Expected result for all options: 3 packets transmitted, 3 received, 0% packet loss.*

---

## Cleanup Test Infrastructure

After completing the verification, clean up the centralized gateway test workloads and host infrastructure.

### Option A: From macOS (Host)
Run these commands from your Mac terminal to remove resources, clean up temporary local files, and terminate the background port-forward process:
```bash
# 1. Clean up test workloads and host infrastructure from macOS
KUBECONFIG=/tmp/kubeconfig-host.yaml kubectl delete -f manifests/centralized-gateway-test/cluster.yaml
KUBECONFIG=/tmp/kubeconfig-host.yaml kubectl delete -f manifests/centralized-gateway-test/subnet.yaml
KUBECONFIG=/tmp/kubeconfig-host.yaml kubectl delete -f manifests/centralized-gateway-test/namespace.yaml

# 2. Delete temporary local kubeconfig files
rm -f kubeconfig-centralized.yaml /tmp/kubeconfig-host.yaml

# 3. Stop the background port-forward process (if running in this session)
kill %1 || killall kubectl
```

### Option B: From the VM Shell
If you performed the verification inside the VM guest shell, run these commands inside the shell:
```bash
kubectl delete -f manifests/centralized-gateway-test/cluster.yaml
kubectl delete -f manifests/centralized-gateway-test/subnet.yaml
kubectl delete -f manifests/centralized-gateway-test/namespace.yaml
```
