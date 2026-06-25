#!/usr/bin/env bash
# File: manifests/egress-gateway-experiment/showcase-demo.sh
# Purpose: Beautiful, automated TMUX Dashboard for Native Kube-OVN Egress IP demonstration (v2 - Multi-VPC & Shared Bridge)
# Note: This script runs natively on macOS to orchestrate and display traffic flows to the egress-demo-control VM.

SESSION="kube-ovn-egress-demo"

# Check if tmux is installed on macOS
if ! command -v tmux &> /dev/null; then
  echo -e "\033[1;31mError: tmux is not installed on macOS.\033[0m"
  echo -e "Please install it first: \033[1;32mbrew install tmux\033[0m, then run this script!"
  exit 1
fi

# Make sure k3k-kube-ovn is running
VM_STATUS=$(limactl list k3k-kube-ovn --format '{{.Status}}' 2>/dev/null)
if [ "$VM_STATUS" != "Running" ]; then
  echo -e "\033[1;31mError: Guest VM 'k3k-kube-ovn' is not running.\033[0m"
  echo -e "Please start it: \033[1;32mlimactl start k3k-kube-ovn\033[0m first, then run this script!"
  exit 1
fi

# Kill existing session if it exists
tmux kill-session -t "$SESSION" 2>/dev/null

# Create a new session, start in detached mode
tmux new-session -d -s "$SESSION" -n "Egress-Dashboard"
tmux set-option -t "$SESSION" default-terminal "tmux-256color"

# Split window to create a 2x2 grid layout:
# 1. Split horizontally (creates a right pane, index 1)
tmux split-window -h -t "$SESSION:0" -p 50

# 2. Split left pane vertically (creates bottom-left pane, index 1; top-left is 0)
tmux split-window -v -t "$SESSION:0.0" -p 50

# 3. Split right pane vertically (creates bottom-right pane, index 3; top-right is 2)
tmux split-window -v -t "$SESSION:0.2" -p 50

# Pane 0 (Top-Left - Traffic Loop): Runs traffic-loop.sh inside the guest VM
tmux send-keys -t "$SESSION:0.0" "limactl shell k3k-kube-ovn env TERM=tmux-256color bash manifests/egress-gateway-experiment/traffic-loop.sh" C-m

# Pane 1 (Bottom-Left - Live Watch of Config): Live watch of Kube-OVN Egress Gateways, Subnets and Gateway Pods
tmux send-keys -t "$SESSION:0.1" "limactl shell k3k-kube-ovn env TERM=tmux-256color watch -n 1 -c \"echo -e '\\\033[1;34m=== K3K VIRTUAL CLUSTERS ===\\\033[0m' && kubectl get clusters.k3k.io -A && echo && echo -e '\\\033[1;34m=== KUBE-OVN VPC EGRESS GATEWAYS ===\\\033[0m' && kubectl get veg -o custom-columns=NAME:.metadata.name,VPC:.spec.vpc,EXT-SUBNET:.spec.externalSubnet,EXT-IPS:.spec.externalIPs,PHASE:.status.phase,READY:.status.ready && echo && echo -e '\\\033[1;34m=== EGRESS INFRASTRUCTURE SUBNETS ===\\\033[0m' && kubectl get subnet subnet-tenant-a subnet-tenant-b subnet-no-egress external-egress-subnet -o custom-columns=NAME:.metadata.name,CIDR:.spec.cidrBlock,VPC:.spec.vpc,VLAN:.spec.vlan && echo && echo -e '\\\033[1;34m=== ACTIVE GATEWAY PODS ===\\\033[0m' && kubectl get pods -n default -o custom-columns=NAME:.metadata.name,STATUS:.status.phase,IP:.status.podIP,NODE:.spec.nodeName\"" C-m


# Pane 2 (Top-Right - VM Logger): Streams the Python egress-logger logs from egress-test-target VM
tmux send-keys -t "$SESSION:0.2" "limactl shell egress-test-target env TERM=tmux-256color sudo journalctl -u egress-logger -f -n 20" C-m

# Pane 3 (Bottom-Right - Interactive Control): Guest VM bash shell loaded with our helper menu
tmux send-keys -t "$SESSION:0.3" "limactl shell k3k-kube-ovn env TERM=tmux-256color bash --rcfile manifests/egress-gateway-experiment/controller-helpers.sh" C-m

# Select Pane 3 as active starting point
tmux select-pane -t "$SESSION:0.3"

# Attach to the completed tmux session dashboard
tmux attach-session -t "$SESSION"
