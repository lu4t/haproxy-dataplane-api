#!/bin/sh
set -eu
CFG="/usr/local/etc/haproxy/haproxy.cfg"

/usr/local/sbin/haproxy -c -q -f "$CFG"

if [ -f /var/run/haproxy.pid ]; then
  exec /usr/local/sbin/haproxy -f "$CFG" -sf "$(cat /var/run/haproxy.pid)"
else
  exec /usr/local/sbin/haproxy -f "$CFG"
fi
