# Design: Controlling Inter-VPC Traffic on Harvester with Kube-OVN

## Problem Statement

Multiple VPCs on a Harvester cluster need controlled communication between them -- for example, an application VPC talking to a database VPC on port 5432 only, with inspection and audit logging. How should this be designed?

## Recommendation: Isolated VPCs + External Firewall

**Keep VPCs isolated inside the cluster. Bridge them through an external firewall/router that sits outside the cluster trust domain.**

This is the same architectural pattern that OpenShift Virtualization adopted with User Defined Networks (hard isolation by default, no in-cluster bridging), and the standard approach in traditional data center and cloud networking.

### Why not a firewall VM inside the cluster?

A firewall's value comes from sitting **outside** the trust boundary it protects. A firewall VM running inside the same cluster as the workloads it guards is architecturally questionable:

| Concern | Impact |
|---|---|
| **Trust boundary violation** | Anyone with cluster-admin RBAC can delete, modify, or bypass the firewall VM and its OVN policy routes. If the cluster is compromised, the firewall is too. |
| **Performance overhead** | All inter-VPC traffic hairpins through a VM on the same hosts -- adding latency and consuming compute. OVN enforces L3/L4 rules at wire speed in the OVS data plane via ACLs, without a middlebox. |
| **OVN already is the firewall** | NetworkPolicy, Subnet ACLs, Security Groups, and AdminNetworkPolicy all translate to OVN ACLs. For L3/L4 east-west rules, a VM adds nothing that OVN can't do natively and faster. |
| **Single point of failure** | The firewall VM becomes a dependency for all inter-VPC traffic. HA (VRRP, ECMP) adds complexity inside a platform that already has HA mechanisms. |
| **Operational burden** | A manually managed VyOS/pfSense/OPNsense requires patching, config backup, monitoring -- a separate operational domain inside your Kubernetes cluster. |

### When does the firewall belong inside?

Only two cases justify in-cluster traffic inspection:

