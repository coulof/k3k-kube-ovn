# Bringing External Multicast Traffic into a Harvester Cluster with Kube-OVN

## Problem Statement

A Harvester HCI cluster running Kube-OVN needs to receive multicast traffic (e.g. video streams, financial market data, sensor feeds) from an external source on the physical network. This document covers the two main connectivity models -- NAT and BGP -- and explains why both converge on the same underlying mechanism.

## TL;DR

You cannot NAT multicast, and BGP does not carry multicast routing. In both cases the answer is the same: use a **Kube-OVN underlay subnet** with **`enableMulticastSnoop: true`** on a VLAN that extends the physical multicast domain into the cluster.

## Background: Kube-OVN Multicast Snooping

Kube-OVN exposes IGMP/MLD snooping through the Subnet CRD. When enabled, it configures the following OVN Northbound DB options on the backing Logical Switch:

| OVN Option | Effect |
|---|---|
| `mcast_snoop` | Enables IGMP (IPv4) / MLD (IPv6) snooping on the logical switch |
| `mcast_querier` | Switch sends periodic IGMP/MLD queries to keep group memberships alive |
| `mcast_flood_unregistered` | Floods multicast for groups with no known listener (default: false) |
| `mcast_flood` (per-port) | Unconditionally forwards all multicast to a specific port (useful for uplinks) |

When snooping is enabled, Kube-OVN automatically allocates a querier IP and MAC on the subnet (`status.mcastQuerierIP`, `status.mcastQuerierMAC`).

**Verify on a running cluster:**

```bash
kubectl explain subnet.spec.enableMulticastSnoop
kubectl get subnet <name> -o jsonpath='{.status.mcastQuerierIP}'
```

### Sources

