#!/bin/bash
# Deploy lanproxy-netns to OpenWrt

set -e

ROUTER_IP="${1:-192.168.1.250}"
ROUTER_USER="root"
BUILD_DIR="build"
ARCH="${2:-amd64}"

BINARY="$BUILD_DIR/lanproxy_linux_$ARCH"

if [ ! -f "$BINARY" ]; then
    echo "Binary not found: $BINARY"
    echo "Run ./build.sh first"
    exit 1
fi

echo "Deploying lanproxy-netns to $ROUTER_IP (arch: $ARCH)"
echo "================================================"

# Create directories
echo "[1/5] Creating directories..."
ssh "$ROUTER_USER@$ROUTER_IP" "mkdir -p /etc/lanproxy"

# Copy binary
echo "[2/5] Copying binary..."
scp "$BINARY" "$ROUTER_USER@$ROUTER_IP:/usr/bin/lanproxy"
ssh "$ROUTER_USER@$ROUTER_IP" "chmod +x /usr/bin/lanproxy"

# Copy scripts
echo "[3/5] Copying scripts..."
scp netns.sh uu-lease.sh udhcpc.script "$ROUTER_USER@$ROUTER_IP:/etc/lanproxy/"
ssh "$ROUTER_USER@$ROUTER_IP" "chmod +x /etc/lanproxy/netns.sh /etc/lanproxy/uu-lease.sh /etc/lanproxy/udhcpc.script"

# Copy init script
echo "[4/5] Copying init script..."
scp lanproxy.init "$ROUTER_USER@$ROUTER_IP:/etc/init.d/lanproxy"
ssh "$ROUTER_USER@$ROUTER_IP" "chmod +x /etc/init.d/lanproxy"

# Copy config
echo "[5/5] Copying config..."
scp config "$ROUTER_USER@$ROUTER_IP:/etc/lanproxy/config"

echo ""
echo "Deployment complete!"
echo ""
echo "To start the service:"
echo "  ssh $ROUTER_USER@$ROUTER_IP '/etc/init.d/lanproxy start'"
echo ""
echo "To enable on boot:"
echo "  ssh $ROUTER_USER@$ROUTER_IP '/etc/init.d/lanproxy enable'"
echo ""
echo "To check status:"
echo "  ssh $ROUTER_USER@$ROUTER_IP 'ps | grep lanproxy; /etc/lanproxy/netns.sh status'"
