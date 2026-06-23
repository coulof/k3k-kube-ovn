#!/usr/bin/env bash
# File: manifests/vpc-peering-experiment/traffic-loop.sh
# Purpose: Continuous traffic connectivity test between client-pod and server-pod

clear
while true; do
  echo -e "\033[1;35m========================================================\033[0m"
  echo -e "\033[1;35m       LIVE TRAFFIC FLOW: TENANT-A -> TENANT-B         \033[0m"
  echo -e "\033[1;35m========================================================\033[0m"
  echo -e "Source:      \033[1;34mclient-pod\033[0m inside \033[1;34mtenant-a\033[0m (Subnet IP: \033[1;33m10.10.0.2\033[0m)"
  echo -e "Destination: \033[1;36mserver-pod\033[0m inside \033[1;36mtenant-b\033[0m (Subnet IP: \033[1;33m10.20.0.2:8080\033[0m)"
  echo -e "Timestamp:   $(date +'%Y-%m-%d %H:%M:%S')"
  echo -e "--------------------------------------------------------"
  echo -e "Sending HTTP request from client-pod to server-pod..."
  echo

  # Execute wget with a short timeout
  out=$(kubectl --kubeconfig tenant-a.yaml exec client-pod -- wget -T 2 -O- http://10.20.0.2:8080 2>&1)
  status=$?

  if [ $status -eq 0 ]; then
    echo -e "\033[1;32m[🟢 SUCCESS] VPC Peering Tunnel Active! Traffic flowing.\033[0m"
    echo -e "Server Response: \"\033[1;32m$out\033[0m\""
  else
    echo -e "\033[1;31m[🔴 BLOCKED] Traffic Dropped / Isolation Active!\033[0m"
    echo -e "Error details:"
    echo "$out" | sed 's/^/  /'
  fi

  echo -e "\033[1;35m========================================================\033[0m"
  echo "Next check in 2 seconds... (Press Ctrl+C to exit)"
  sleep 2
  clear
done
