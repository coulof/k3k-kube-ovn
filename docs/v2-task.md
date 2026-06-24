# Egress VPC Gateway Experiment Execution Checklist

- `[x]` Step 1: Create and start the test target VM `egress-test-target`
- `[x]` Step 2: Create and start the primary VM `k3k-kube-ovn`
- `[x]` Step 3: Verify baseline network connectivity between both VMs on the `user-v2-egress` network
- `[x]` Step 4: Implement and refine `manifests/egress-gateway-experiment/vpcs-and-subnets.yaml` with Multus and ProviderNetwork
- `[x]` Step 5: Refine the traffic loop `traffic-loop.sh` to target the `egress-test-target` VM
- `[x]` Step 6: Refine `showcase-demo.sh` to stream the `egress-test-target` logs directly
- `[x]` Step 7: Deploy resources and verify the egress NAT translation natively
- `[x]` Step 8: Complete documentation and write walkthrough report
