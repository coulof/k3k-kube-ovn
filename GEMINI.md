# Gemini AI Assistant Instructions

Welcome, Gemini. This file describes the project so you can assist effectively.

## Project Summary

This repository sets up **Kube-OVN** as the primary CNI (Container Network Interface) for an **RKE2 host cluster**, which hosts virtual Kubernetes clusters created by **k3k** in **shared mode**. The architecture leverages host-level subnets to isolate virtual cluster pods.

The infrastructure stack is:
1. **RKE2** -- host cluster running with `cni: none` (replacing the default Canal with Kube-OVN)
2. **cert-manager** -- deployed via RKE2 auto-deploy manifests
3. **k3k** -- deployed via RKE2 auto-deploy manifests to manage virtual clusters
4. **Kube-OVN v1.16.2** -- installed on the host RKE2 cluster to manage physical OVS bridges and map distinct host-level namespaces to custom subnets

## Key Concepts

### Single Source of Truth & Directory Mounting
To avoid maintaining manifests in multiple places, the Lima VM configuration explicitly mounts the host repository directory (`~`) as read-only.
* `manifests/k3k/k3k-helmchart.yaml` $\rightarrow$ `/var/lib/rancher/rke2/server/manifests/k3k-helmchart.yaml`
* `manifests/k3k/namespace.yaml` $\rightarrow$ `/var/lib/rancher/rke2/server/manifests/k3k-namespace.yaml`
* `manifests/kube-ovn/subnet.yaml` $\rightarrow$ `/var/lib/rancher/rke2/server/manifests/k3k-subnet.yaml`
* `manifests/k3k/cluster.yaml` $\rightarrow$ `/var/lib/rancher/rke2/server/manifests/k3k-cluster.yaml`
* `manifests/rancher/rancher-helmchart.yaml` $\rightarrow$ `/var/lib/rancher/rke2/server/manifests/rancher-helmchart.yaml` (customized dynamically)

These are then natively applied and orchestrated by RKE2's build-in deploy controller.

### k3k Shared Mode
In shared mode, k3k virtual clusters share the host node's kernel and network stack. Workloads scheduled in the virtual cluster run as host pods under the namespace `k3k-<clustername>` (e.g., `k3k-kube-ovn-cluster`). 

### Host-Level Subnet Mapping & Kubelet Routing
By creating a custom `Subnet` CRD on the host cluster targeting the `k3k-kube-ovn-cluster` namespace, Kube-OVN automatically assigns IP addresses for virtual cluster workloads from the isolated `10.16.0.0/16` range.
* **Important:** The subnet must have `private: false` (or not enforce isolation) so that the virtual `k3k-kubelet` agent running in the guest namespace can talk to the host cluster's Kubernetes API server IP (`10.43.0.1:443`). Strict subnet isolation will block this traffic, causing the virtual kubelet to enter `CrashLoopBackOff`.

## Repository Structure

```
docs/
  localhost-dns-routing-fix.md -- Guide for resolving .localhost agent connection issues
lima/
  k3k-kube-ovn.yaml         -- Lima template with read-only mounts & dynamic manifest sync
manifests/
  k3k/
    k3k-helmchart.yaml      -- HelmChart CRD to auto-deploy k3k on host RKE2
    namespace.yaml          -- Namespace declaration with Kube-OVN subnet annotations
    cluster.yaml            -- k3k virtual Cluster spec (shared mode, CNI-less serverArgs)
  kube-ovn/
    subnet.yaml             -- Host-level Kube-OVN subnet mapped to the guest namespace (private: false)
    kube-ovn-helmchart.yaml -- Guest-level HelmChart CRD (optional, for tenant control plane)
  rancher/
    rancher-agent-resolver.yaml -- Self-healing controller manifest to resolve .localhost for agents
```

## Network Layout

| Network       | CIDR             | Used By                        |
|---------------|------------------|--------------------------------|
| Host Pod      | 10.42.0.0/16     | RKE2 host default subnet       |
| Host Service  | 10.43.0.0/16     | RKE2 host cluster services     |
| vCluster Pod  | 10.16.0.0/16     | Virtual cluster (isolated subnet) |
| vCluster Svc  | 10.96.0.0/12     | k3k virtual cluster services   |
| Join Network  | 100.64.0.0/16    | Kube-OVN node-to-pod bridge    |

## Useful Commands for Context

```bash
# Host cluster status
kubectl get nodes -o wide
kubectl -n k3k-system get pods

# View host subnets
kubectl get subnet

# Pods running in the virtual cluster namespace on the host
kubectl get pods -n k3k-kube-ovn-cluster -o wide

# Virtual cluster access
k3kcli kubeconfig generate kube-ovn-cluster > kubeconfig-virtual.yaml
KUBECONFIG=kubeconfig-virtual.yaml kubectl get nodes
KUBECONFIG=kubeconfig-virtual.yaml kubectl -n kube-system get pods
```

## Style Preferences

- Keep manifests simple and well-commented
- Prefer declarative YAML over imperative commands
- Document any non-obvious parameter choice (such as `private: false` for API accessibility)
