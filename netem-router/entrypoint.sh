#!/bin/bash
set -euo pipefail

# Create and set up IFB interfaces
ip link add ifb0 type ifb
ip link add ifb1 type ifb
ip link set ifb0 up
ip link set ifb1 up

# Redirect ingress traffic to IFB interfaces
tc qdisc add dev eth0 handle ffff: ingress
tc filter add dev eth0 parent ffff: protocol ip u32 match u32 0 0 action mirred egress redirect dev ifb0

tc qdisc add dev eth1 handle ffff: ingress
tc filter add dev eth1 parent ffff: protocol ip u32 match u32 0 0 action mirred egress redirect dev ifb1

echo "netem-router ready: eth0<->ifb0 and eth1<->ifb1"

# Keep container running
exec tail -f /dev/null
