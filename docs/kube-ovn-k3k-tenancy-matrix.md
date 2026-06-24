# 📋 Kube-OVN & k3k Shared Mode Tenancy Matrix

This reference document outlines the operational boundaries, administrative permissions, and control hierarchies when using **Kube-OVN** as the host CNI alongside **k3k** virtual clusters in shared mode.

---

## 🏛️ Architectural Context

In a `k3k` shared-mode architecture, guest cluster control planes and virtual workloads run as host pods inside dedicated host-level namespaces (`k3k-<tenant-name>`) ([k3k Shared Mode Architecture](https://github.com/rancher/k3k)). 

Because guest workloads share the host node's kernel and network namespace, administrative capabilities for cluster-scoped networking resources are centralized on the **Core (Host) Cluster** ([Kube-OVN Subnets](https://kubeovn.github.io/docs/v1.12.x/guide/subnet/)), while standard namespaced resources are delegated to the **Tenant (Guest) Cluster** ([Kubernetes Namespaced Resources](https://kubernetes.io/docs/concepts/overview/working-with-objects/namespaces/)).

---

## 📊 Tenancy Control Matrix

The following matrix defines which level of cluster holds authority over networking and orchestration resources:

| Object / Resource Type | API Scope | Core (Host) Cluster Control | Tenant (Guest) Cluster Control | Synchronization & Enforcement Mechanism |
| :--- | :--- | :--- | :--- | :--- |
| **Virtual Private Clouds (`Vpc`)** | Cluster | **Full Control:** Provisions VPC logical routers, routing tables, and peerings ([Kube-OVN VPCs](https://kubeovn.github.io/docs/v1.12.x/guide/vpc/)). | **No Access:** Unaware of underlying physical/logical VPC routers. | Handled via the core cluster's OVN logical database controller ([Kube-OVN VPCs](https://kubeovn.github.io/docs/v1.12.x/guide/vpc/)). |
| **Subnets (`Subnet`)** | Cluster | **Full Control:** Defines subnet IP ranges, gateways, DNS, and VPC associations ([Kube-OVN Subnets](https://kubeovn.github.io/docs/v1.12.x/guide/subnet/)). | **No Access:** Cannot directly register or modify subnets. | Managed centrally by Kube-OVN on the host to prevent IP exhaustion or conflicts ([Kube-OVN Subnets](https://kubeovn.github.io/docs/v1.12.x/guide/subnet/)). |
| **VPC Peering (`VpcPeering`)** | Cluster | **Full Control:** Establishes tunnels and point-to-point links between tenant routers ([Kube-OVN VPCs](https://kubeovn.github.io/docs/v1.12.x/guide/vpc/)). | **No Access:** Cannot configure inter-VPC routing. | Peerings are compiled into OVS logical patch ports inside the OVN DB ([Kube-OVN VPCs](https://kubeovn.github.io/docs/v1.12.x/guide/vpc/)). |
| **Workload Pods & Deployments** | Namespaced | **Indirect Execution:** Runs guest container runtimes as mirrored host pods ([k3k Shared Mode Architecture](https://github.com/rancher/k3k)). | **Full Control:** Schedules and manages pod configurations inside virtual spaces ([Kubernetes Pods](https://kubernetes.io/docs/concepts/workloads/pods/)). | Mirroring is managed by the `k3k` virtual kubelet controller ([k3k Shared Mode Architecture](https://github.com/rancher/k3k)). |
| **Subnet Bindings (Annotations)** | Metadata | **Enforcer:** Binds mirrored host pod interfaces to target logical switches ([Kube-OVN Pod-Subnet Bind](https://kubeovn.github.io/docs/v1.12.x/guide/subnet/#bind-pods-to-subnet)). | **Delegated Control:** Annotates guest pods or guest namespaces with subnet targets ([Kube-OVN Pod-Subnet Bind](https://kubeovn.github.io/docs/v1.12.x/guide/subnet/#bind-pods-to-subnet)). | `k3k` replicates metadata annotations from the virtual pod spec to the host pod spec during mirroring ([k3k Shared Mode Architecture](https://github.com/rancher/k3k)). |
| **Logical IP Tracking (`IP`)** | Cluster | **Full Control:** Tracks and allocates all IP interfaces globally. | **Read-Only:** Retrieves assigned pod IPs through standard status commands ([Kube-OVN IP Resource](https://kubeovn.github.io/docs/v1.12.x/guide/subnet/)). | Assigned host pod IPs are mirrored back to guest pod status definitions ([k3k Shared Mode Architecture](https://github.com/rancher/k3k)). |
| **Network Security Policies (`NetworkPolicy`)** | Namespaced | **Full Control:** Enforces core-level rules directly on host namespaces ([Kubernetes Network Policies](https://kubernetes.io/docs/concepts/services-networking/network-policies/)). | **Disabled / Offloaded:** Standard guest network policies are bypassed ([k3k Shared Mode Architecture](https://github.com/rancher/k3k)). | Guest network policy is bypassed (`--disable-network-policy`) to offload all filtering to Kube-OVN host-level Port ACLs ([k3k Shared Mode Architecture](https://github.com/rancher/k3k)). |
| **Kubernetes Services & Ingress** | Namespaced | **No Control:** Uninvolved in guest endpoint resolution or internal guest routing. | **Full Control:** Creates virtual `Services` and ingress configurations inside the guest cluster ([Kubernetes Services](https://kubernetes.io/docs/concepts/services-networking/service/)). | Guest cluster manages its own local Service CIDR blocks independently of the host cluster network ([k3k Shared Mode Architecture](https://github.com/rancher/k3k)). |

---

## 🔍 Detailed Resource Delegation Analysis

### 1. Network Boundary Controls (VPC, Subnet, Peering)
*   **Administrative Separation:** Under Kube-OVN, logical network segmentation relies on cluster-scoped custom resource definitions (`vpcs.kubeovn.io` and `subnets.kubeovn.io`) ([Kube-OVN VPCs](https://kubeovn.github.io/docs/v1.12.x/guide/vpc/)). Because tenant administrators only interact with namespaced objects in their virtual control plane, they have zero write access to these physical router mappings.
*   **The Delegate Pattern:** Tenant admins retain control over workload routing indirectly by applying standard OVN annotations to their guest workloads, such as `ovn.kubernetes.io/logical_switch: <subnet_name>` ([Kube-OVN Pod-Subnet Bind](https://kubeovn.github.io/docs/v1.12.x/guide/subnet/#bind-pods-to-subnet)).

### 2. Workload and Metadata Orchestration
*   **Shared Kernel Execution:** In shared-mode, guest pods are scheduled as host processes inside the host namespace `k3k-<tenant-name>` ([k3k Shared Mode Architecture](https://github.com/rancher/k3k)).
*   **Virtual Kubelet Mirroring:** The `k3k-kubelet` daemon bridges the api-server boundaries. When a pod is scheduled inside the virtual cluster, the virtual kubelet captures the spec, preserves annotations, and requests a mirrored pod creation from the host api-server ([k3k Shared Mode Architecture](https://github.com/rancher/k3k)).

### 3. Policy and Security Boundaries
*   **Offloading Policy Compilation:** Running overlapping network policy engines inside both the guest and the host cluster kernel can cause routing deadlocks and IPTables state-machine corruption. Consequently, `k3k` recommends disabling guest-level network policies via `--disable-network-policy` ([k3k Shared Mode Architecture](https://github.com/rancher/k3k)).
*   **Host-Level OVS Compilation:** The core cluster administrator applies `NetworkPolicies` inside the host namespace `k3k-<tenant-name>`. These are compiled by Kube-OVN directly into OVS Port ACLs on the host nodes, securing traffic before it reaches the VM or guest environment ([Kubernetes Network Policies](https://kubernetes.io/docs/concepts/services-networking/network-policies/)).

### 4. Multi-Tenant L3 Isolation Security Boundaries (Experimentation Findings)
*   **The Annotation Breakthrough Vulnerability:** In experimentation mode, we evaluated what happens if a guest workload running in virtual namespace `tenant-a` attempts to bind to the logical switch of `tenant-b` (configured in [breakthrough-pod.yaml](../manifests/egress-gateway-experiment/breakthrough-pod.yaml)). By applying the annotation `ovn.kubernetes.io/logical_switch: subnet-tenant-b` to a pod inside the `tenant-a` virtual guest namespace, the pod successfully bypassed the VPC boundaries, obtained an IP from `subnet-tenant-b` (`10.20.0.0/16`), and successfully pinged workloads running inside Tenant B.
*   **The Root Cause (Co-location):** Under `k3k` shared-mode, all guest namespaces are mapped directly onto the host and co-located in a single host-level namespace: `k3k-kube-ovn-cluster` (configured in [cluster.yaml#L5](../manifests/k3k/cluster.yaml#L5)).
*   **Host-Level Subnet Restriction Gap:** While Kube-OVN supports restricting subnet usage to specific namespaces via the `spec.namespaces` field in the `Subnet` CRD ([Kube-OVN Global Subnets](https://kubeovn.github.io/docs/v1.12.x/guide/subnet/)), this validation is executed by the host Kube-OVN admission webhook and only checks the **host pod's** namespace. Since all virtual pods from all tenants map to the same host namespace `k3k-kube-ovn-cluster` ([cluster.yaml#L5](manifests/k3k/cluster.yaml#L5)), restricting a subnet to this namespace permits **all** virtual tenants to access it, rendering native Kube-OVN subnet-to-namespace filtering completely ineffective for virtual tenant separation.
*   **Blind k3k Synchronization:** The `k3k-kubelet` controller blindly synchronizes guest pod metadata, copying annotations directly from the virtual pod specification to the host pod specification ([k3k Shared Mode Architecture](https://github.com/rancher/k3k)). It lacks any native mechanism to strip or validate network annotations based on the guest namespace context.
*   **Kubernetes RBAC Limitation:** Standard Kubernetes RBAC inside the virtual cluster has no field-level or annotation-level validation capabilities ([Kubernetes Namespaced Resources](https://kubernetes.io/docs/concepts/overview/working-with-objects/namespaces/)); it can only authorize or deny pod creation globally for a user, not restrict specific annotation values.
*   **Verdict:** Without custom/3rd-party validating webhook engines (such as Kyverno or OPA/Gatekeeper), **strict L3 multi-tenant isolation is natively unenforceable in k3k shared-mode.** To achieve secure isolation using only 100% native out-of-the-box configurations, you must either transition to **non-shared virtual clusters** (dedicated isolated nodes) or deploy workloads directly into separate **host-level namespaces** without using k3k.

---

## 📚 Sources & References

*   **Kube-OVN Virtual Private Clouds:** [Kube-OVN VPC Guide](https://kubeovn.github.io/docs/v1.12.x/guide/vpc/)
*   **Kube-OVN Global Subnets:** [Kube-OVN Subnet Guide](https://kubeovn.github.io/docs/v1.12.x/guide/subnet/)
*   **Kube-OVN Pod-to-Subnet Binding:** [Kube-OVN Pod Subnet Binding Annotation Reference](https://kubeovn.github.io/docs/v1.12.x/guide/subnet/#bind-pods-to-subnet)
*   **Rancher k3k Virtual Cluster Engine:** [k3k GitHub Repository](https://github.com/rancher/k3k)
*   **Kubernetes NetworkPolicies:** [Kubernetes Official NetworkPolicy Documentation](https://kubernetes.io/docs/concepts/services-networking/network-policies/)
*   **Kubernetes Namespace Boundaries:** [Kubernetes Namespaces Concept Reference](https://kubernetes.io/docs/concepts/overview/working-with-objects/namespaces/)

