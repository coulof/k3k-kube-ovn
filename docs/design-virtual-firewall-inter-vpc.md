# Design: Virtual Firewall for Inter-VPC Traffic on Harvester with Kube-OVN

## Problem Statement

Multiple VPCs on a Harvester cluster need to communicate with each other, but all inter-VPC traffic must pass through a centralized firewall for inspection, policy enforcement, and audit logging.

Kube-OVN's native options are insufficient on their own:

- **VPC Peering** -- bilateral only (2 VPCs), no middlebox in the path, no inspection ([Kube-OVN VPC Peering](https://kubeovn.github.io/docs/v1.16.x/en/vpc/vpc-peering/))
- **VPC Egress Gateway** -- strictly VPC-to-external, not inter-VPC ([Kube-OVN VPC Egress Gateway](https://kubeovn.github.io/docs/v1.16.x/en/vpc/vpc-egress-gateway/))
- **Subnet ACLs / NetworkPolicy** -- microsegmentation within a VPC, not cross-VPC routing ([#7381](https://github.com/harvester/harvester/issues/7381))
- **Multi-VPC centralized access** -- requested upstream but not yet implemented ([kubeovn/kube-ovn#6229](https://github.com/kubeovn/kube-ovn/issues/6229))

A virtual firewall VM (pfSense, OPNsense, VyOS, Fortinet, Palo Alto, etc.) running on Harvester can fill this gap.

## Design Overview

A **hub-and-spoke** topology where the firewall VM acts as the transit router between all VPCs.

```
                    ┌─────────────────────────────────┐
                    │        Transit/Security VPC      │
                    │         (vpc-transit)             │
                    │                                   │
                    │   ┌───────────────────────────┐   │
                    │   │  Firewall VM (e.g. VyOS)  │   │
                    │   │                           │   │
                    │   │  eth0: 172.16.0.2/24      │   │ ◄── transit subnet
                    │   │  eth1: 10.10.0.2/24       │   │ ◄── peered to vpc-app
                    │   │  eth2: 10.20.0.2/24       │   │ ◄── peered to vpc-db
                    │   │  eth3: 10.30.0.2/24       │   │ ◄── peered to vpc-dmz
                    │   │  eth4: 192.168.1.2/24     │   │ ◄── underlay (external)
                    │   └───────────────────────────┘   │
                    └──────┬──────────┬──────────┬──────┘
                           │          │          │
              VPC Peering  │          │          │  VPC Peering
              (169.254.x)  │          │          │  (169.254.x)
                           │          │          │
                ┌──────────┘   ┌──────┘   ┌──────┘
                ▼              ▼          ▼
         ┌───────────┐  ┌───────────┐  ┌───────────┐
         │  vpc-app   │  │  vpc-db    │  │  vpc-dmz   │
         │            │  │            │  │            │
         │ 10.10.0/24 │  │ 10.20.0/24 │  │ 10.30.0/24 │
         │ App VMs    │  │ DB VMs     │  │ Web VMs    │
         └───────────┘  └───────────┘  └───────────┘
```

### Key Principle

Every VPC has a **default route (0.0.0.0/0) pointing at the firewall VM's interface** in that VPC's peered subnet. The firewall VM has interfaces in all VPCs (via Multus/Kube-OVN secondary NICs) and applies security policies before forwarding.

## Design Options

### Option A: Multi-NIC Firewall with VPC Peering (Scalable)

Each spoke VPC peers with the transit VPC. The firewall VM has one NIC per peered VPC plus an optional underlay NIC for external access.

**Pros:**
- Each VPC remains fully isolated -- traffic only crosses VPCs through the firewall
- Scales to N VPCs (one peering + one firewall NIC per VPC)
- Firewall has full visibility: source VPC, destination VPC, L3/L4/L7 content
- Can apply zone-based policies (app→db: allow 5432/tcp, dmz→db: deny all)

**Cons:**
- VPC peering is currently limited to bilateral pairs (each spoke peers only with transit)
- Spoke-to-spoke traffic traverses two hops (spoke→firewall→spoke)
- Firewall VM is a single point of failure (mitigate with HA pair)

**Current limitation:** Kube-OVN supports only [bilateral VPC peering](https://kubeovn.github.io/docs/v1.16.x/en/vpc/vpc-peering/). Each spoke VPC can peer with the transit VPC, but the transit VPC needs N peerings (one per spoke). This works if Kube-OVN allows one VPC to have multiple `vpcPeerings` entries -- the CRD field is an array, suggesting this is possible, but it is not explicitly documented for N>1.

### Option B: Multi-NIC Firewall on Shared Subnets (Simpler)

Instead of VPC peering, place the firewall VM directly on each VPC's subnet using Multus secondary NICs. Each VPC's subnet uses the firewall's IP as its gateway.

**Pros:**
- No VPC peering needed -- simpler configuration
- Firewall is the gateway; all traffic naturally flows through it
- Works today with Harvester v1.8 Kube-OVN integration

**Cons:**
- Firewall VM's pod needs annotation for each network attachment
- Kube-OVN assigns the gateway role to OVN by default; overriding requires `disableGatewayCheck: true` and careful IP planning
- Scaling to many VPCs means many NICs on a single VM

### Option C: Underlay Transit + Overlay Spokes (Hybrid)

The firewall VM sits on an underlay/VLAN subnet with direct physical network access. Each spoke VPC uses a VPC Egress Gateway or static route to forward inter-VPC-bound traffic to the firewall's underlay IP. The firewall routes back into the destination VPC via another underlay path or overlay.

**Pros:**
- Firewall has native physical network performance (no encapsulation overhead)
- Underlay path can carry multicast, non-IP protocols
- Matches traditional DC firewall placement

**Cons:**
- Requires underlay subnets on both sides of the firewall
- Lose OVN L3 features on underlay segments
- More complex physical switch configuration

## Recommended Design: Option A (Multi-NIC + VPC Peering)

Option A provides the cleanest isolation model and matches the VPC abstraction. Here are the manifests.

### Network Layout

| VPC | Subnet CIDR | Firewall IP in this VPC | Purpose |
|---|---|---|---|
| vpc-transit | 172.16.0.0/24 | 172.16.0.2 | Firewall management + HA |
| vpc-app | 10.10.0.0/24 | peered via 169.254.1.1 | Application VMs |
| vpc-db | 10.20.0.0/24 | peered via 169.254.2.1 | Database VMs |
| vpc-dmz | 10.30.0.0/24 | peered via 169.254.3.1 | DMZ / public-facing VMs |
| (underlay) | 192.168.1.0/24 | 192.168.1.2 | External/internet access |

### Manifests

#### VPCs with Peering and Static Routes

```yaml
# Transit VPC -- the hub
apiVersion: kubeovn.io/v1
kind: Vpc
metadata:
  name: vpc-transit
spec:
  # Peer with each spoke VPC
  vpcPeerings:
    - remoteVpc: vpc-app
      localConnectIP: 169.254.1.1/30
    - remoteVpc: vpc-db
      localConnectIP: 169.254.2.1/30
    - remoteVpc: vpc-dmz
      localConnectIP: 169.254.3.1/30
  staticRoutes:
    # Route to spoke subnets via peering endpoints
    - cidr: 10.10.0.0/24
      nextHopIP: 169.254.1.2
      policy: policyDst
    - cidr: 10.20.0.0/24
      nextHopIP: 169.254.2.2
      policy: policyDst
    - cidr: 10.30.0.0/24
      nextHopIP: 169.254.3.2
      policy: policyDst

---
# App VPC -- spoke
apiVersion: kubeovn.io/v1
kind: Vpc
metadata:
  name: vpc-app
spec:
  vpcPeerings:
    - remoteVpc: vpc-transit
      localConnectIP: 169.254.1.2/30
  staticRoutes:
    # Default route: ALL traffic goes through the firewall
    - cidr: 0.0.0.0/0
      nextHopIP: 169.254.1.1
      policy: policyDst

---
# DB VPC -- spoke
apiVersion: kubeovn.io/v1
kind: Vpc
metadata:
  name: vpc-db
spec:
  vpcPeerings:
    - remoteVpc: vpc-transit
      localConnectIP: 169.254.2.2/30
  staticRoutes:
    - cidr: 0.0.0.0/0
      nextHopIP: 169.254.2.1
      policy: policyDst

---
# DMZ VPC -- spoke
apiVersion: kubeovn.io/v1
kind: Vpc
metadata:
  name: vpc-dmz
spec:
  vpcPeerings:
    - remoteVpc: vpc-transit
      localConnectIP: 169.254.3.2/30
  staticRoutes:
    - cidr: 0.0.0.0/0
      nextHopIP: 169.254.3.1
      policy: policyDst
```

#### Subnets

```yaml
apiVersion: kubeovn.io/v1
kind: Subnet
metadata:
  name: subnet-transit
spec:
  vpc: vpc-transit
  cidrBlock: 172.16.0.0/24
  gateway: 172.16.0.1
  protocol: IPv4

---
apiVersion: kubeovn.io/v1
kind: Subnet
metadata:
  name: subnet-app
spec:
  vpc: vpc-app
  cidrBlock: 10.10.0.0/24
  gateway: 10.10.0.1
  protocol: IPv4

---
apiVersion: kubeovn.io/v1
kind: Subnet
metadata:
  name: subnet-db
spec:
  vpc: vpc-db
  cidrBlock: 10.20.0.0/24
  gateway: 10.20.0.1
  protocol: IPv4

---
apiVersion: kubeovn.io/v1
kind: Subnet
metadata:
  name: subnet-dmz
spec:
  vpc: vpc-dmz
  cidrBlock: 10.30.0.0/24
  gateway: 10.30.0.1
  protocol: IPv4
```

#### Firewall VM (KubeVirt on Harvester)

The firewall VM needs a NIC on the transit subnet plus an optional underlay NIC for external access. The VPC peering handles routing at the OVN level -- the firewall VM sees peered traffic arriving on its transit subnet interface because the transit VPC's logical router forwards it.

```yaml
# Network Attachment for underlay/external access (optional)
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: underlay-external
  namespace: vm-firewall
spec:
  config: |
    {
      "cniVersion": "0.3.1",
      "type": "kube-ovn",
      "server_socket": "/run/openvswitch/kube-ovn-daemon.sock",
      "provider": "underlay-external.vm-firewall.ovn"
    }

---
# Firewall VM
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: firewall-01
  namespace: vm-firewall
  labels:
    app: firewall
spec:
  running: true
  template:
    metadata:
      labels:
        app: firewall
      annotations:
        # Primary NIC on transit subnet
        ovn.kubernetes.io/logical_switch: subnet-transit
        ovn.kubernetes.io/ip_address: "172.16.0.2"
        # Enable IP forwarding inside the VM
        ovn.kubernetes.io/port_security: "false"
    spec:
      domain:
        cpu:
          cores: 4
        resources:
          requests:
            memory: 4Gi
        devices:
          interfaces:
            - name: transit
              bridge: {}
            # Add underlay NIC for external access
            - name: external
              bridge: {}
          disks:
            - name: rootdisk
              disk:
                bus: virtio
      networks:
        - name: transit
          pod: {}
        - name: external
          multus:
            networkName: underlay-external
      volumes:
        - name: rootdisk
          containerDisk:
            image: <your-firewall-image>   # VyOS, OPNsense, etc.
```

### How Traffic Flows

```
VM in vpc-app (10.10.0.5) → VM in vpc-db (10.20.0.8)

1. App VM sends packet to 10.20.0.8
2. vpc-app has default route → 169.254.1.1 (transit VPC peering endpoint)
3. OVN delivers packet to vpc-transit's logical router
4. vpc-transit routes 10.20.0.0/24 → 169.254.2.2 (peering to vpc-db)
5. BUT: the transit VPC's subnet hosts the firewall VM at 172.16.0.2
   → OVN policy route can redirect to the firewall VM first
6. Firewall inspects, applies policy, forwards (or drops)
7. Packet exits firewall → vpc-transit router → peering → vpc-db → DB VM
```

**Note:** Step 5-6 requires that the transit VPC has policy routes configured to steer peered traffic through the firewall VM's IP before forwarding to the destination peering endpoint. This is the critical piece -- without it, OVN would route directly between peering endpoints, bypassing the firewall.

```yaml
# Policy route on vpc-transit to force traffic through the firewall
# (applied to vpc-transit's logical router)
spec:
  policyRoutes:
    - priority: 1000
      match: "ip4.src == 10.10.0.0/24 && ip4.dst == 10.20.0.0/24"
      action: reroute
      nextHopIP: 172.16.0.2   # firewall VM
    - priority: 1000
      match: "ip4.src == 10.20.0.0/24 && ip4.dst == 10.10.0.0/24"
      action: reroute
      nextHopIP: 172.16.0.2
    # ... one pair per spoke-to-spoke direction
```

## High Availability

A single firewall VM is a SPOF. Options:

| HA Pattern | How it works | Kube-OVN support |
|---|---|---|
| **Active/Passive VRRP** | Two firewall VMs share a VIP via VRRP/keepalived; the transit VPC routes to the VIP | Supported -- static route `nextHopIP` points to the VIP |
| **Active/Active ECMP** | Two firewall VMs each advertise routes; OVN load-balances via ECMP | Requires `enableEcmp: true` on subnet + BFD for failover |
| **Harvester VM HA** | Harvester restarts the firewall VM on another node if the host fails | Built-in; set `spec.runStrategy: RerunOnFailure` on the VM |

The VRRP pattern is the simplest and most commonly supported by firewall appliances (VyOS, pfSense, OPNsense all support VRRP natively).

## Firewall Software Options

| Appliance | License | Multi-arch (arm64+amd64) | KubeVirt compatible | Notes |
|---|---|---|---|---|
| **VyOS** | GPL (rolling) / Commercial (LTS) | Yes | Yes (qcow2) | Best fit for routing-heavy designs; full BGP/OSPF |
| **OPNsense** | BSD | amd64 only | Yes (qcow2/raw) | Rich UI, plugin ecosystem |
| **pfSense** | Apache 2.0 (CE) | amd64 only | Yes (qcow2/raw) | Widely deployed, large community |
| **Fortinet FortiGate-VM** | Commercial | Yes | Yes (qcow2) | Enterprise-grade, FortiGuard threat intel |
| **Palo Alto VM-Series** | Commercial | amd64 only | Yes (qcow2) | Advanced threat prevention, App-ID |

For arm64 development on MacBook Pro, VyOS is the safest choice.

## Open Questions and Limitations

1. **Multiple vpcPeerings on one VPC:** The `vpcPeerings` field is an array, but the docs only confirm bilateral (2 VPC) peering. Whether a single VPC can maintain N simultaneous peerings is **not explicitly documented**. This is the design's biggest risk -- test with 3+ VPCs before committing.

2. **Policy routes for traffic steering:** The `policyRoutes` field on VPC supports `reroute` action, which redirects matched traffic to a different next-hop. This is essential for forcing peered traffic through the firewall. If `reroute` does not work across peering endpoints, Option B (direct multi-NIC) becomes necessary.

3. **Scalability:** Each new spoke VPC adds one peering config + two policy route entries (forward + reverse) per existing spoke. For N spokes, the transit VPC needs N peerings and N*(N-1) policy route entries.

4. **Upstream feature request:** [kubeovn/kube-ovn#6229](https://github.com/kubeovn/kube-ovn/issues/6229) requests multi-VPC centralized access natively. If implemented, it could simplify or replace this design.

5. **Harvester context:** Issue [#4400](https://github.com/harvester/harvester/issues/4400) asked about firewall VMs on Harvester and was closed with the answer that it was not supported at the time (pre-Kube-OVN integration). With the kube-ovn-operator addon (v1.6+), VPC isolation and multi-NIC VMs are now available, making this design feasible.

## References

- [Kube-OVN VPC](https://kubeovn.github.io/docs/v1.16.x/en/vpc/vpc/) -- static routes, policy routes
- [Kube-OVN VPC Peering](https://kubeovn.github.io/docs/v1.16.x/en/vpc/vpc-peering/) -- bilateral interconnect via 169.254.x.x
- [Kube-OVN VPC Egress Gateway](https://kubeovn.github.io/docs/v1.16.x/en/vpc/vpc-egress-gateway/) -- external-only, not inter-VPC
- [kubeovn/kube-ovn#6229](https://github.com/kubeovn/kube-ovn/issues/6229) -- multi-VPC centralized access request (open)
- [harvester/harvester#4400](https://github.com/harvester/harvester/issues/4400) -- firewall VM on Harvester (closed, pre-KubeOVN)
- [harvester/harvester#7397](https://github.com/harvester/harvester/issues/7397) -- SDN Epic (Phase 1)
- [Harvester kube-ovn-operator](https://docs.harvesterhci.io/v1.8/advanced/addons/kubeovn-operator)
- [Kube-OVN Multi-Network Policy](https://kubeovn.github.io/docs/v1.16.x/en/guide/multi-network-policy/) -- scoping policies to specific NICs
