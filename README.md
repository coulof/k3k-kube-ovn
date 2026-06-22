# Kube-OVN as CNI for k3k Virtual Clusters on RKE2

This repository contains manifests and notes for deploying [Kube-OVN](https://kubeovn.github.io/docs/stable/en/) as the network plugin inside [k3k](https://github.com/rancher/k3k) virtual Kubernetes clusters running in **shared mode**, on top of an [RKE2](https://docs.rke2.io/) host cluster managed by [Rancher Prime](https://www.rancher.com/).

## Architecture Overview

```
+-----------------------------------------------------------+
|  RKE2 Host Cluster (Canal CNI - default)                  |
|                                                           |
|  +---------------------+  +----------------------------+ |
|  | Rancher Prime       |  | k3k Controller             | |
|  | (cattle-system)     |  | (k3k-system)               | |
|  +---------------------+  +----------------------------+ |
|                                                           |
|  +------------------------------------------------------+ |
|  | k3k Virtual Cluster (shared mode)                    | |
|  |                                                      | |
|  |  CNI: Kube-OVN                                       | |
|  |  Pod CIDR:     10.16.0.0/16                          | |
|  |  Service CIDR: 10.96.0.0/12                          | |
|  |  Join CIDR:    100.64.0.0/16                         | |
|  +------------------------------------------------------+ |
+-----------------------------------------------------------+
```

## Stack

| Component     | Version    | Role                                    |
|---------------|------------|-----------------------------------------|
| RKE2          | latest     | Base Kubernetes distribution             |
| Rancher Prime | 2.14.x     | Cluster management UI                   |
| k3k           | latest     | Virtual Kubernetes clusters              |
| Kube-OVN      | v1.16.2    | Advanced CNI for k3k virtual clusters    |

## Prerequisites

- An RKE2 cluster up and running (single or multi-node)
- `kubectl` and `helm` CLI tools
- Storage class available (for k3k etcd persistence)
- For Mac (aarch64) testing: ensure images support `linux/arm64`

## Quick Start

### 1. Install RKE2

```bash
# On the first node (server)
curl -sfL https://get.rke2.io | sh -
systemctl enable rke2-server --now
```

The default CNI (Canal) is fine for the host cluster. Kube-OVN will run **inside** the k3k virtual clusters.

### 2. Install Rancher Prime

```bash
# Install cert-manager (required)
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml

# Add Rancher Helm repo
helm repo add rancher-stable https://releases.rancher.com/server-charts/stable
helm repo update

# Install Rancher
helm install rancher rancher-stable/rancher \
  --namespace cattle-system --create-namespace \
  --set hostname=rancher.example.com \
  --set bootstrapPassword=admin \
  --set replicas=1
```

### 3. Install k3k

```bash
helm repo add k3k https://rancher.github.io/k3k
helm repo update

helm install k3k k3k/k3k \
  --namespace k3k-system --create-namespace
```

### 4. Create a k3k Virtual Cluster with Kube-OVN

```bash
# Create the virtual cluster (shared mode, CNI disabled so Kube-OVN takes over)
kubectl apply -f manifests/k3k/cluster.yaml

# Wait for the virtual cluster to be ready
kubectl -n k3k-kube-ovn-cluster wait --for=condition=Ready cluster/kube-ovn-cluster --timeout=300s

# Get the kubeconfig for the virtual cluster
k3kcli kubeconfig generate kube-ovn-cluster > kubeconfig-virtual.yaml

# Install Kube-OVN inside the virtual cluster
KUBECONFIG=kubeconfig-virtual.yaml helm repo add kubeovn https://kubeovn.github.io/kube-ovn/
KUBECONFIG=kubeconfig-virtual.yaml helm install kube-ovn kubeovn/kube-ovn \
  --namespace kube-system \
  --version v1.16.2 \
  -f manifests/kube-ovn/values.yaml
```

### Alternative: Auto-deploy Kube-OVN via RKE2 Helm Controller

If your k3k virtual cluster uses k3s under the hood, you can drop a HelmChart manifest into the auto-deploy directory:

```bash
# Copy the HelmChart manifest to the k3s server manifests path
kubectl cp manifests/kube-ovn/helmchart.yaml \
  <k3k-server-pod>:/var/lib/rancher/k3s/server/manifests/kube-ovn.yaml
```

Or apply the HelmChart resource directly to the virtual cluster:

```bash
KUBECONFIG=kubeconfig-virtual.yaml kubectl apply -f manifests/kube-ovn/helmchart.yaml
```

## Directory Structure

```
.
├── README.md                          # This file
├── GEMINI.md                          # Instructions for Gemini AI assistant
├── manifests/
│   ├── k3k/
│   │   └── cluster.yaml               # k3k virtual cluster definition
│   └── kube-ovn/
│       ├── helmchart.yaml             # HelmChart CRD for k3s Helm controller
│       └── values.yaml                # Kube-OVN Helm values
```

## Key Considerations

### Shared Mode Networking

In k3k shared mode, the virtual cluster shares the host's network namespace. Kube-OVN's overlay network (Geneve/VXLAN) must not collide with the host cluster's pod/service CIDRs. The default CIDRs in this repo are chosen to avoid overlap:

| Network       | Host Cluster (RKE2) | Virtual Cluster (k3k + Kube-OVN) |
|---------------|---------------------|-----------------------------------|
| Pod CIDR      | 10.42.0.0/16        | 10.16.0.0/16                      |
| Service CIDR  | 10.43.0.0/16        | 10.96.0.0/12                      |
| Join CIDR     | N/A                 | 100.64.0.0/16                     |

### Architecture Support

All manifests use default upstream images that support both `amd64` and `arm64`. If you test on Apple Silicon (aarch64), the same manifests work on x86_64 production clusters without changes.

### Tunnel Type

Kube-OVN defaults to `geneve` encapsulation. If your environment doesn't support Geneve, switch to `vxlan` in `manifests/kube-ovn/values.yaml`.

## Troubleshooting

```bash
# Check Kube-OVN pods inside the virtual cluster
KUBECONFIG=kubeconfig-virtual.yaml kubectl -n kube-system get pods -l app=kube-ovn

# Check OVN/OVS status
KUBECONFIG=kubeconfig-virtual.yaml kubectl -n kube-system exec -it ds/kube-ovn-cni -- ovs-vsctl show

# Check k3k cluster status on the host
kubectl -n k3k-kube-ovn-cluster get cluster,pods

# Logs from the k3k controller
kubectl -n k3k-system logs deploy/k3k-controller-manager
```

## References

- [Kube-OVN Documentation](https://kubeovn.github.io/docs/stable/en/)
- [k3k GitHub](https://github.com/rancher/k3k)
- [RKE2 Helm Controller](https://docs.rke2.io/add-ons/helm)
- [RKE2 CNI Options](https://docs.rke2.io/networking/basic_network_options)
- [Rancher Prime Installation](https://ranchermanager.docs.rancher.com/getting-started/installation-and-upgrade/install-upgrade-on-a-kubernetes-cluster)
