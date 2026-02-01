#!/bin/bash
# Build lanproxy for multiple architectures

set -e

VERSION="1.0.0"
BUILD_DIR="build"
SRC="main.go"

mkdir -p "$BUILD_DIR"

echo "Building lanproxy v$VERSION"
echo "================================"

# Linux x86_64 (for testing on VM)
echo "[1/4] Building for linux/amd64..."
GOOS=linux GOARCH=amd64 go build -ldflags="-s -w" -o "$BUILD_DIR/lanproxy_linux_amd64" "$SRC"

# Linux ARM (Raspberry Pi, some routers)
echo "[2/4] Building for linux/arm..."
GOOS=linux GOARCH=arm GOARM=7 go build -ldflags="-s -w" -o "$BUILD_DIR/lanproxy_linux_arm" "$SRC"

# Linux ARM64 (newer routers)
echo "[3/4] Building for linux/arm64..."
GOOS=linux GOARCH=arm64 go build -ldflags="-s -w" -o "$BUILD_DIR/lanproxy_linux_arm64" "$SRC"

# Linux MIPS (OpenWrt on older routers)
echo "[4/4] Building for linux/mipsle..."
GOOS=linux GOARCH=mipsle GOMIPS=softfloat go build -ldflags="-s -w" -o "$BUILD_DIR/lanproxy_linux_mipsle" "$SRC"

echo ""
echo "Build complete!"
echo ""
ls -lh "$BUILD_DIR/"

echo ""
echo "To deploy to OpenWrt:"
echo "  scp $BUILD_DIR/lanproxy_linux_amd64 root@192.168.1.250:/usr/bin/lanproxy"
echo "  scp netns.sh uu-lease.sh udhcpc.script root@192.168.1.250:/etc/lanproxy/"
echo "  scp lanproxy.init root@192.168.1.250:/etc/init.d/lanproxy"
echo "  scp config root@192.168.1.250:/etc/lanproxy/config"
