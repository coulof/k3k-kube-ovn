# 🎯 Kube-OVN Native Multi-VPC Egress Gateway Walkthrough Report

This report presents the architectural design, core findings, implementation details, and empirical validation results for the **native Kube-OVN `VpcEgressGateway`** multi-tenant egress SNAT demonstration.

The experiment was carried out entirely within an unprivileged, non-root-requiring multi-NIC Lima virtual environment on macOS, utilizing secondary target VMs (`egress-test-target`) for validation.

---

## 🏗️ Architectural Overview

Two virtual guest namespaces (`tenant-a` and `tenant-b`) running in a shared-mode `k3k` virtual cluster are mapped to isolated OVN VPCs and subnets, and dynamically SNAT'ed over distinct external egress IPs:

```mermaid
%%{init: {
  'theme': 'base',
  'themeVariables': {
    'fontFamily': 'SUSE, sans-serif',
    'fontSize': '14px',
    'primaryColor': '#30ba78',
    'primaryTextColor': '#0c322c',
    'primaryBorderColor': '#30ba78',
    'lineColor': '#0c322c',
    'secondaryColor': '#0c322c',
    'tertiaryColor': '#90ebcd',
    'mainBkg': '#ffffff',
    'nodeBorder': '#0c322c',
    'clusterBkg': '#efefef',
    'clusterBorder': '#90ebcd',
    'titleColor': '#0c322c',
    'edgeLabelBackground':'#ffffff'
  }
} }%%
graph TD
    %% Styling
    classDef default fill:#ffffff,stroke:#0c322c,stroke-width:1px,color:#0c322c;
    classDef target fill:#efefef,stroke:#0c322c,stroke-width:2px,color:#0c322c;
    classDef tenantA fill:#90ebcd,stroke:#0c322c,stroke-width:2px,color:#0c322c;
    classDef tenantB fill:#30ba78,stroke:#0c322c,stroke-width:2px,color:#0c322c;

    subgraph targetVM [VM: egress-test-target]
        srv["Egress Logger Server<br/>(Python HTTP)<br/>IP: 192.168.105.100:8888<br/>Interface: eth1"]:::target
    end

    subgraph hostVM [VM: k3k-kube-ovn]
        subgraph Subnet A [Tenant A VPC: subnet-tenant-a]
            podA1["client-pod-1 (tenant-a)<br/>IP: 10.10.0.5"]:::tenantA
            podA2["client-pod-2 (tenant-a)<br/>IP: 10.10.0.4"]:::tenantA
        end

        subgraph Subnet B [Tenant B VPC: subnet-tenant-b]
            podB1["client-pod-1 (tenant-b)<br/>IP: 10.20.0.6"]:::tenantB
            podB2["client-pod-2 (tenant-b)<br/>IP: 10.20.0.7"]:::tenantB
        end

        %% OVN Native Gateways
        gwA["VpcEgressGateway: gateway-tenant-a<br/>Egress IP: 192.168.105.70"]:::tenantA
        gwB["VpcEgressGateway: gateway-tenant-b<br/>Egress IP: 192.168.105.80"]:::tenantB
    end

    %% Outgoing traffic paths
    podA1 -- "VPC A" --> gwA
    podA2 -- "VPC A" --> gwA
    gwA -- "Source NAT over OVS Patch Ports" --> |Src: 192.168.105.70| srv

    podB1 -- "VPC B" --> gwB
    podB2 -- "VPC B" --> gwB
    gwB -- "Source NAT over OVS Patch Ports" --> |Src: 192.168.105.80| srv
```

---

## 🔍 Core Findings and Deep Diagnosis

During execution, two significant network hurdles were successfully diagnosed and resolved:

### 1. The Missing OVN `localnet` Port (Resolved via `Vlan` CRD)
* **Symptom:** Gateway pods could not ping or reach the external target `192.168.105.100` over `net1` (`Destination Host Unreachable`).
* **Root Cause:** A raw Kube-OVN `Subnet` referring to an underlay provider network without an accompanying `Vlan` resource is treated as a standard overlay switch. It lacked a port of `type: localnet` in OVN, which meant the host-side OVS veth pairs remained fully isolated in `br-int` and had no patch ports connecting them to the egress interface bridge `br-egress` [1].
* **Resolution:** Declared a native, flat `Vlan` CRD (`vlanId: 0`) named `egress-vlan` pointing to provider `egress`, and bound the `external-egress-subnet` to it [2]. OVN-controller immediately established dynamic patch ports between `br-int` and `br-egress`, enabling bidirectional forwarding [3].

