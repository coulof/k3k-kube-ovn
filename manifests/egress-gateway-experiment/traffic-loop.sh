#!/usr/bin/env bash
# File: manifests/egress-gateway-experiment/traffic-loop.sh
# Purpose: Continuous verification of Kube-OVN Egress IP aggregation across multiple pods, contrasting Bypass (No Gateway), Gateway SNAT, and Isolated No-Egress configurations

# Enforce tmux-256color terminal type for high-fidelity interactive display
export TERM=tmux-256color

# Target IPs on egress-test-target VM
TARGET_UNDERLAY_IP="192.168.105.100"
TARGET_MGT_IP="192.168.104.4"

clear
while true; do
  echo -e "\033[1;35m=====================================================================\033[0m"
  echo -e "     LIVE MULTI-POD EGRESS IP FLOWS -> egress-demo-control VM        \033[0m"
  echo -e "\033[1;35m=====================================================================\033[0m"
  echo -e "Underlay Server:   \033[1;33mhttp://${TARGET_UNDERLAY_IP}:8888\033[0m (Egress Gateway Target)"
  echo -e "Management Server: \033[1;33mhttp://${TARGET_MGT_IP}:8888\033[0m (Standard Node Egress Target)"
  echo -e "Timestamp:         $(date +'%Y-%m-%d %H:%M:%S')"
  echo -e "---------------------------------------------------------------------"

  # 1. Query Host Test Pods (Standard Main Cluster Egress & Isolated No-Egress)
  # Scheduled on the main host's subnets
  echo -e "\033[1;33m=== 1. MAIN HOST ACTIVE PODS ===\033[0m"

  # Auto-apply host test pods if not running
  if ! kubectl get pod test-pod &>/dev/null; then
    kubectl apply -f manifests/test-pod.yaml &>/dev/null
  fi
  if ! kubectl get pod no-egress-pod &>/dev/null; then
    kubectl apply -f manifests/egress-gateway-experiment/no-egress-pod.yaml &>/dev/null
  fi

  # Ensure both test pods are Ready/Running before executing commands
  kubectl wait --for=condition=Ready pod/test-pod pod/no-egress-pod --timeout=15s &>/dev/null

  pods_host=$(kubectl get pods --field-selector=status.phase=Running -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
  found_host_pod=false
  for pod in $pods_host; do
    if [[ "$pod" == "test-pod"* ]]; then
      found_host_pod=true
      echo -n "  -> Pod [${pod}] (Main Host | Expected Egress: 192.168.104.3 - Node IP): "
      out=$(kubectl exec ${pod} -- sh -c "wget -T 2 -qO- \"http://${TARGET_MGT_IP}:8888/?pod=\$(hostname)&ip=\$(ip route get ${TARGET_MGT_IP} | awk '{print \$7}')\"" 2>&1)
      status=$?
      if [ $status -eq 0 ]; then
        echo -e "\033[1;32m[🟢 SUCCESS]\033[0m Response: \"$out\""
      else
        echo -e "\033[1;31m[🔴 FAILED]\033[0m Error: $out"
      fi
    elif [[ "$pod" == "no-egress-pod"* ]]; then
      found_host_pod=true
      echo -n "  -> Pod [${pod}] (ISOLATED | Subnet: subnet-no-egress | Expected: 🔴 TIMEOUT): "
      out=$(kubectl exec ${pod} -- sh -c "wget -T 2 -qO- \"http://${TARGET_UNDERLAY_IP}:8888/?pod=\$(hostname)&ip=\$(ip route get ${TARGET_UNDERLAY_IP} | awk '{print \$7}')\"" 2>&1)
      status=$?
      if [ $status -eq 0 ]; then
        echo -e "\033[1;31m[🔴 UNEXPECTED SUCCESS]\033[0m Response: \"$out\""
      else
        echo -e "\033[1;32m[🟢 EXPECTED TIMEOUT]\033[0m Error: download timed out"
      fi
    fi
  done
  if [ "$found_host_pod" = false ]; then
    echo -e "  \033[1;30mNo running host test-pods found.\033[0m"
  fi

  echo

  # 2. Query Tenant A Workloads (Dynamic check of running pods in tenant-a namespace)
  echo -e "\033[1;34m=== 2. TENANT-A ACTIVE WORKLOADS ===\033[0m"
  pods_a=$(kubectl --kubeconfig tenant-a.yaml get pods -n tenant-a --field-selector=status.phase=Running -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
  if [ -z "$pods_a" ]; then
    echo -e "  \033[1;30mNo running pods found in Tenant A namespace.\033[0m"
  else
    for pod in $pods_a; do
      # Get logical switch annotation
      subnet=$(kubectl --kubeconfig tenant-a.yaml get pod "$pod" -n tenant-a -o jsonpath='{.metadata.annotations.ovn\.kubernetes\.io/logical_switch}' 2>/dev/null)
      
      if [ "$subnet" = "subnet-tenant-a" ]; then
        echo -n "  -> Pod [${pod}] (Subnet: ${subnet} | Expected Egress: 192.168.105.70): "
        out=$(kubectl --kubeconfig tenant-a.yaml exec ${pod} -n tenant-a -- sh -c "wget -T 2 -qO- \"http://${TARGET_UNDERLAY_IP}:8888/?pod=\$(hostname)&ip=\$(ip route get ${TARGET_UNDERLAY_IP} | awk '{print \$7}')\"" 2>&1)
        status=$?
        if [ $status -eq 0 ]; then
          echo -e "\033[1;32m[🟢 SUCCESS]\033[0m Response: \"$out\""
        else
          echo -e "\033[1;31m[🔴 FAILED]\033[0m Error: $out"
        fi
      elif [ "$subnet" = "subnet-tenant-b" ]; then
        echo -n "  -> Pod [${pod}] (VPC BREAKTHROUGH | Subnet: ${subnet} | Expected Egress: 192.168.105.80): "
        out=$(kubectl --kubeconfig tenant-a.yaml exec ${pod} -n tenant-a -- sh -c "wget -T 2 -qO- \"http://${TARGET_UNDERLAY_IP}:8888/?pod=\$(hostname)&ip=\$(ip route get ${TARGET_UNDERLAY_IP} | awk '{print \$7}')\"" 2>&1)
        status=$?
        if [ $status -eq 0 ]; then
          echo -e "\033[1;32m[🟢 SUCCESS]\033[0m Response: \"$out\""
        else
          echo -e "\033[1;31m[🔴 FAILED]\033[0m Error: $out"
        fi
      else
        # No subnet annotation / default routing
        echo -n "  -> Pod [${pod}] (Default / Bypass | Expected Egress: 192.168.104.3 - Node IP): "
        out=$(kubectl --kubeconfig tenant-a.yaml exec ${pod} -n tenant-a -- sh -c "wget -T 2 -qO- \"http://${TARGET_MGT_IP}:8888/?pod=\$(hostname)&ip=\$(ip route get ${TARGET_MGT_IP} | awk '{print \$7}')\"" 2>&1)
        status=$?
        if [ $status -eq 0 ]; then
          echo -e "\033[1;32m[🟢 SUCCESS]\033[0m Response: \"$out\""
        else
          echo -e "\033[1;31m[🔴 FAILED]\033[0m Error: $out"
        fi
      fi
    done
  fi

  echo

  # 3. Query Tenant B Workloads (Dynamic check of running pods in tenant-b namespace)
  echo -e "\033[1;36m=== 3. TENANT-B ACTIVE WORKLOADS ===\033[0m"
  pods_b=$(kubectl --kubeconfig tenant-b.yaml get pods -n tenant-b --field-selector=status.phase=Running -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
  if [ -z "$pods_b" ]; then
    echo -e "  \033[1;30mNo running pods found in Tenant B namespace.\033[0m"
  else
    for pod in $pods_b; do
      # Get logical switch annotation
      subnet=$(kubectl --kubeconfig tenant-b.yaml get pod "$pod" -n tenant-b -o jsonpath='{.metadata.annotations.ovn\.kubernetes\.io/logical_switch}' 2>/dev/null)
      
      if [ "$subnet" = "subnet-tenant-b" ]; then
        echo -n "  -> Pod [${pod}] (Subnet: ${subnet} | Expected Egress: 192.168.105.80): "
        out=$(kubectl --kubeconfig tenant-b.yaml exec ${pod} -n tenant-b -- sh -c "wget -T 2 -qO- \"http://${TARGET_UNDERLAY_IP}:8888/?pod=\$(hostname)&ip=\$(ip route get ${TARGET_UNDERLAY_IP} | awk '{print \$7}')\"" 2>&1)
        status=$?
        if [ $status -eq 0 ]; then
          echo -e "\033[1;32m[🟢 SUCCESS]\033[0m Response: \"$out\""
        else
          echo -e "\033[1;31m[🔴 FAILED]\033[0m Error: $out"
        fi
      elif [ "$subnet" = "subnet-tenant-a" ]; then
        echo -n "  -> Pod [${pod}] (VPC BREAKTHROUGH | Subnet: ${subnet} | Expected Egress: 192.168.105.70): "
        out=$(kubectl --kubeconfig tenant-b.yaml exec ${pod} -n tenant-b -- sh -c "wget -T 2 -qO- \"http://${TARGET_UNDERLAY_IP}:8888/?pod=\$(hostname)&ip=\$(ip route get ${TARGET_UNDERLAY_IP} | awk '{print \$7}')\"" 2>&1)
        status=$?
        if [ $status -eq 0 ]; then
          echo -e "\033[1;32m[🟢 SUCCESS]\033[0m Response: \"$out\""
        else
          echo -e "\033[1;31m[🔴 FAILED]\033[0m Error: $out"
        fi
      else
        # No subnet annotation / default routing
        echo -n "  -> Pod [${pod}] (Default / Bypass | Expected Egress: 192.168.104.3 - Node IP): "
        out=$(kubectl --kubeconfig tenant-b.yaml exec ${pod} -n tenant-b -- sh -c "wget -T 2 -qO- \"http://${TARGET_MGT_IP}:8888/?pod=\$(hostname)&ip=\$(ip route get ${TARGET_MGT_IP} | awk '{print \$7}')\"" 2>&1)
        status=$?
        if [ $status -eq 0 ]; then
          echo -e "\033[1;32m[🟢 SUCCESS]\033[0m Response: \"$out\""
        else
          echo -e "\033[1;31m[🔴 FAILED]\033[0m Error: $out"
        fi
      fi
    done
  fi

  echo -e "\033[1;35m=====================================================================\033[0m"
  echo "Next check in 5 seconds... (Press Ctrl+C to exit)"
  sleep 5
  clear
done
