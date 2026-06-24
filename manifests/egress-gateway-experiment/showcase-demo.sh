#!/usr/bin/env bash
# File: manifests/egress-gateway-experiment/showcase-demo.sh
# Purpose: Beautiful, automated TMUX Dashboard for Native Kube-OVN Egress IP demonstration (v2 - Multi-VPC & Shared Bridge)
# Note: This script runs natively on macOS. It starts the logger natively on macOS, and bridges VM workloads dynamically.

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

# Split window: left (Pane 0) and right
tmux split-window -h -t "$SESSION:0" -p 50

# Split right window: top-right (Pane 1) and bottom-right (Pane 2)
tmux split-window -v -t "$SESSION:0.1" -p 50

# Pane 0 (Left - Traffic Loop): Runs traffic-loop.sh inside the guest VM
tmux send-keys -t "$SESSION:0.0" "limactl shell k3k-kube-ovn bash manifests/egress-gateway-experiment/traffic-loop.sh" C-m

# Pane 1 (Top-Right - VM Logger): Streams the Python egress-logger logs from egress-test-target VM
tmux send-keys -t "$SESSION:0.1" "limactl shell egress-test-target sudo journalctl -u egress-logger -f -n 20" C-m

# Pane 2 (Bottom-Right - Interactive Control): Standard macOS bash shell with guidance
tmux send-keys -t "$SESSION:0.2" "bash --rcfile <(echo 'source ~/.bashrc; export PS1=\"\033[1;36megress-demo-control\033[0m$ \"; echo; echo -e \"\033[1;32m=== NATIVE KUBE-OVN MULTI-VPC EGRESS CONTROL PANEL ===\033[0m\"; echo -e \"Useful helper command shortcuts available:\"; echo -e \"  - \033[1;33mlimactl shell k3k-kube-ovn kubectl get vpc\033[0m\"; echo -e \"  - \033[1;33mlimactl shell k3k-kube-ovn kubectl get subnet\033[0m\"; echo -e \"  - \033[1;33mlimactl shell k3k-kube-ovn kubectl get vpc-egress-gateways\033[0m\"; echo')" C-m

# Select Pane 2 as active starting point
tmux select-pane -t "$SESSION:0.2"

# Attach to the completed tmux session dashboard
tmux attach-session -t "$SESSION"
