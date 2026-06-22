# Harvester kube-ovn-operator: Underlay/VLAN Mode and Microsegmentation

## What is the kube-ovn-operator?

The [kube-ovn-operator](https://github.com/harvester/kubeovn-operator) is an **official Harvester addon** that manages the full lifecycle of Kube-OVN as a secondary CNI on Harvester clusters. It is maintained by the Harvester team (not the upstream Kube-OVN project).

It is enabled through the Harvester UI: **Advanced > Add-ons > kubeovn-operator (Experimental) > Enable**.

The operator introduces a single `Configuration` CRD that defines the desired Kube-OVN deployment state, and runs three reconciliation controllers:

1. **Configuration Controller** -- generates Kube-OVN objects from templates
2. **Healthcheck Controller** -- monitors OVN NB/SB databases
3. **Node Controller** -- handles node deletion (DB member + chassis cleanup)

### Sources

- [Harvester kube-ovn-operator addon docs](https://docs.harvesterhci.io/v1.8/advanced/addons/kubeovn-operator)
- [kubeovn-operator GitHub](https://github.com/harvester/kubeovn-operator)
- [Configuration CRD types](https://github.com/harvester/kubeovn-operator/blob/main/api/v1/configuration_types.go)

---

## Underlay/VLAN Mode Support

### Short answer

**Yes**, since Harvester v1.8 (Phase 2 of the Kube-OVN integration).

### Phased rollout

| Phase | Harvester version | Scope |
|---|---|---|
| Phase 1 | v1.6.x | Overlay only: subnets, VPCs, subnet ACLs, NetworkPolicy for microsegmentation ([#7397](https://github.com/harvester/harvester/issues/7397)) |
| Phase 2 | v1.8.x | **Underlay on non-mgmt cluster networks**, VPC NAT Gateway (EIP/SNAT/DNAT), external connectivity ([#9464](https://github.com/harvester/harvester/issues/9464)) |
| Phase 3 | v1.9.x | LB integration, VM live migration on overlay, guest clusters on overlay networks ([#9907](https://github.com/harvester/harvester/issues/9907)) |

Phase 2 addressed this specific gap:

> *"Limited Network Flexibility: Overlay networks can only be created on the built-in management network (mgmt), preventing users from leveraging custom underlay networks for better performance and integration with physical infrastructure."*
>
> -- [#9464](https://github.com/harvester/harvester/issues/9464)

### Configuration CRD fields for VLAN/underlay

From [`configuration_types.go`](https://github.com/harvester/kubeovn-operator/blob/main/api/v1/configuration_types.go):

```go
type NetworkingSpec struct {
    NetworkType  string   // "geneve" or "vlan"
    TunnelType   string   // "geneve", "vxlan", or "stt"
    Vlan         VlanSpec
    // ...
}

type VlanSpec struct {
    ProviderName  string // default: "provider"
    VlanInterface string // physical NIC name
    VlanName      string // default: "ovn-vlan"
    VlanID        int    // 1-4094
}

type ComponentSpec struct {
    U2OInterconnection bool // underlay-to-overlay routing
    // ...
}
```

### How underlay works on Harvester

To create a pure underlay network with directly routable VM IPs, three Kube-OVN resources are needed on top of the operator-managed installation:

```yaml
# 1. ProviderNetwork -- maps to a physical NIC or bond on Harvester nodes
apiVersion: kubeovn.io/v1
kind: ProviderNetwork
metadata:
  name: pn1
spec:
  defaultInterface: bond-vm-bo   # Harvester bond created via ClusterNetwork + VlanConfig

---
# 2. Vlan -- tags traffic on the provider network
apiVersion: kubeovn.io/v1
kind: Vlan
metadata:
  name: vlan2013
spec:
  id: 2013
  provider: pn1

---
# 3. Subnet -- virtual switch mapped to the VLAN
apiVersion: kubeovn.io/v1
kind: Subnet
metadata:
  name: underlay-subnet
spec:
  protocol: IPv4
  cidrBlock: 10.115.16.0/21
  gateway: 10.115.23.254
  vlan: vlan2013
  provider: vswitch.default.ovn
  natOutgoing: false
  disableGatewayCheck: true
  excludeIps:
    - 10.115.16.1
    - 10.115.23.254
```

### Known integration friction

Issue [#10154](https://github.com/harvester/harvester/issues/10154) (open) tracks directly routable VM IPs on physical VLANs. Community testing on Harvester v1.8 has surfaced friction between Kube-OVN's ProviderNetwork and Harvester's own network controller:

- Harvester's `harvester-network-controller` manages bonds (`bond-vm-bo`) and Linux bridges (`bond-vm-br`) via ClusterNetwork + VlanConfig
- Kube-OVN's ProviderNetwork creates its own OVS bridge (`br-pn1`) and takes over the bond interface
- These two controllers can conflict: the Linux bridge loses its uplink when OVS absorbs the bond

The recommended workaround (per issue discussion) is to create the ClusterNetwork + VlanConfig first to get the bond, then point the ProviderNetwork at the bond interface.

### Underlay limitations

From the [Kube-OVN underlay docs](https://kubeovn.github.io/docs/v1.16.x/en/start/underlay/):

> *"L3 functions such as SNAT/EIP, distributed gateway/centralized gateway in Overlay mode cannot be used. VPC level isolation is also not available for underlay subnet."*

### Sources

- [#9464 -- Phase 2 Epic](https://github.com/harvester/harvester/issues/9464)
- [#7834 -- L3 connectivity on user-defined cluster network](https://github.com/harvester/harvester/issues/7834) (closed, delivered)
- [#10154 -- Directly routable VM IPs on physical VLAN](https://github.com/harvester/harvester/issues/10154) (open)
- [Kube-OVN Underlay Installation](https://kubeovn.github.io/docs/v1.16.x/en/start/underlay/)

---

## Microsegmentation via OVN

### Short answer

Microsegmentation is supported since Phase 1 (Harvester v1.6.x) on **overlay networks**. Two mechanisms are available, both implemented as OVN ACLs under the hood.

### Mechanism 1: Kubernetes NetworkPolicy (recommended)

From [#7381](https://github.com/harvester/harvester/issues/7381) (closed, shipped):

> *"KubeOVN makes use of Kubernetes Network Policy CRD to implement ACL rules allowing/restricting traffic between VMs."*

VMs are labeled, and standard Kubernetes `NetworkPolicy` selects them:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: isolate-frontend
spec:
  podSelector:
    matchLabels:
      vm-role: frontend
  ingress:
    - from:
        - ipBlock:
            cidr: 10.10.0.0/16
  egress:
    - to:
        - ipBlock:
            cidr: 20.20.0.0/16
```

Kube-OVN translates these into OVN primitives:
- **Port Groups** -- group logical switch ports by pod selector
- **Address Sets** -- collect IP ranges from ipBlock/namespaceSelector
- **ACLs** -- allow rules at priority 2001, default deny at priority 2000

The operator enables this via `ComponentSpec.EnableNP: true` (default).

### Mechanism 2: Subnet ACLs (raw OVN match expressions)

Also from [#7381](https://github.com/harvester/harvester/issues/7381):

> *"KubeOVN subnet acl can be used to isolate traffic between VMs within the same subnet."*

```yaml
apiVersion: kubeovn.io/v1
kind: Subnet
metadata:
  name: isolated-subnet
spec:
  cidrBlock: 10.10.0.0/24
  allowEWTraffic: false          # block all east-west by default
  acls:
    - action: drop
      direction: to-lport
      match: "ip4.dst == 10.10.0.2 && ip"
      priority: 1002
    - action: allow-related
      direction: from-lport
      match: "ip4.src == 10.10.0.3 && ip"
      priority: 1002
```

The `match` field uses raw OVN ACL syntax (`ip4.src`, `ip4.dst`, `tcp.dst`, etc.). `allowEWTraffic: false` provides default-deny within the subnet.

**Gotcha:** Do not block the gateway IP in ACL rules. Bug [#8935](https://github.com/harvester/harvester/issues/8935) documents that blocking the gateway causes VM creation failures because DHCP cannot reach the gateway during pod setup (6-minute timeout, then eventual failure or flaky creation).

### Mechanism 3: AdminNetworkPolicy (cluster-scoped)

The operator CRD includes `ComponentSpec.EnableANP: bool` (default: false). When enabled, Kube-OVN supports Kubernetes `AdminNetworkPolicy` resources -- cluster-scoped policies that apply across namespaces without requiring per-namespace `NetworkPolicy` objects.

### GUI support

Issue [#8683](https://github.com/harvester/harvester/issues/8683) (closed, shipped) added Harvester UI support for managing network policies.

### Which mechanism to use

From the [Kube-OVN NetworkPolicy docs](https://kubeovn.github.io/docs/v1.16.x/en/guide/networkpolicy/):

> *"These mechanisms are all implemented through OVN ACLs at the underlying level. Using multiple access control mechanisms simultaneously may lead to complex rule management and priority conflicts. It is recommended not to use multiple access control rules simultaneously."*

| Mechanism | Scope | When to use |
|---|---|---|
| **NetworkPolicy** | Namespace-scoped, pod label selectors | Standard Kubernetes-native microsegmentation between VMs |
| **Subnet ACL** | Subnet-wide, raw OVN match syntax | Fine-grained L3/L4 rules within a single subnet |
| **AdminNetworkPolicy** | Cluster-scoped | Platform-level guardrails across all namespaces |
| **Security Groups** | Per-pod annotation, tiered evaluation | AWS-style SG model with priority tiers (available via Kube-OVN CRD, not yet exposed in Harvester UI) |

### Underlay + microsegmentation caveat

The Kube-OVN underlay docs state that NetworkPolicy/Service is available on underlay subnets (via OVS flow tables), but VPC-level isolation is explicitly not supported. Subnet ACLs and NetworkPolicy should work on underlay subnets, but this is not explicitly confirmed for Harvester's integration. Issue [#10154](https://github.com/harvester/harvester/issues/10154) includes community testing of network policies on underlay VMs.

### Sources

- [#7397 -- SDN Epic (Phase 1)](https://github.com/harvester/harvester/issues/7397) -- microsegmentation listed as core goal
- [#7381 -- NetworkPolicy for microsegmentation](https://github.com/harvester/harvester/issues/7381) (closed, shipped)
- [#8683 -- GUI for network policies](https://github.com/harvester/harvester/issues/8683) (closed, shipped)
- [#8935 -- Subnet ACL gateway blocking bug](https://github.com/harvester/harvester/issues/8935) (closed)
- [Configuration CRD](https://github.com/harvester/kubeovn-operator/blob/main/api/v1/configuration_types.go) -- `EnableNP`, `EnableANP`
- [Kube-OVN NetworkPolicy](https://kubeovn.github.io/docs/v1.16.x/en/guide/networkpolicy/)
- [Kube-OVN Security Groups](https://kubeovn.github.io/docs/v1.16.x/en/vpc/security-group/)
- [Kube-OVN Underlay](https://kubeovn.github.io/docs/v1.16.x/en/start/underlay/)
