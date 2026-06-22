# Kube-OVN Centralized Gateway Test Guide

This guide describes how to run and verify a **Centralized Gateway** configuration using Kube-OVN on top of the host cluster VM.

---

## 🧠 What is a Centralized Gateway?

In an overlay network:
1. **Distributed Gateway (Default):** Every host node acts as a gateway and forwards external-bound traffic (`natOutgoing: true`) independently using its own local network interface and routing table.
2. **Centralized Gateway:** Egress traffic from all pods mapped to the subnet is routed over OVS internal tunnels to a **single, specific host node** (designated as the `gatewayNode`). That designated node then translates and routes the traffic through its local interface.

### Why Use a Centralized Gateway?
- **Auditing & Whitelisting:** External networks only see a single, predictable host IP for all egress traffic originating from the subnet (the IP of the designated `gatewayNode`), rather than various random node IPs.
- **Controlled Egress Paths:** Restricts outbound paths to specific machines in the cluster.

---

## 📂 Test Manifests Layout

The centralized gateway test artifacts are located under:
```
manifests/centralized-gateway-test/
├── subnet.yaml           # Subnet CRD with gatewayType: centralized & gatewayNode mapping
├── namespace.yaml        # Target guest namespace on host with subnet annotation mapping
├── cluster.yaml          # k3k Virtual Cluster spec running on the isolated range
└── test-pod.yaml         # Lightweight Alpine testing container
```

---

## 🚀 Execution & Verification Steps

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

### 4. Deploy the Centralized Test Pod
Once the control plane pods are running, deploy the alpine verification container directly in the namespace:
```bash
# Deploy the alpine test pod
kubectl apply -f manifests/centralized-gateway-test/test-pod.yaml -n k3k-kube-ovn-centralized-cluster

# Check that it has been successfully assigned an IP in the 10.17.0.0/16 range
kubectl get pod test-pod-centralized -n k3k-kube-ovn-centralized-cluster -o wide
```

### 5. Perform Connectivity Verification
Verify both local gateway and external internet access through the single centralized node:
```bash
# 1. Ping the host API server Gateway IP (10.43.0.1)
kubectl exec -it test-pod-centralized -n k3k-kube-ovn-centralized-cluster -- ping -c 3 10.43.0.1

# 2. Ping external WAN destination (8.8.8.8) to verify centralized SNAT egress
kubectl exec -it test-pod-centralized -n k3k-kube-ovn-centralized-cluster -- ping -c 3 8.8.8.8
```
*Expected result for both tests: 3 packets transmitted, 3 packets received, 0% packet loss.*

---

## 🧹 Cleanup Test Workloads
After completing the verification, clean up the centralized gateway test suite:
```bash
kubectl delete -f manifests/centralized-gateway-test/test-pod.yaml -n k3k-kube-ovn-centralized-cluster
kubectl delete -f manifests/centralized-gateway-test/cluster.yaml
kubectl delete -f manifests/centralized-gateway-test/subnet.yaml
kubectl delete -f manifests/centralized-gateway-test/namespace.yaml
```
