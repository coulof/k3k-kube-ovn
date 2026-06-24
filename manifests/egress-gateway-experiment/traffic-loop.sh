#!/usr/bin/env bash
# File: manifests/egress-gateway-experiment/traffic-loop.sh
# Purpose: Continuous verification of Kube-OVN Egress IP aggregation across multiple pods over eth1

# Get the target egress-test-target VM IP
TARGET_IP="192.168.105.100"

clear
while true; do
  echo -e "\033[1;35m=====================================================================\033[0m"
  echo -e "     LIVE MULTI-POD EGRESS IP FLOWS -> macOS HOST LOGGER              \033[0m"
  echo -e "\033[1;35m=====================================================================\033[0m"
  echo -e "Target Mac Server: \033[1;33mhttp://${TARGET_IP}:8888\033[0m"
  echo -e "Timestamp:         $(date +'%Y-%m-%d %H:%M:%S')"
  echo -e "---------------------------------------------------------------------"

  # 1. Query Tenant A Workloads (Subnet CIDR 10.10.0.0/16)
  echo -e "\033[1;34m=== TENANT-A WORKLOADS (Expected Egress: 192.168.105.70) ===\033[0m"
  for pod in client-pod-1 client-pod-2; do
    echo -n "  -> Pod [${pod}]: "
    # Run wget inside the virtual pod via sh -c to resolve hostname & IP inside the pod
    out=$(kubectl --kubeconfig tenant-a.yaml exec ${pod} -- sh -c "wget -T 2 -qO- 'http://${TARGET_IP}:8888/?pod=\$(hostname)&ip=\$(hostname -i)'" 2>&1)
    status=$?
    if [ $status -eq 0 ]; then
      echo -e "\033[1;32m[🟢 SUCCESS]\033[0m Response: \"$out\""
    else
      echo -e "\033[1;31m[🔴 FAILED]\033[0m Error: $out"
    fi
  done

  echo

  # 2. Query Tenant B Workloads (Subnet CIDR 10.20.0.0/16)
  echo -e "\033[1;36m=== TENANT-B WORKLOADS (Expected Egress: 192.168.105.80) ===\033[0m"
  for pod in client-pod-1 client-pod-2; do
    echo -n "  -> Pod [${pod}]: "
    # Run wget inside the virtual pod via sh -c to resolve hostname & IP inside the pod
    out=$(kubectl --kubeconfig tenant-b.yaml exec ${pod} -- sh -c "wget -T 2 -qO- 'http://${TARGET_IP}:8888/?pod=\$(hostname)&ip=\$(hostname -i)'" 2>&1)
    status=$?
    if [ $status -eq 0 ]; then
      echo -e "\033[1;32m[🟢 SUCCESS]\033[0m Response: \"$out\""
    else
      echo -e "\033[1;31m[🔴 FAILED]\033[0m Error: $out"
    fi
  done

  echo -e "\033[1;35m=====================================================================\033[0m"
  echo "Next check in 4 seconds... (Press Ctrl+C to exit)"
  sleep 4
  clear
done
