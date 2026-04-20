#!/bin/bash
# NymVPN Network Isolation Test
# Run this from the CLIENT VM to verify isolation is working correctly
#
# Usage: sudo /opt/test-isolation.sh [gateway_ip]
#   or:  sudo bash /path/to/test-isolation.sh 10.55.0.1

set -euo pipefail

GATEWAY_IP="${1:-10.55.0.1}"
PASS=0
FAIL=0

echo "=== NymVPN Network Isolation Test ==="
echo "Date: $(date)"
echo "Hostname: $(hostname)"
echo ""

# Test 1: Gateway reachable
echo "1. Gateway reachable ($GATEWAY_IP):"
if ping -c 1 -W 3 "$GATEWAY_IP" >/dev/null 2>&1; then
  echo "   PASS - Gateway responds"
  PASS=$((PASS+1))
else
  echo "   FAIL - Cannot reach gateway"
  FAIL=$((FAIL+1))
fi
echo ""

# Test 2: DNS resolution via gateway
echo "2. DNS resolution via gateway:"
result=$(dig +short +time=5 example.com @"$GATEWAY_IP" 2>/dev/null || true)
if [ -n "$result" ]; then
  echo "   PASS - Resolved: $result"
  PASS=$((PASS+1))
else
  echo "   FAIL - DNS resolution failed (tunnel may be down)"
  FAIL=$((FAIL+1))
fi
echo ""

# Test 3: External IP (should be NymVPN exit)
echo "3. External IP check (should be NymVPN exit):"
ext_ip=$(curl -s --max-time 10 ifconfig.me 2>/dev/null || true)
if [ -n "$ext_ip" ]; then
  echo "   PASS - External IP: $ext_ip"
  echo "   NOTE: Verify this is NOT your host's real IP"
  PASS=$((PASS+1))
else
  echo "   INFO - No external access (tunnel may be down)"
  FAIL=$((FAIL+1))
fi
echo ""

# Test 4: IPv6 disabled
echo "4. IPv6 status:"
ipv6_status=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || echo "unknown")
if [ "$ipv6_status" = "1" ]; then
  echo "   PASS - IPv6 disabled"
  PASS=$((PASS+1))
else
  echo "   FAIL - IPv6 is enabled (leak risk)"
  FAIL=$((FAIL+1))
fi
echo ""

# Test 5: resolv.conf locked
echo "5. DNS config locked:"
if lsattr /etc/resolv.conf 2>/dev/null | grep -q 'i'; then
  echo "   PASS - resolv.conf is immutable"
  PASS=$((PASS+1))
else
  echo "   FAIL - resolv.conf is NOT immutable"
  FAIL=$((FAIL+1))
fi
echo ""

# Test 6: resolv.conf points to gateway only
echo "6. DNS points to gateway only:"
dns_servers=$(grep "^nameserver" /etc/resolv.conf | awk '{print $2}')
if [ "$dns_servers" = "$GATEWAY_IP" ]; then
  echo "   PASS - DNS: $dns_servers"
  PASS=$((PASS+1))
else
  echo "   FAIL - DNS: $dns_servers (expected $GATEWAY_IP only)"
  FAIL=$((FAIL+1))
fi
echo ""

# Test 7: No unexpected routes
echo "7. Routing table check:"
unexpected=$(ip route | grep -v "^${GATEWAY_IP%.*}.0/" | grep -v "^default via $GATEWAY_IP" | grep -v "^169.254" || true)
if [ -z "$unexpected" ]; then
  echo "   PASS - Only internal network and default via gateway"
  PASS=$((PASS+1))
else
  echo "   WARN - Unexpected routes:"
  echo "   $unexpected"
  FAIL=$((FAIL+1))
fi
echo ""

# Test 8: DNS leak test
echo "8. DNS leak test (external resolver):"
leak_result=$(dig +short +time=3 myip.opendns.com @resolver1.opendns.com 2>/dev/null || true)
if [ -z "$leak_result" ]; then
  echo "   PASS - External DNS resolver unreachable (forced through gateway)"
  PASS=$((PASS+1))
elif [ "$leak_result" = "$ext_ip" ]; then
  echo "   PASS - Returns VPN IP ($leak_result), no leak"
  PASS=$((PASS+1))
else
  echo "   WARN - Returns: $leak_result (verify this is NymVPN exit, not host IP)"
  FAIL=$((FAIL+1))
fi
echo ""

# Summary
echo "==========================================="
echo "Results: $PASS passed, $FAIL failed"
echo "==========================================="

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