| Case | Why OVN isn't enough | Right tool |
|---|---|---|
| **L7 / IPS / DPI** | OVN ACLs are L3/L4 only. Application-layer inspection, protocol decoding, or intrusion detection needs something that understands L7. | [Palo Alto CN-Series](https://docs.paloaltonetworks.com/cn-series) (CNF, CRD-managed, inline via CNI chaining) or [NSM](https://networkservicemesh.io/) service function chain with Suricata/nftables |
| **Compliance mandate** | A regulation or auditor requires a specific named appliance ("traffic must traverse a FortiGate with FortiGuard enabled"). | Deploy the required appliance -- but still prefer it external when possible |

Even in these cases, a **containerized CNF** (CN-Series) or **NSM service chain** is preferable to a firewall VM.

## Architecture

```
                          External Firewall / Router
                       (separate trust domain, outside cluster)
                        ┌──────────────────────────────┐
                        │   e.g. FortiGate / PA / VyOS  │
                        │                                │
                        │   VLAN 100: 192.168.100.1/24   │
                        │   VLAN 200: 192.168.200.1/24   │
                        │   VLAN 300: 192.168.300.1/24   │
                        │   WAN:      203.0.113.1/24     │
                        └───────┬──────┬──────┬──────────┘
                                │      │      │
                   Underlay     │      │      │    Underlay
                   VLAN 100     │      │      │    VLAN 300
                                │      │      │
             ┌──────────────────┘      │      └──────────────────┐
             ▼                         ▼                         ▼
    ┌──────────────────┐    ┌──────────────────┐    ┌──────────────────┐
    │     VPC-App       │    │     VPC-DB        │    │     VPC-DMZ       │
    │     (overlay)     │    │     (overlay)     │    │     (overlay)     │
    │                   │    │                   │    │                   │
    │  Egress Gateway   │    │  Egress Gateway   │    │  Egress Gateway   │
    │  → underlay       │    │  → underlay       │    │  → underlay       │
    │    VLAN 100       │    │    VLAN 200       │    │    VLAN 300       │
    │                   │    │                   │    │                   │
    │  OVN ACLs for     │    │  OVN ACLs for     │    │  OVN ACLs for     │
    │  microsegment.    │    │  microsegment.    │    │  microsegment.    │
    └──────────────────┘    └──────────────────┘    └──────────────────┘

              Harvester Cluster (Kube-OVN)
```

### How it works

1. **VPCs are fully isolated** inside the cluster -- no peering, no static routes between them
2. Each VPC has a **VPC Egress Gateway** ([docs](https://kubeovn.github.io/docs/v1.16.x/en/vpc/vpc-egress-gateway/)) that SNATs traffic onto an **underlay VLAN** via Macvlan
3. Each VPC gets its own VLAN on the physical network (VLAN 100, 200, 300)
4. The **external firewall** has an interface on each VLAN and controls:
   - Which VPCs can talk to each other (zone-based policy)
   - On which ports/protocols (L4 rules)
   - With L7 inspection, IPS, logging, audit trail
   - Internet/WAN access (north-south)
5. **East-west within a VPC** is handled by OVN ACLs (NetworkPolicy, Subnet ACLs, Security Groups) -- no firewall involvement

### Separation of concerns

| Layer | Responsible for | Mechanism |
|---|---|---|
| **Kube-OVN (inside cluster)** | VPC isolation, microsegmentation within a VPC, pod networking | OVN logical switches/routers, ACLs, NetworkPolicy, Subnet ACLs |
| **Egress Gateway (cluster edge)** | Bridging overlay VPC to physical underlay VLAN | VpcEgressGateway CRD, Macvlan, SNAT |
| **External Firewall (outside cluster)** | Inter-VPC policy, L7 inspection, north-south security, audit logging | Zone-based firewall rules, IPS/IDS, logging |
| **Physical Switch** | VLAN trunking, L2 forwarding between firewall and cluster nodes | 802.1Q trunk ports, IGMP snooping |

## Manifests

### VPCs (isolated, no peering)

```yaml
apiVersion: kubeovn.io/v1
kind: Vpc
metadata:
  name: vpc-app
spec:
  # No vpcPeerings -- fully isolated
  # No staticRoutes to other VPCs
  staticRoutes: []

---
apiVersion: kubeovn.io/v1
kind: Vpc
metadata:
  name: vpc-db
spec:
  staticRoutes: []

---
apiVersion: kubeovn.io/v1
kind: Vpc
metadata:
  name: vpc-dmz
spec:
  staticRoutes: []
```

### Subnets

```yaml
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

### Underlay VLANs for Egress

```yaml
# Provider network -- maps to the physical NIC on Harvester nodes
apiVersion: kubeovn.io/v1
kind: ProviderNetwork
metadata:
  name: provider-fw
spec:
  defaultInterface: bond1

---
# One VLAN per VPC
apiVersion: kubeovn.io/v1
kind: Vlan
metadata:
  name: vlan100
spec:
  id: 100
  provider: provider-fw

---
apiVersion: kubeovn.io/v1
kind: Vlan
metadata:
  name: vlan200
spec:
  id: 200
  provider: provider-fw

---
apiVersion: kubeovn.io/v1
kind: Vlan
metadata:
  name: vlan300
spec:
  id: 300
  provider: provider-fw

---
# Underlay subnets for each VLAN (firewall-facing side)
apiVersion: kubeovn.io/v1
kind: Subnet
metadata:
  name: underlay-app
spec:
  protocol: IPv4
  cidrBlock: 192.168.100.0/24
  gateway: 192.168.100.1       # firewall's IP on this VLAN
  vlan: vlan100
  natOutgoing: false

---
apiVersion: kubeovn.io/v1
kind: Subnet
metadata:
  name: underlay-db
spec:
  protocol: IPv4
  cidrBlock: 192.168.200.0/24
  gateway: 192.168.200.1
  vlan: vlan200
  natOutgoing: false

---
apiVersion: kubeovn.io/v1
kind: Subnet
metadata:
  name: underlay-dmz
spec:
  protocol: IPv4
  cidrBlock: 192.168.300.0/24
  gateway: 192.168.300.1
  vlan: vlan300
  natOutgoing: false
```

### Egress Gateways (one per VPC)

```yaml
apiVersion: kubeovn.io/v1
kind: VpcEgressGateway
metadata:
  name: egw-app
  namespace: default
spec:
  vpc: vpc-app
  replicas: 2
  externalSubnet: underlay-app
  bfd:
    enabled: true
  policies:
    - snat: true
      subnets:
        - subnet-app

---
apiVersion: kubeovn.io/v1
kind: VpcEgressGateway
metadata:
  name: egw-db
  namespace: default
spec:
  vpc: vpc-db
  replicas: 2
  externalSubnet: underlay-db
  bfd:
    enabled: true
  policies:
    - snat: true
      subnets:
        - subnet-db

---
apiVersion: kubeovn.io/v1
kind: VpcEgressGateway
metadata:
  name: egw-dmz
  namespace: default
spec:
  vpc: vpc-dmz
  replicas: 2
  externalSubnet: underlay-dmz
  bfd:
    enabled: true
  policies:
    - snat: true
      subnets:
        - subnet-dmz
```

### Microsegmentation within VPCs (OVN ACLs)

```yaml
# Example: only allow DB VMs to receive traffic on port 5432
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: db-allow-5432
  namespace: vpc-db-workloads
spec:
  podSelector:
    matchLabels:
      role: database
  policyTypes:
    - Ingress
  ingress:
    - ports:
        - protocol: TCP
          port: 5432
```

## Traffic Flow Example

```
App VM (10.10.0.5, vpc-app) → DB VM (10.20.0.8, vpc-db) on port 5432

1. App VM sends packet to 10.20.0.8:5432
2. vpc-app has no route to 10.20.0.0/24 (VPCs are isolated)
3. App VM's default route goes through the egress gateway (egw-app)
4. Egress gateway SNATs and sends to underlay VLAN 100
5. Physical switch delivers to external firewall on VLAN 100 interface
6. Firewall evaluates zone policy:
   - Zone "app" (VLAN 100) → Zone "db" (VLAN 200): allow TCP/5432
   - Logs the connection, runs IPS inspection
   - Routes packet to VLAN 200
7. Packet enters Harvester cluster on VLAN 200
8. Kube-OVN underlay delivers to vpc-db's egress gateway (reverse path)
9. DB VM receives packet; OVN NetworkPolicy allows TCP/5432
```

## External Firewall Configuration (conceptual)

The firewall is configured with zones mapped to VLANs:

```
Zone "app"  → interface VLAN 100 (192.168.100.1/24)
Zone "db"   → interface VLAN 200 (192.168.200.1/24)
Zone "dmz"  → interface VLAN 300 (192.168.300.1/24)
Zone "wan"  → interface WAN       (203.0.113.1/24)

Policies:
  app → db:   allow TCP/5432, log
  dmz → app:  allow TCP/443, TCP/80, log
  app → wan:  allow TCP/443, log
  db  → wan:  deny all
  *   → *:    deny all, log
```

This is managed entirely outside Kubernetes -- through the firewall's own UI/API/Terraform/Ansible. The cluster has no knowledge of or dependency on these rules.

## High Availability

| Component | HA mechanism |
|---|---|
| **Egress Gateways** | `replicas: 2` + BFD for sub-second failover (built into Kube-OVN) |
| **External Firewall** | Active/Passive with VRRP or Active/Active with ECMP (standard firewall HA, independent of cluster) |
| **Physical Switch** | Redundant switch stack / MLAG (standard DC networking) |

Each layer has its own HA -- no single component spans trust domains.

## How OpenShift Virtualization Reached the Same Conclusion

OpenShift 4.18+ introduced **User Defined Networks (UDN)** with the same philosophy:

- UDNs are **isolated by default** at the OVN data plane -- no logical router connects them
- NetworkPolicy between namespaces on different UDNs **does not work** (hard isolation, not policy-based)
- If two tenants need a shared network, you create a **ClusterUserDefinedNetwork (CUDN)** that explicitly spans their namespaces
- Within a shared network, the **AdminNetworkPolicy (ANP) / NetworkPolicy / BaselineAdminNetworkPolicy (BANP)** 3-tier ACL model handles microsegmentation

OpenShift doesn't discuss firewall VMs inside the cluster because **the architecture eliminates the need**: networks that shouldn't talk can't talk; networks that should talk use OVN ACLs for policy. North-south traffic goes through an external firewall at the infrastructure layer.

| OpenShift concept | Kube-OVN equivalent |
|---|---|
| UDN (hard isolation) | VPC (isolated, no peering) |
| CUDN (shared network across namespaces) | VPC Peering or shared subnet |
| ANP / BANP (platform-admin ACLs) | Subnet ACLs / Security Groups |
| NetworkPolicy (tenant ACLs) | NetworkPolicy (same) |
| External firewall (north-south) | External firewall via Egress Gateway + underlay VLAN |

### Sources

- [User Defined Networks in OpenShift Virtualization](https://www.redhat.com/en/blog/user-defined-networks-red-hat-openshift-virtualization)
- [Enhancing the Kubernetes pod network with UDNs](https://www.redhat.com/en/blog/enhancing-kubernetes-pod-network-user-defined-networks)
- [AdminNetworkPolicy on OVN-Kubernetes](https://ovn-kubernetes.io/features/network-security-controls/admin-network-policy/)
- [Using AdminNetworkPolicy API (Red Hat)](https://www.redhat.com/en/blog/using-adminnetworkpolicy-api-to-secure-openshift-cluster-networking)

## When L7 In-Cluster Inspection Is Truly Required

If compliance or security requirements mandate L7 east-west inspection that cannot be solved by routing through the external firewall, these are the viable in-cluster options (ordered by preference):

| Option | Type | Maturity | What it does |
|---|---|---|---|
| **[Palo Alto CN-Series](https://docs.paloaltonetworks.com/cn-series)** | CNF (container) | Production (commercial) | CRD-managed NGFW, inline via CNI chaining. L7 App-ID, IPS, DNS Security. |
| **[NSM](https://networkservicemesh.io/) + VNF** | SFC framework | CNCF Sandbox | Service function chain: `pod → firewall container → pod`. Bring your own VNF (nftables, Suricata). |
| **[F5 BIG-IP Next CNF](https://www.f5.com/products/big-ip/next/big-ip-next-for-kubernetes)** | CNF (container) | Production (commercial, telco) | Firewall + DDoS + IPS. Helm + F5 Lifecycle Operator. |

These are all **containerized** -- no firewall VM to manage. The CN-Series is the most proven for Kubernetes east-west inspection.

### Firewall appliance operators (if a VM is mandated)

If a specific firewall VM appliance is required by compliance:

| Project | Manages | Maturity | Link |
|---|---|---|---|
| **[turnbros/opnsense-operator](https://github.com/turnbros/opnsense-operator)** | OPNsense via REST API | Alpha (dormant) | CRDs: `FirewallAlias`, `FirewallFilter` |
| **[fortinet/k8s-fortigate-ctrl](https://github.com/fortinet/k8s-fortigate-ctrl)** | FortiGate via FortiOS API | Alpha ("demo code") | CRDs for FortiGate instances |

Both are early-stage. Building a custom operator for VyOS or OPNsense (watch CRDs → reconcile → push config via REST API) is a bounded project.

## Appendix: In-Cluster Firewall VM Design (Not Recommended)

For reference, an in-cluster firewall VM design using VPC peering is technically possible but architecturally discouraged. The hub-and-spoke pattern would use:

- A **transit VPC** peered with each spoke VPC via `vpcPeerings` (169.254.x.x link-local interconnects)
- **Policy routes** on the transit VPC to steer peered traffic through a firewall VM (`policyRoutes` with `action: reroute`)
- The firewall VM running on the transit subnet with interfaces to each peered VPC

This design has the following problems:
- VPC peering is documented as bilateral only; multi-peering on a single VPC is not confirmed ([Kube-OVN VPC Peering](https://kubeovn.github.io/docs/v1.16.x/en/vpc/vpc-peering/))
- The firewall shares the cluster's trust domain and failure domain
- Adds latency and complexity for rules that OVN can enforce natively
- The upstream feature request for multi-VPC centralized access ([kubeovn/kube-ovn#6229](https://github.com/kubeovn/kube-ovn/issues/6229)) remains open

If this pattern is required despite the above, see the git history of this file for the full manifests (commit `ec2955b`).

## References

### Kube-OVN
- [VPC](https://kubeovn.github.io/docs/v1.16.x/en/vpc/vpc/) -- static routes, policy routes, isolation
- [VPC Egress Gateway](https://kubeovn.github.io/docs/v1.16.x/en/vpc/vpc-egress-gateway/) -- bridging overlay to underlay
- [VPC Peering](https://kubeovn.github.io/docs/v1.16.x/en/vpc/vpc-peering/) -- bilateral interconnect (not recommended for this pattern)
- [Underlay Installation](https://kubeovn.github.io/docs/v1.16.x/en/start/underlay/) -- ProviderNetwork, VLAN, underlay subnets
- [NetworkPolicy](https://kubeovn.github.io/docs/v1.16.x/en/guide/networkpolicy/) -- OVN ACL-based microsegmentation
- [Security Groups](https://kubeovn.github.io/docs/v1.16.x/en/vpc/security-group/) -- per-pod tiered ACLs
- [kubeovn/kube-ovn#6229](https://github.com/kubeovn/kube-ovn/issues/6229) -- multi-VPC centralized access (open)

### Harvester
- [kube-ovn-operator addon](https://docs.harvesterhci.io/v1.8/advanced/addons/kubeovn-operator)
- [harvester/harvester#4400](https://github.com/harvester/harvester/issues/4400) -- firewall VM on Harvester (closed, pre-KubeOVN)
- [harvester/harvester#7397](https://github.com/harvester/harvester/issues/7397) -- SDN Epic

### OpenShift Virtualization (comparative)
- [UDNs in OpenShift Virtualization](https://www.redhat.com/en/blog/user-defined-networks-red-hat-openshift-virtualization)
- [Enhancing pod network with UDNs](https://www.redhat.com/en/blog/enhancing-kubernetes-pod-network-user-defined-networks)
- [AdminNetworkPolicy on OVN-Kubernetes](https://ovn-kubernetes.io/features/network-security-controls/admin-network-policy/)
- [OpenShift 4.18 networking (Network World)](https://www.networkworld.com/article/3833169/red-hat-openshift-4-18-expands-cloud-native-networking.html)

### CNF Firewalls
- [Palo Alto CN-Series](https://docs.paloaltonetworks.com/cn-series)
- [CN-Series as Kubernetes CNF](https://docs.paloaltonetworks.com/cn-series/deployment/cn-deployment/deployment-modes-of-cn-series-firewalls/deploy-the-cn-series-firewall-as-a-kubernetes-cnf)
- [F5 BIG-IP Next for Kubernetes](https://www.f5.com/products/big-ip/next/big-ip-next-for-kubernetes)
- [Network Service Mesh (NSM)](https://networkservicemesh.io/) -- CNCF Sandbox, L2/L3 SFC

### Firewall Appliance Operators
- [turnbros/opnsense-operator](https://github.com/turnbros/opnsense-operator) (alpha)
- [fortinet/k8s-fortigate-ctrl](https://github.com/fortinet/k8s-fortigate-ctrl) (alpha)
- [Aviatrix DCF for Kubernetes](https://docs.aviatrix.com/docs/enterprise/8.2/guides/security/dcf/dcf-kubernetes) (cloud-only)
