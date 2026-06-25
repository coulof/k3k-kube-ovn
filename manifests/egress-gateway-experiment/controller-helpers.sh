# File: manifests/egress-gateway-experiment/controller-helpers.sh
# Purpose: Interactive bash helpers and shortcuts for Kube-OVN Egress Gateway Control Panel

# Enforce tmux-256color terminal type for high-fidelity interactive display
export TERM=tmux-256color

# Source system-wide RKE2 profiles for correct KUBECONFIG and kubectl paths
[ -f /etc/profile.d/rke2.sh ] && source /etc/profile.d/rke2.sh

# Fix backspace key mapping inside VM tmux session
stty erase '^?' 2>/dev/null

# Clean prompt
export PS1="\033[1;36megress-control\033[0m$ "

function menu() {
  clear
  echo -e "\033[1;36m=============================================================\033[0m"
  echo -e "\033[1;36m       KUBE-OVN MULTI-VPC EGRESS GATEWAY CONTROLLER         \033[0m"
  echo -e "\033[1;36m=============================================================\033[0m"
  echo -e "Use the following interactive commands to steer the egress gateway:"
  echo
  echo -e "  \033[1;32menable\033[0m          -> Deploy VpcEgressGateway (gateway-tenant-a)"
  echo -e "  \033[1;31mdisable\033[0m         -> Tear down VpcEgressGateway (gateway-tenant-a)"
  echo -e "  \033[1;32mlaunch [a|b]\033[0m    -> Launch tenant workloads (alias: start | default: both)"
  echo -e "  \033[1;31mstop [a|b]\033[0m      -> Stop tenant workloads (default: both)"
  echo -e "  \033[1;33mbreakthrough\033[0m    -> Deploy Tenant A breakthrough-pod (using Tenant B subnet)"
  echo -e "  \033[1;31munbreakthrough\033[0m  -> Terminate Tenant A breakthrough-pod"
  echo -e "  \033[1;34mstatus\033[0m          -> Display egress gateways and active workloads"
  echo -e "  \033[1;35mmenu\033[0m            -> Show this helper menu again"
  echo
  echo -e "\033[1;36m=============================================================\033[0m"
  echo -e "Type a command above and press Enter!"
  echo
}

function enable() {
  echo -e "\033[1;32mApplying VpcEgressGateway configuration for Tenant A...\033[0m"
  cat <<EOF | kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml apply -f -
apiVersion: kubeovn.io/v1
kind: VpcEgressGateway
metadata:
  name: gateway-tenant-a
  namespace: default
spec:
  vpc: vpc-tenant-a
  replicas: 1
  externalSubnet: external-egress-subnet
  internalSubnet: subnet-tenant-a
  externalIPs:
  - 192.168.105.70
  policies:
  - snat: true
    subnets:
    - subnet-tenant-a
EOF
}

function disable() {
  echo -e "\033[1;31mRemoving VpcEgressGateway 'gateway-tenant-a'...\033[0m"
  kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml delete vpc-egress-gateway gateway-tenant-a --ignore-not-found=true
}

function breakthrough() {
  echo -e "\033[1;33mDeploying breakthrough-pod in Tenant A namespace pointing to Tenant B subnet...\033[0m"
  kubectl --kubeconfig tenant-a.yaml apply -f manifests/egress-gateway-experiment/breakthrough-pod.yaml
}

function unbreakthrough() {
  echo -e "\033[1;31mRemoving breakthrough-pod from Tenant A namespace...\033[0m"
  kubectl --kubeconfig tenant-a.yaml delete -f manifests/egress-gateway-experiment/breakthrough-pod.yaml --ignore-not-found=true
}

function status() {
  echo -e "\033[1;34m=== KUBE-OVN VPC EGRESS GATEWAYS ===\033[0m"
  kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml get veg -o custom-columns=NAME:.metadata.name,VPC:.spec.vpc,EXT-SUBNET:.spec.externalSubnet,EXT-IPS:.spec.externalIPs,PHASE:.status.phase,READY:.status.ready
  echo
  echo -e "\033[1;34m=== ACTIVE GATEWAY PODS ===\033[0m"
  kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml get pods -n default -l app=vpc-egress-gateway -o custom-columns=NAME:.metadata.name,STATUS:.status.phase,IP:.status.podIP,NODE:.spec.nodeName
  echo
  echo -e "\033[1;34m=== TENANT-A VIRTUAL POD WORKLOADS ===\033[0m"
  kubectl --kubeconfig tenant-a.yaml get pods -n tenant-a -o wide
  echo
  echo -e "\033[1;34m=== TENANT-B VIRTUAL POD WORKLOADS ===\033[0m"
  kubectl --kubeconfig tenant-b.yaml get pods -n tenant-b -o wide
}

function start() {
  local target="${1:-all}"
  if [ "$target" = "a" ] || [ "$target" = "tenant-a" ] || [ "$target" = "all" ]; then
    echo -e "\033[1;32mLaunching Tenant A workloads...\033[0m"
    kubectl --kubeconfig tenant-a.yaml apply -f manifests/egress-gateway-experiment/workloads-tenant-a.yaml
  fi
  if [ "$target" = "b" ] || [ "$target" = "tenant-b" ] || [ "$target" = "all" ]; then
    echo -e "\033[1;32mLaunching Tenant B workloads...\033[0m"
    kubectl --kubeconfig tenant-b.yaml apply -f manifests/egress-gateway-experiment/workloads-tenant-b.yaml
  fi
}

function launch() {
  start "$@"
}

function stop() {
  local target="${1:-all}"
  if [ "$target" = "a" ] || [ "$target" = "tenant-a" ] || [ "$target" = "all" ]; then
    echo -e "\033[1;31mStopping Tenant A workloads...\033[0m"
    kubectl --kubeconfig tenant-a.yaml delete -f manifests/egress-gateway-experiment/workloads-tenant-a.yaml --ignore-not-found=true
  fi
  if [ "$target" = "b" ] || [ "$target" = "tenant-b" ] || [ "$target" = "all" ]; then
    echo -e "\033[1;31mStopping Tenant B workloads...\033[0m"
    kubectl --kubeconfig tenant-b.yaml delete -f manifests/egress-gateway-experiment/workloads-tenant-b.yaml --ignore-not-found=true
  fi
}

# Display the menu on startup
menu
