# Gemini AI Assistant Instructions

Welcome, Gemini. This file describes the project so you can assist effectively.

## Project Summary

This repository sets up **Kube-OVN** as the CNI (Container Network Interface) for virtual Kubernetes clusters created by **k3k** in **shared mode**. The infrastructure stack is:

1. **RKE2** -- the base Kubernetes distribution (keeps its default Canal CNI)
2. **Rancher Prime 2.14** -- installed on RKE2 for cluster management
3. **k3k** -- creates lightweight virtual Kubernetes clusters inside the host cluster
4. **Kube-OVN v1.16.2** -- deployed inside each k3k virtual cluster as its CNI

## Key Concepts

### k3k Shared Mode
In shared mode, k3k virtual clusters share the host node's kernel and network stack. There are no dedicated agent pods -- only server pods run the control plane. Workloads scheduled in the virtual cluster actually run as pods in the host cluster's namespace (`k3k-<clustername>`).

### Why Kube-OVN?
Kube-OVN provides advanced networking features (OVN/OVS-based): fine-grained subnet management, QoS, network policies, VPC isolation, and multi-cluster interconnect. It is a more feature-rich alternative to Flannel/Canal for environments that need L2/L3 network control.

### Helm Controller Auto-Deploy
RKE2 (and k3s) ship with a built-in Helm controller. Dropping a `HelmChart` YAML into `/var/lib/rancher/k3s/server/manifests/` auto-installs the chart. This repo includes a `HelmChart` CRD manifest to automate Kube-OVN installation.

## Repository Structure

```
manifests/
  k3k/cluster.yaml          -- k3k Cluster CRD (shared mode, CNI-less k3s)
  kube-ovn/helmchart.yaml   -- HelmChart CRD for k3s Helm controller auto-deploy
  kube-ovn/values.yaml      -- Kube-OVN Helm chart values
```

## Network Layout (Do NOT Change Without Checking for Collisions)

| Network       | CIDR             | Used By                        |
|---------------|------------------|--------------------------------|
| Host Pod      | 10.42.0.0/16     | RKE2 host cluster (Canal)      |
| Host Service  | 10.43.0.0/16     | RKE2 host cluster              |
| vCluster Pod  | 10.16.0.0/16     | Kube-OVN in k3k virtual cluster|
| vCluster Svc  | 10.96.0.0/12     | k3k virtual cluster services   |
| Join Network  | 100.64.0.0/16    | Kube-OVN node-to-pod bridge    |

## What I Typically Need Help With

- Adjusting Kube-OVN values for specific scenarios (QoS, subnets, VPC)
- Debugging networking issues between host and virtual clusters
- Extending manifests for multi-cluster or multi-tenant setups
- Testing on aarch64 (Apple Silicon) while targeting amd64 production

## Architecture Constraints

- Manifests must work on both **aarch64** (dev/test on MacBook Pro) and **x86_64** (production)
- The host cluster CNI (Canal) must not be disturbed
- CIDR ranges must not overlap between host and virtual clusters
- Kube-OVN runs only inside k3k virtual clusters, never on the host

## Useful Commands for Context

```bash
# Host cluster status
kubectl get nodes -o wide
kubectl -n k3k-system get pods

# Virtual cluster access
k3kcli kubeconfig generate <cluster-name> > kubeconfig-virtual.yaml
KUBECONFIG=kubeconfig-virtual.yaml kubectl get nodes
KUBECONFIG=kubeconfig-virtual.yaml kubectl -n kube-system get pods

# Kube-OVN specific
KUBECONFIG=kubeconfig-virtual.yaml kubectl -n kube-system get subnet
KUBECONFIG=kubeconfig-virtual.yaml kubectl -n kube-system get vpc
```

## Style Preferences

- Keep manifests simple and well-commented
- Prefer declarative YAML over imperative commands
- Document any non-obvious parameter choice
- When in doubt, match upstream defaults
