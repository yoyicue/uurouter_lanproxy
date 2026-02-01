#!/bin/sh
# lanproxy-netns: create a network namespace that behaves like a LAN client by
# attaching a veth peer to br-lan. This makes the proxy's outbound traffic go
# through PREROUTING with iifname "br-lan", so uuplugin rules can match.

set -eu

ACTION="${1:-start}"

BR_LAN_IF="${BR_LAN_IF:-br-lan}"
NS_NAME="${NS_NAME:-lanproxy}"
VETH_HOST="${VETH_HOST:-veth-lpx-br}"
VETH_NS="${VETH_NS:-veth-lpx}"
NS_PROTO="${NS_PROTO:-static}"
NS_ADDR="${NS_ADDR:-192.168.1.252/24}"
NS_GW="${NS_GW:-192.168.1.250}"
UU_LEASE_MAC="${UU_LEASE_MAC:-98:41:5C:AA:BB:CC}"
KEEP_NETNS="${KEEP_NETNS:-0}"

UDHCPC_SCRIPT="${UDHCPC_SCRIPT:-/etc/lanproxy/udhcpc.script}"
UDHCPC_PIDFILE="${UDHCPC_PIDFILE:-/tmp/lanproxy.udhcpc.pid}"
DHCP_REQUEST_IP="${DHCP_REQUEST_IP:-}"
DHCP_HOSTNAME="${DHCP_HOSTNAME:-NintendoSwitch}"
DHCP_VENDORCLASS="${DHCP_VENDORCLASS:-}"

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "[lanproxy-netns] missing command: $1" >&2
    exit 1
  }
}

start() {
  need ip

  if [ "$NS_PROTO" != "static" ] && [ "$NS_PROTO" != "dhcp" ]; then
    echo "[lanproxy-netns] invalid NS_PROTO: $NS_PROTO (expected static|dhcp)" >&2
    exit 1
  fi

  # Create netns if missing.
  if ! ip netns list 2>/dev/null | awk '{print $1}' | grep -qx "$NS_NAME"; then
    ip netns add "$NS_NAME"
  fi

  # Create veth pair in the root namespace if missing.
  if ! ip link show "$VETH_HOST" >/dev/null 2>&1; then
    ip link add "$VETH_HOST" type veth peer name "$VETH_NS"
  fi

  # Attach host end to the LAN bridge (idempotent).
  ip link set "$VETH_HOST" master "$BR_LAN_IF" 2>/dev/null || true
  ip link set "$VETH_HOST" up

  # Move netns end into the namespace if it's still in root.
  if ip link show "$VETH_NS" >/dev/null 2>&1; then
    ip link set "$VETH_NS" netns "$NS_NAME"
  fi

  # Configure the namespace end.
  ip netns exec "$NS_NAME" ip link set lo up
  # Set a stable MAC so uuplugin can map IP<->MAC if it reads lease files.
  ip netns exec "$NS_NAME" ip link set dev "$VETH_NS" address "$UU_LEASE_MAC" 2>/dev/null || true
  ip netns exec "$NS_NAME" ip link set "$VETH_NS" up

  if [ "$NS_PROTO" = "static" ]; then
    ip netns exec "$NS_NAME" ip addr flush dev "$VETH_NS" || true
    ip netns exec "$NS_NAME" ip addr add "$NS_ADDR" dev "$VETH_NS"
    ip netns exec "$NS_NAME" ip route replace default via "$NS_GW"
    return 0
  fi

  # NS_PROTO=dhcp: run udhcpc to emit DHCP fingerprint, but force default via NS_GW.
  need udhcpc

  # Kill any previous client.
  if [ -f "$UDHCPC_PIDFILE" ]; then
    pid="$(cat "$UDHCPC_PIDFILE" 2>/dev/null || true)"
    [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
    rm -f "$UDHCPC_PIDFILE" 2>/dev/null || true
  fi

  # If the script is missing, we still run udhcpc (for fingerprinting) but it won't configure.
  udhcpc_args="-i $VETH_NS -p $UDHCPC_PIDFILE"
  [ -x "$UDHCPC_SCRIPT" ] && udhcpc_args="$udhcpc_args -s $UDHCPC_SCRIPT"

  # Prefer -V if supported.
  udhcpc_help="$(udhcpc -h 2>&1 || true)"
  if [ -n "$DHCP_VENDORCLASS" ] && echo "$udhcpc_help" | grep -q -- " -V"; then
    udhcpc_args="$udhcpc_args -V $DHCP_VENDORCLASS"
  fi

  # Hostname: try to set it if supported.
  if [ -n "$DHCP_HOSTNAME" ]; then
    if echo "$udhcpc_help" | grep -q -- " -H"; then
      udhcpc_args="$udhcpc_args -H $DHCP_HOSTNAME"
    elif echo "$udhcpc_help" | grep -q -- " -x"; then
      udhcpc_args="$udhcpc_args -x hostname:$DHCP_HOSTNAME"
    fi
  fi

  # Request a specific IP if supported (useful with upstream DHCP reservation).
  if [ -n "$DHCP_REQUEST_IP" ] && echo "$udhcpc_help" | grep -q -- " -r"; then
    udhcpc_args="$udhcpc_args -r $DHCP_REQUEST_IP"
  fi

  # Export NS_GW so udhcpc.script can force the default route via OpenWrt.
  # shellcheck disable=SC2086
  ip netns exec "$NS_NAME" env NS_GW="$NS_GW" udhcpc $udhcpc_args >/tmp/lanproxy.udhcpc.log 2>&1 &

  # Wait for IPv4 assignment (best-effort).
  i=0
  while [ $i -lt 20 ]; do
    if ip netns exec "$NS_NAME" ip -4 -o addr show dev "$VETH_NS" 2>/dev/null | grep -q "inet "; then
      ip netns exec "$NS_NAME" ip route replace default via "$NS_GW" 2>/dev/null || true
      return 0
    fi
    i=$((i + 1))
    sleep 1
  done
}

stop() {
  need ip

  if [ -f "$UDHCPC_PIDFILE" ]; then
    pid="$(cat "$UDHCPC_PIDFILE" 2>/dev/null || true)"
    [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
    rm -f "$UDHCPC_PIDFILE" 2>/dev/null || true
  fi

  [ "$KEEP_NETNS" = "1" ] && return 0

  # Deleting the namespace will also remove the veth pair.
  ip netns del "$NS_NAME" 2>/dev/null || true
}

status() {
  need ip
  echo "=== lanproxy netns ==="
  ip netns list | grep -E "^${NS_NAME}(\\s|$)" || echo "(missing netns: $NS_NAME)"
  echo ""
  echo "=== host link ($VETH_HOST) ==="
  ip link show "$VETH_HOST" 2>/dev/null || echo "(missing link: $VETH_HOST)"
  echo ""
  echo "=== netns addr/route ==="
  ip netns exec "$NS_NAME" ip addr show dev "$VETH_NS" 2>/dev/null || echo "(missing netns or link)"
  ip netns exec "$NS_NAME" ip route show 2>/dev/null || true
}

case "$ACTION" in
  start) start ;;
  stop) stop ;;
  restart) stop; start ;;
  status) status ;;
  *) echo "Usage: $0 {start|stop|restart|status}" >&2; exit 1 ;;
esac
