# File: manifests/vpc-peering-experiment/controller-helpers.sh
# Purpose: Interactive bash helpers and shortcuts for the Kube-OVN & k3k Peering Demo

# Clean prompt
export PS1="\033[1;33mpeering-demo-control\033[0m$ "

function menu() {
  clear
  echo -e "\033[1;33m=============================================================\033[0m"
  echo -e "\033[1;33m        KUBE-OVN & K3K MULTI-TENANT PEERING CONTROLLER       \033[0m"
  echo -e "\033[1;33m=============================================================\033[0m"
  echo -e "Use the following simple commands to steer the interactive demo:"
  echo
  echo -e "  \033[1;32mpeer\033[0m        -> Establish VPC Peering (Phase 2)"
  echo -e "  \033[1;31munpeer\033[0m      -> Tear down VPC Peering (Phase 1 baseline)"
  echo -e "  \033[1;35msecure\033[0m      -> Apply Host NetworkPolicy to block peering (Phase 3)"
  echo -e "  \033[1;36munsecure\033[0m    -> Remove Host NetworkPolicy (Restore full peering)"
  echo -e "  \033[1;34mstatus\033[0m      -> Print current resource status"
  echo -e "  \033[1;37mmenu\033[0m        -> Show this menu again"
  echo
  echo -e "\033[1;33m=============================================================\033[0m"
  echo -e "Type a command above and press Enter!"
  echo
}

function peer() {
  echo -e "\033[1;32mApplying VPC Peering configuration...\033[0m"
  kubectl apply -f manifests/vpc-peering-experiment/peering.yaml
}

function unpeer() {
  echo -e "\033[1;31mDeleting VPC Peering configuration...\033[0m"
  kubectl delete -f manifests/vpc-peering-experiment/peering.yaml --wait=false 2>/dev/null || true
}

function secure() {
  echo -e "\033[1;35mApplying Host-Level NetworkPolicy inside namespace 'k3k-tenant-b'...\033[0m"
  kubectl apply -f manifests/vpc-peering-experiment/networkpolicy.yaml
}

function unsecure() {
  echo -e "\033[1;36mRemoving Host-Level NetworkPolicy from namespace 'k3k-tenant-b'...\033[0m"
  kubectl delete -f manifests/vpc-peering-experiment/networkpolicy.yaml --wait=false 2>/dev/null || true
}

function status() {
  echo -e "\033[1;34m=== VPC PEERING SPECS ===\033[0m"
  kubectl get vpc vpc-tenant-a vpc-tenant-b -o custom-columns=NAME:.metadata.name,PEERINGS:.status.vpcPeerings
  echo
  echo -e "\033[1;34m=== ACTIVE NETWORKPOLICIES IN k3k-tenant-b ===\033[0m"
  kubectl get networkpolicy -n k3k-tenant-b
}

# Display the menu on startup
menu