- Subnet CRD: [`pkg/apis/kubeovn/v1/subnet.go`](https://github.com/kubeovn/kube-ovn/blob/master/pkg/apis/kubeovn/v1/subnet.go) -- `EnableMulticastSnoop` field
- Controller implementation: [`pkg/controller/subnet.go`](https://github.com/kubeovn/kube-ovn/blob/master/pkg/controller/subnet.go) -- `acquireMcastQuerierIP`, `handleMcastQuerierChange`, `mcast_flood`
- OVN NB schema: [ovn-nb(5)](https://man7.org/linux/man-pages/man5/ovn-nb.5.html) -- `Logical_Switch` options, `Logical_Switch_Port` options

## NAT Case

### Why NAT cannot carry multicast

NAT (SNAT/DNAT) relies on connection tracking -- a stateful mapping between a source and a single destination. Multicast is one-to-many and stateless:

- There is no single destination IP to DNAT to (the destination is a group address like `239.x.x.x`)
- Conntrack cannot track IGMP joins/leaves
- SNAT rewrites the source, breaking RPF (Reverse Path Forwarding) checks that PIM routers rely on

### Solution: bypass NAT with an underlay subnet

Instead of routing multicast through an overlay + NAT, place the receiving pods/VMs directly on the physical multicast VLAN via an underlay subnet.

```
External Multicast Source
        |
  Physical Switch (trunk port, VLAN 100, PIM/IGMP enabled)
        |
  Harvester Node NIC (bond0 / eth1)
        |
  OVS Bridge (br-provider1)
        |
  Kube-OVN Underlay Subnet (enableMulticastSnoop: true)
        |
  Pod / VM joins multicast group (IGMP join)
        |
  Multicast frames delivered via OVN logical switch
```

#### Manifests

```yaml
# 1. Provider network -- maps to the physical NIC on Harvester nodes
apiVersion: kubeovn.io/v1
kind: ProviderNetwork
metadata:
  name: provider-multicast
spec:
  defaultInterface: bond1   # NIC carrying the multicast VLAN

---
# 2. VLAN -- tags traffic on the provider network
apiVersion: kubeovn.io/v1
kind: Vlan
metadata:
  name: vlan100
spec:
  id: 100
  provider: provider-multicast

---
# 3. Underlay subnet with multicast snooping
apiVersion: kubeovn.io/v1
kind: Subnet
metadata:
  name: multicast-underlay
spec:
  protocol: IPv4
  cidrBlock: 192.168.100.0/24
  gateway: 192.168.100.1
  vlan: vlan100
  enableMulticastSnoop: true
  # No NAT -- underlay subnets cannot use SNAT/EIP
  natOutgoing: false
```

### Important limitation

L3 overlay features are unavailable on underlay subnets:

> *"L3 functions such as SNAT/EIP, distributed gateway/centralized gateway in Overlay mode cannot be used."*
>
> -- [Underlay Installation](https://kubeovn.github.io/docs/v1.16.x/en/start/underlay/)

Pods on this subnet communicate at L2 with the physical network. If they also need internet egress, attach a second interface on an overlay subnet with NAT, or route through the physical gateway.

### Physical switch requirements

- The switch port facing each Harvester node must be a **trunk port** carrying the multicast VLAN
- **IGMP snooping** should be enabled on the switch so multicast is only forwarded to ports with listeners
- If the multicast source is on a different L3 segment, the upstream router needs **PIM** (or static IGMP joins) on the interface facing the Harvester VLAN

## BGP Case

### Why BGP alone cannot deliver multicast

Kube-OVN's BGP integration (`kube-ovn-speaker`) uses GoBGP to **advertise** routes to external peers:

- Pod IPs, Subnet CIDRs, ClusterIP Services, EIPs
- Announcement only -- it does not learn or import routes from peers

> *No mention exists regarding inbound route learning or integration with external routing tables.*
>
> -- [BGP Support](https://kubeovn.github.io/docs/v1.16.x/en/advance/with-bgp/)

Standard BGP carries unicast NLRI (Network Layer Reachability Information). Multicast routing uses separate protocols (PIM, IGMP, MSDP) that operate independently of BGP unicast.

### Solution: BGP for unicast reachability + underlay for multicast

Use BGP to solve the unicast part (making pod subnets routable from outside), and an underlay VLAN for the multicast data plane:

```
                      BGP session
kube-ovn-speaker ◄──────────────────► Upstream Router
  (advertises pod/subnet CIDRs)           |
                                     PIM / IGMP
                                          |
                                    Physical Switch
                                     (VLAN trunk)
                                          |
                                    Harvester Node
                                          |
                                    OVS br-provider
                                          |
                              Underlay Subnet (mcast snoop)
                                          |
                                    Pod / VM
```

1. **BGP** ensures the upstream router knows how to reach pod IPs (for unicast return traffic, control plane, etc.)
2. **Underlay subnet** with `enableMulticastSnoop: true` provides the L2 path for actual multicast frame delivery
3. The **upstream router** must run PIM on the VLAN interface so the multicast distribution tree extends into the cluster

### What about EVPN?

Kube-OVN has experimental BGP/EVPN support on egress gateways. EVPN type-2 (MAC/IP) and type-3 (Inclusive Multicast) routes could theoretically unify unicast and multicast delivery over VXLAN. However:

> *"L3VPN is implemented; L2VPN is not yet supported."*
> *"FRR hot reload is not supported."*
> *"BFD for BGP is not supported."*
>
> -- [Egress Gateway BGP/EVPN](https://kubeovn.github.io/docs/v1.16.x/en/vpc/vpc-egress-gateway-bgp-evpn/)

EVPN L2VPN would be the clean answer for multicast-over-BGP, but it is not production-ready in Kube-OVN today.

## Harvester-Specific Considerations

Harvester uses **Multus + Bridge CNI** for VM VLAN networks. The physical NIC is bonded and trunked to carry multiple VLANs. This maps naturally to Kube-OVN's ProviderNetwork + VLAN model:

| Harvester concept | Kube-OVN equivalent |
|---|---|
| ClusterNetwork (bond) | ProviderNetwork (`spec.defaultInterface`) |
| VM Network (VLAN) | Vlan + underlay Subnet |
| Bridge CNI attachment | OVS bridge `br-<provider>` with localnet port |

For multicast specifically:

- The Harvester ClusterNetwork bond must carry the multicast VLAN as a trunk member
- The physical switch must have IGMP snooping enabled on that VLAN
- VMs attached to the underlay subnet issue IGMP joins; OVN snooping forwards matching multicast to their ports only

Source: [Harvester Networking Deep Dive](https://docs.harvesterhci.io/v1.4/networking/deep-dive)

## Summary Table

| Approach | Multicast data path | What to configure | Limitation |
|---|---|---|---|
| **NAT** | Cannot NAT multicast; bypass with underlay | Underlay subnet + `enableMulticastSnoop: true` + VLAN to physical multicast network | No SNAT/EIP on underlay subnets |
| **BGP** | BGP for unicast only; multicast still needs L2 | BGP for route ads + underlay subnet + IGMP + PIM on upstream router | `kube-ovn-speaker` is advertisement-only; no route import |
| **EVPN** | Could unify both via type-2/type-3 routes | Egress gateway with `bgpConf` + `evpnConf` | Experimental; L2VPN not yet supported |
| **Common denominator** | **Underlay subnet with multicast snooping on a VLAN trunk** | ProviderNetwork + Vlan + Subnet + physical switch IGMP/PIM | Physical network must extend multicast domain to Harvester nodes |

## References

- [Kube-OVN Underlay Installation](https://kubeovn.github.io/docs/v1.16.x/en/start/underlay/)
- [Kube-OVN BGP Support](https://kubeovn.github.io/docs/v1.16.x/en/advance/with-bgp/)
- [Kube-OVN Egress Gateway BGP/EVPN](https://kubeovn.github.io/docs/v1.16.x/en/vpc/vpc-egress-gateway-bgp-evpn/)
- [OVN Northbound DB -- mcast_snoop options](https://man7.org/linux/man-pages/man5/ovn-nb.5.html)
- [Harvester Networking Deep Dive](https://docs.harvesterhci.io/v1.4/networking/deep-dive)
- [Kube-OVN Subnet CRD source](https://github.com/kubeovn/kube-ovn/blob/master/pkg/apis/kubeovn/v1/subnet.go)