### 2. Underlay to Overlay Route Precedence (Resolved via `/32` Host Route)
* **Symptom:** The host VM lost direct L2 bridge access to `192.168.105.100` because Kube-OVN continuously registered a broad `/24` route to `ovn0` on the host [4].
* **Root Cause:** In OVN multi-tenant underlay setups, the host daemon reconciles routes to bridge management traffic.
* **Resolution:** Programmed a highly specific `/32` host-route `192.168.105.100/32` directly on `br-egress` in the host VM [5]. Because IP routing follows the **Longest Prefix Match** rule, this `/32` route bypassed the `/24` OVN override completely without requiring constant reconciliation fights.

---

## ⚙️ Implemented Configurations

### 📂 Provider Network & VLAN Manifest
Located in `manifests/egress-gateway-experiment/vpcs-and-subnets.yaml`:
```yaml
# Map dedicated virtual gateway interface 'lima1' as Kube-OVN ProviderNetwork
apiVersion: kubeovn.io/v1
kind: ProviderNetwork
metadata:
  name: egress
spec:
  defaultInterface: lima1

---
# Declare Vlan CRD to map the underlay subnet to the ProviderNetwork natively
apiVersion: kubeovn.io/v1
kind: Vlan
metadata:
  name: egress-vlan
spec:
  vlanId: 0
  provider: egress

---
# Establish underlay external Subnet connected to our ProviderNetwork/NAD
apiVersion: kubeovn.io/v1
kind: Subnet
metadata:
  name: external-egress-subnet
spec:
  protocol: IPv4
  cidrBlock: 192.168.105.0/24
  gateway: 192.168.105.1
  vlan: egress-vlan
  provider: egress.kube-system.ovn
  natOutgoing: false
  private: false
  u2oInterconnection: false
  vpc: ovn-cluster
```

---

## 🧪 Empirical Validation Metrics

All tests compiled and completed with **100% success rate**.

### 1. Host VM L2 Bridge Reachability [5]
```bash
limactl shell k3k-kube-ovn ping -c 3 192.168.105.100
```
```
PING 192.168.105.100 (192.168.105.100) 56(84) bytes of data.
64 bytes from 192.168.105.100: icmp_seq=1 ttl=64 time=0.591 ms
64 bytes from 192.168.105.100: icmp_seq=2 ttl=64 time=0.391 ms
64 bytes from 192.168.105.100: icmp_seq=3 ttl=64 time=0.483 ms

--- 192.168.105.100 ping statistics ---
3 packets transmitted, 3 received, 0% packet loss, time 2032ms
```

### 2. Tenant A Workload Egress SNAT Verification [6]
```bash
limactl shell k3k-kube-ovn kubectl --kubeconfig tenant-a.yaml exec client-pod-1 -- wget -T 2 -qO- 'http://192.168.105.100:8888/?pod=client-pod-1&ip=10.10.0.5'
```
```
Hello from Egress Test VM! Recorded Src IP: 192.168.105.70
```

### 3. Tenant B Workload Egress SNAT Verification [7]
```bash
limactl shell k3k-kube-ovn kubectl --kubeconfig tenant-b.yaml exec client-pod-1 -- wget -T 2 -qO- 'http://192.168.105.100:8888/?pod=client-pod-1&ip=10.20.0.6'
```
```
Hello from Egress Test VM! Recorded Src IP: 192.168.105.80
```

---

## 📚 Sources & References

- [1] Kube-OVN ProviderNetwork Underlay Configuration: `manifests/egress-gateway-experiment/vpcs-and-subnets.yaml#L60-L67`
- [2] Native Kube-OVN Flat VLAN Mapping Specification: `manifests/egress-gateway-experiment/vpcs-and-subnets.yaml#L84-L93`
- [3] OVS Bridge Mapping and OVN Logical Switch Port bindings: `ovn-nbctl show` and `ovn-sbctl show` executed inside the cluster.
- [4] Host-Level routing override of `ovn0`: `k3k-kube-ovn` VM routing table diagnostics.
- [5] Host `/32` route addition for test target: `limactl shell k3k-kube-ovn ip route` diagnostics.
- [6] Tenant A workloads pod definition and namespace binding: `manifests/egress-gateway-experiment/workloads-tenant-a.yaml` and `tenant-a.yaml`.
- [7] Tenant B workloads pod definition and namespace binding: `manifests/egress-gateway-experiment/workloads-tenant-b.yaml` and `tenant-b.yaml`.

🦎 AIcko
