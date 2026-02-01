#!/bin/bash
# Test lanproxy functionality (explicit HTTP proxy)

PROXY_HOST="${1:-192.168.1.252}"
PROXY_PORT="${2:-8888}"

echo "Testing lanproxy at $PROXY_HOST:$PROXY_PORT"
echo "=============================================="
echo ""

# Test 1: Basic connectivity
echo "[Test 1] Basic proxy connectivity..."
if curl -s -o /dev/null -w "%{http_code}" -x "http://$PROXY_HOST:$PROXY_PORT" http://example.com --connect-timeout 5 | grep -q "200"; then
    echo "  PASS: HTTP proxy working"
else
    echo "  FAIL: HTTP proxy not responding"
fi

# Test 2: HTTPS CONNECT
echo ""
echo "[Test 2] HTTPS CONNECT tunnel..."
if curl -s -o /dev/null -w "%{http_code}" -x "http://$PROXY_HOST:$PROXY_PORT" https://example.com --connect-timeout 5 | grep -q "200"; then
    echo "  PASS: HTTPS CONNECT working"
else
    echo "  FAIL: HTTPS CONNECT not working"
fi

# Test 3: Nintendo domains
echo ""
echo "[Test 3] Nintendo domain connectivity..."
NINTENDO_DOMAINS="
conntest.nintendowifi.net
ctest.cdn.nintendo.net
api.accounts.nintendo.com
"

for domain in $NINTENDO_DOMAINS; do
    if curl -s -o /dev/null -w "%{http_code}" -x "http://$PROXY_HOST:$PROXY_PORT" "https://$domain" --connect-timeout 5 2>/dev/null | grep -qE "200|301|302|403"; then
        echo "  PASS: $domain reachable"
    else
        echo "  WARN: $domain not reachable (may be normal)"
    fi
done

# Test 4: Check UU acceleration path (requires tcpdump/nft counters on router)
echo ""
echo "[Test 4] To verify UU acceleration, run on OpenWrt:"
echo "  nft list ruleset | grep -E 'XU_ACC_MAIN|60000' -n"
echo "  tcpdump -i lo -n 'port 60000' -c 10"
echo "  Then generate traffic via the proxy (Switch or curl)."

echo ""
echo "Tests complete."
