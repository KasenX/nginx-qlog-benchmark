#!/bin/bash
set -euo pipefail

# Add the route to the client subnet via the router
ip route add 10.10.0.0/24 via 10.20.0.100

# Ensure the nginx workers can write qlog files
chown nginx:nginx /var/log/nginx/qlog

exec nginx -g 'daemon off;'
