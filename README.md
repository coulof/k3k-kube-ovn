# Kube-OVN as CNI for k3k Virtual Clusters on RKE2

This repository sets up **Kube-OVN** as the primary Container Network Interface (CNI) for virtual Kubernetes clusters created by **k3k** in **shared mode**, running on top of an **RKE2 host cluster**.

---

## Architecture Overview

```
+---------------------------------------------------------------------------------+
| RKE2 Host Cluster (CNI: Kube-OVN)                                               |
|                                                                                 |
|  +---------------------------+  +--------------------------------------------+  |
|  | Host Namespace: default   |  | Host Namespace: k3k-kube-ovn-cluster       |  |
|  | (Host workloads)          |  | (Virtual Cluster Workloads)                |  |
|  |                           |  |                                            |  |
|  | [Pod] (IP: 10.42.x.x)     |  | [Virtual Pod] (IP: 10.16.x.x)              |  |
|  +---------------------------+  +--------------------------------------------+  |
|                                                                                 |
|  +---------------------------+  +--------------------------------------------+  |
|  | OVN Subnet: default-subnet|  | OVN Subnet: k3k-kube-ovn-subnet            |  |
|  | CIDR: 10.42.0.0/16        |  | CIDR: 10.16.0.0/16 (private: false)         |  |
|  +---------------------------+  +--------------------------------------------+  |
+---------------------------------------------------------------------------------+
```

### Key Architectural Concepts

1. **Host-Level CNI Control:** RKE2 is configured with `cni: none`. Kube-OVN is installed on the host RKE2 cluster to manage physical OVS bridges and all core networking.
2. **Namespace-to-Subnet Binding:** A custom Kube-OVN `Subnet` is defined on the host with CIDR `10.16.0.0/16` and is annotated directly to bind with the virtual cluster's namespace (`k3k-kube-ovn-cluster`). Workloads scheduled inside the virtual cluster are translated to the host and automatically assigned IPs from this isolated range.
3. **Kubelet API Communication:** The virtual cluster's `k3k-kubelet` agent must be able to talk to the host cluster's Kubernetes API server IP (`10.43.0.1:443`). To unblock this traffic, the subnet has `private: false` (strict isolation disabled), preventing a container creation deadlock.
4. **Declarative & Single Source of Truth:** The Lima configuration mounts the host directory read-only. On boot, the provisioning scripts automatically copy manifests from the mounted path to `/var/lib/rancher/rke2/server/manifests/` to be natively deployed by RKE2, removing any double-maintenance overhead.

---

## Tech Stack

| Component | Version | Role |
| :--- | :--- | :--- |
| **Lima** | latest | macOS VM manager (openSUSE Leap guest) |
| **RKE2** | latest | Base host Kubernetes distribution |
| **k3k** | latest | Lightweight virtual Kubernetes clusters |
| **Kube-OVN** | `v1.16.2` | Advanced CNI and subnet mapping |
| **Rancher Prime** | latest | Enterprise Kubernetes management platform |

---

## Directory Structure

```
.
├── README.md                      # This file
├── GEMINI.md                      # Gemini AI context and instructions
├── lima/
│   └── k3k-kube-ovn.yaml         # Lima VM template with read-only mounts & auto-sync
└── manifests/
    ├── k3k/
    │   ├── k3k-helmchart.yaml    # Declarative HelmChart for k3k
    │   ├── namespace.yaml        # Namespace with Kube-OVN subnet annotations
    │   └── cluster.yaml          # k3k virtual cluster spec (shared mode)
    ├── kube-ovn/
    │   └── subnet.yaml           # Host Kube-OVN subnet mapped to virtual namespace
    └── rancher/
        └── rancher-helmchart.yaml # Declarative HelmChart for Rancher Prime
```

---

## Network Layout

| Network | CIDR | Used By |
| :--- | :--- | :--- |
| **Host Pod** | `10.42.0.0/16` | RKE2 host default subnet (Kube-OVN) |
| **Host Service**| `10.43.0.0/16` | RKE2 host cluster services |
| **vCluster Pod**| `10.16.0.0/16` | Kube-OVN subnet mapped to virtual cluster namespace |
| **vCluster Svc**| `10.96.0.0/12` | k3k virtual cluster services |
| **Join Network**| `100.64.0.0/16` | Kube-OVN node-to-pod bridge |

---

## Quick Start (Lima on Mac)

### 1. Start the VM
The Lima template provisions the openSUSE Leap VM, mounts your host home directory, and automates copying all manifests:

```bash
# Create the VM instance
limactl create --name k3k-kube-ovn lima/k3k-kube-ovn.yaml

# Start the VM instance (mounts host paths)
limactl start k3k-kube-ovn
```

### 2. Verify Deployments
Shell into the VM and verify the status of components. Kubectl is pre-configured:

```bash
# Access the VM shell
limactl shell k3k-kube-ovn

# Check that the host node is Ready
kubectl get nodes

# Check that all pods are running successfully
kubectl get pods -A
```

Expected output:
* Kube-OVN, cert-manager, and k3k pods are in `Running` state in `kube-system`, `cert-manager`, and `k3k-system` namespaces.
* Virtual cluster pods (`k3k-kube-ovn-cluster-server-0` and `k3k-kube-ovn-cluster-kubelet-...`) are running cleanly in `k3k-kube-ovn-cluster`.

---

## Verification & Troubleshooting

### 1. View OVN Subnets
To verify that the custom virtual subnet is active:
```bash
kubectl get subnet k3k-kube-ovn-subnet
```

### 2. Check Virtual Pod IPs
Verify that virtual pods and test pods schedule directly inside the custom host-level subnet CIDR (`10.16.0.0/16`):
```bash
kubectl get pods -n k3k-kube-ovn-cluster -o wide
```

Expected IP allocation:
* `k3k-kube-ovn-cluster-kubelet-...` $\rightarrow$ `10.16.0.x`
* `k3k-kube-ovn-cluster-server-0` $\rightarrow$ `10.16.0.x`

---

## References

- [Lima VM Documentation](https://lima-vm.io/)
- [Kube-OVN Documentation](https://kubeovn.github.io/docs/stable/en/)
- [Rancher k3k Repository](https://github.com/rancher/k3k)
- [RKE2 Auto-deploying Manifests](https://docs.rke2.io/advanced#auto-deploying-manifests)
