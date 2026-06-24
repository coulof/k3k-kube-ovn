#!/usr/bin/env bash
# File: manifests/vpc-peering-experiment/showcase-demo.sh
# Purpose: Beautiful, automated tmux Dashboard for Kube-OVN Peering & NetworkPolicies

SESSION="kube-ovn-demo"

# Make sure we are inside the guest VM
if [ ! -f "/etc/rancher/rke2/rke2.yaml" ] && [ -z "$KUBECONFIG" ]; then
  echo -e "\033[1;31mError: This script must be run inside the 'k3k-kube-ovn' guest VM.\033[0m"
  echo -e "Please run: \033[1;32mlimactl shell k3k-kube-ovn\033[0m first, then execute this script!"
  exit 1
fi

# Check if tmux is installed
if ! command -v tmux &> /dev/null; then
  echo -e "\033[1;33mTmux is not installed inside the VM. Installing it now...\033[0m"
  sudo zypper -n install tmux
fi

# Kill existing session if it exists
tmux kill-session -t "$SESSION" 2>/dev/null

# Create a new session, start in detached mode
tmux new-session -d -s "$SESSION" -n "Dashboard"

# Create a 2x2 grid layout
# 1. Split horizontally (creates a right pane, index 1)
tmux split-window -h -t "$SESSION:0"

# 2. Split left pane vertically (creates bottom-left pane, index 1; top-left is 0)
tmux split-window -v -t "$SESSION:0.0"

# 3. Split right pane vertically (creates bottom-right pane, index 3; top-right is 2)
tmux split-window -v -t "$SESSION:0.2"

# Pane commands setup:
# Pane 0 (Top-Left): Continuous colorized traffic testing loop
tmux send-keys -t "$SESSION:0.0" "bash manifests/vpc-peering-experiment/traffic-loop.sh" C-m

# Pane 1 (Bottom-Left): Live watch of VPC and Subnet details
tmux send-keys -t "$SESSION:0.1" "watch -n 1 -c \"echo -e '\\\033[1;34m=== KUBE-OVN VPC PEERING STATUS ===\\\033[0m' && kubectl get vpc vpc-tenant-a vpc-tenant-b -o custom-columns=NAME:.metadata.name,PEERINGS:.status.vpcPeerings && echo && echo -e '\\\033[1;34m=== WORKLOAD SUBNETS ===\\\033[0m' && kubectl get subnet subnet-tenant-a subnet-tenant-b -o custom-columns=NAME:.metadata.name,CIDR:.spec.cidrBlock,VPC:.spec.vpc\"" C-m

# Pane 2 (Top-Right): Live watch of Subnet ACL rules & active OVN ACL list
tmux send-keys -t "$SESSION:0.2" "watch -n 1 -c \"echo -e '\\\033[1;36m=== SUBNET ACL RULES FOR subnet-tenant-b ===\\\033[0m' && kubectl get subnet subnet-tenant-b -o custom-columns=NAME:.metadata.name,ACLS:.spec.acls && echo && echo -e '\\\033[1;36m=== ACTIVE OVN NB ACL LIST ===\\\033[0m' && kubectl exec -n kube-system deploy/ovn-central -- ovn-nbctl acl-list subnet-tenant-b\"" C-m

# Pane 3 (Bottom-Right): Sourced interactive control menu
tmux send-keys -t "$SESSION:0.3" "bash --rcfile <(echo 'source ~/.bashrc; [ -f manifests/vpc-peering-experiment/controller-helpers.sh ] && source manifests/vpc-peering-experiment/controller-helpers.sh')" C-m

# Select and highlight Pane 3 as the active starting point
tmux select-pane -t "$SESSION:0.3"

# Attach to the completed tmux session dashboard
tmux attach-session -t "$SESSION"
