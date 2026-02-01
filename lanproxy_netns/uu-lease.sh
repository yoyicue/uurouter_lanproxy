#!/bin/sh
# uu-lease: help uuplugin discover the netns "LAN device" by writing a fake
# dnsmasq lease entry. Useful when OpenWrt is NOT the DHCP server (bypass mode).

set -eu

ACTION="${1:-update}"

WRITE_UU_LEASE="${WRITE_UU_LEASE:-1}"
NS_ADDR="${NS_ADDR:-192.168.1.252/24}"
NS_NAME="${NS_NAME:-lanproxy}"
VETH_NS="${VETH_NS:-veth-lpx}"
UU_LEASE_MAC="${UU_LEASE_MAC:-98:41:5C:AA:BB:CC}"
UU_LEASE_HOSTNAME="${UU_LEASE_HOSTNAME:-Nintendo-Switch}"
UU_LEASE_FILE1="${UU_LEASE_FILE1:-/tmp/dhcp.leases}"
UU_LEASE_FILE2="${UU_LEASE_FILE2:-/tmp/var/lib/misc/dnsmasq.leases}"

ns_ip() {
  # Prefer reading the actual address from netns (DHCP mode), fallback to NS_ADDR.
  if command -v ip >/dev/null 2>&1; then
    ip netns exec "$NS_NAME" ip -4 -o addr show dev "$VETH_NS" 2>/dev/null | \
      awk '{print $4}' | awk -F/ 'NR==1{print $1}' | grep -E '^[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+$' && return 0
  fi
  echo "$NS_ADDR" | awk -F/ '{print $1}'
}

mktemp_safe() {
  if command -v mktemp >/dev/null 2>&1; then
    mktemp
    return
  fi
  echo "/tmp/uu-lease.$$.$RANDOM"
}

update_file() {
  f="$1"
  ip="$(ns_ip)"
  line="0 $UU_LEASE_MAC $ip $UU_LEASE_HOSTNAME *"

  mkdir -p "$(dirname "$f")" 2>/dev/null || true
  tmp="$(mktemp_safe)"

  if [ -f "$f" ]; then
    # Drop any old entry matching our MAC or IP, then append the fresh one.
    awk -v mac="$UU_LEASE_MAC" -v ip="$ip" 'NF==0 {next} $2!=mac && $3!=ip {print}' "$f" > "$tmp" 2>/dev/null || true
  else
    : > "$tmp"
  fi
  echo "$line" >> "$tmp"
  mv "$tmp" "$f"
}

update() {
  [ "$WRITE_UU_LEASE" = "1" ] || return 0
  update_file "$UU_LEASE_FILE1"
  update_file "$UU_LEASE_FILE2"
}

case "$ACTION" in
  update) update ;;
  *) echo "Usage: $0 update" >&2; exit 1 ;;
esac
