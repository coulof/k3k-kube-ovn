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
  echo -e "\033[1;31mRemoving VPC Peering and static routes from VPC specs...\033[0m"
  kubectl patch vpc vpc-tenant-a -p '{"spec":{"vpcPeerings":null,"staticRoutes":null}}' --type=merge 2>/dev/null || true
  kubectl patch vpc vpc-tenant-b -p '{"spec":{"vpcPeerings":null,"staticRoutes":null}}' --type=merge 2>/dev/null || true
}

function secure() {
  echo -e "\033[1;35mApplying high-priority Subnet ACL on 'subnet-tenant-b' to drop tenant-a traffic...\033[0m"
  kubectl patch subnet subnet-tenant-b --type='merge' -p '{"spec":{"acls":[{"action":"drop","direction":"to-lport","match":"ip4.src == 10.10.0.0/16","priority":4000}]}}'
}

function unsecure() {
  echo -e "\033[1;36mRemoving Subnet ACL from 'subnet-tenant-b' (Restoring full peering connectivity)...\033[0m"
  kubectl patch subnet subnet-tenant-b --type='merge' -p '{"spec":{"acls":null}}'
}

function status() {
  echo -e "\033[1;34m=== VPC PEERING SPECS ===\033[0m"
  kubectl get vpc vpc-tenant-a vpc-tenant-b -o custom-columns=NAME:.metadata.name,PEERINGS:.status.vpcPeerings
  echo
  echo -e "\033[1;34m=== ACTIVE SUBNET ACL RULES (subnet-tenant-b) ===\033[0m"
  kubectl get subnet subnet-tenant-b -o custom-columns=NAME:.metadata.name,ACLS:.spec.acls
}

# Display the menu on startup
menu
