#!/bin/bash
set -euo pipefail

# Trust the mkcert CA
update-ca-certificates

# Add the route to the nginx subnet via the router
ip route add 10.20.0.0/24 via 10.10.0.100

# Keep container running
exec tail -f /dev/null
