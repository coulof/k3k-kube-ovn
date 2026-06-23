# Persistent Project Memory & Context Rules

This repository maintains a unified stack of SUSE cloud-native components (RKE2, Kube-OVN, k3k, cert-manager, Rancher Prime) in a multi-VM development environment managed by Lima.

---

## 🏗️ Architectural Core Concepts

### 1. Networking and IP Mapping
* **Host Pod network (RKE2 default):** `10.42.0.0/16`
* **Host Service network:** `10.43.0.0/16`
* **Virtual Cluster (vCluster) Pod network:** `10.16.0.0/16`
* **Virtual Cluster Service network:** `10.96.0.0/12`
* **Kube-OVN Join network:** `100.64.0.0/16`

### 2. DNS & Hostname Routing (The `.localhost` Standard)
To achieve complete zero-configuration local browser access from macOS without requiring administrative rights:
* **Host Domain Name:** **`lima-rancher-prime.localhost`**
* **Port Forwarding:** macOS port `8443` is forwarded by Lima to guest `443` in the `rancher-prime` VM.
* **Mac Resolution:** macOS natively resolves `.localhost` subdomains to `127.0.0.1`.
* **Guest Collision Resolution:** Under RFC 6761, modern guest client libraries and runtimes hardcode `.localhost` to `127.0.0.1` (loopback). To bypass this inside the `k3k-kube-ovn` guest VM, the background service **`rancher-hosts-sync.service`** maps `lima-rancher-prime.localhost` to the correct IP inside `/etc/hosts` AND runs `socat` on port `443` of the loopback interface, tunneling the traffic over the `user-v2` network to Rancher Prime.

### 3. Guest VM Permissions
To prevent conflicts with host-mounted home directories and read-only volume mounts:
* Both K3s and RKE2 write-modes must be set to `644` (making `k3s.yaml` and `rke2.yaml` readable).
* Profile helper scripts `/etc/profile.d/k3s.sh` and `/etc/profile.d/rke2.sh` are set up in the guest OS to automatically export `KUBECONFIG` to `/etc/rancher/k3s/k3s.yaml` or `/etc/rancher/rke2/rke2.yaml`, respectively. This allows the `lima` user to run `kubectl` out of the box.

### 4. Credentials & Security
* Never commit `.env` credentials files to Git.
* Sourcing `RANCHER_BOOTSTRAP_PASSWORD` dynamically from `.env` inside mounted directories on first boot is the source of truth for passwords.

---

## 🛠️ Behavioral Guidelines for Future AI Assistants

* **Always preserve CNI bootstrapping flow:** Kube-OVN is installed imperatively over a `cni: none` RKE2 setup to resolve scheduling deadlocks before syncing declarative manifests.
* **Do not edit host `/etc/hosts`:** Maintain the `.localhost` and dynamic `rancher-hosts-sync` model to keep setups administrative-free.
* **Maintain profile profile files:** Always respect guest VM-specific `/etc/profile.d/` configurations to prevent `KUBECONFIG` conflicts.
