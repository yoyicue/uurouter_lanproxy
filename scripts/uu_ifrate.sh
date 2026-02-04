#!/bin/sh
# Measure average RX/TX throughput (Mbps) on one or more interfaces by sampling /proc/net/dev.
# Designed for OpenWrt/Linux (will not work on macOS).

set -eu

duration="10"
src_ip=""

usage() {
  cat >&2 <<'EOF'
Usage:
  uu_ifrate.sh [-d seconds] [--src-ip <IP>] <iface...>

Examples (OpenWrt):
  # Measure specific interfaces for 10s
  sh uu_ifrate.sh -d 10 tun164 veth-lpx-br

  # Auto-detect UU tun interface(s) used by a device IP (requires `ip`)
  sh uu_ifrate.sh --src-ip 192.168.1.252 -d 10
EOF
  exit 2
}

is_uint() {
  case "${1:-}" in
    ""|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

read_dev_bytes() {
  iface="$1"
  # /proc/net/dev columns: rx_bytes=$2, tx_bytes=$10 (after iface:)
  awk -v ifc="$iface" '$1 == (ifc ":") {print $2, $10}' /proc/net/dev
}

detect_tuns_for_ip() {
  ip_need="$1"
  command -v ip >/dev/null 2>&1 || {
    echo "error: --src-ip requires 'ip' (iproute2/ip-full)" >&2
    exit 1
  }

  # Find policy routing tables that are used when packets are marked (UU creates fwmark rules).
  tables="$(ip rule show 2>/dev/null | awk -v ip="$ip_need" '
    $0 ~ ("from " ip " ") && $0 ~ /fwmark/ {
      for (i = 1; i <= NF; i++) if ($i == "lookup") print $(i + 1)
    }' | sort -n | uniq)"

  [ -n "$tables" ] || return 1

  tuns=""
  for t in $tables; do
    # Typical: "default dev tun164"
    devs="$(ip route show table "$t" 2>/dev/null | awk '
      $0 ~ / dev tun/ {
        for (i = 1; i <= NF; i++) if ($i == "dev") print $(i + 1)
      }' | sort | uniq)"
    [ -n "$devs" ] || continue
    for d in $devs; do
      case " $tuns " in
        *" $d "*) ;;
        *) tuns="${tuns}${tuns:+ }$d" ;;
      esac
    done
  done

  [ -n "$tuns" ] || return 1
  echo "$tuns"
  return 0
}

# Parse args (support --src-ip long option).
while [ $# -gt 0 ]; do
  case "$1" in
    -d)
      [ $# -ge 2 ] || usage
      duration="$2"
      shift 2
      ;;
    --src-ip)
      [ $# -ge 2 ] || usage
      src_ip="$2"
      shift 2
      ;;
    -h|--help)
      usage
      ;;
    --)
      shift
      break
      ;;
    -*)
      echo "error: unknown option: $1" >&2
      usage
      ;;
    *)
      break
      ;;
  esac
done

is_uint "$duration" || { echo "error: -d must be an integer seconds" >&2; exit 2; }
[ "$duration" -gt 0 ] || { echo "error: -d must be > 0" >&2; exit 2; }

ifaces="$*"
if [ -z "$ifaces" ] && [ -n "$src_ip" ]; then
  ifaces="$(detect_tuns_for_ip "$src_ip" || true)"
  if [ -z "$ifaces" ]; then
    echo "error: failed to auto-detect tun interface(s) for $src_ip (is UU acceleration enabled for this IP?)" >&2
    exit 1
  fi
fi

[ -n "$ifaces" ] || usage

tmp="/tmp/uu_ifrate.$$"
start_file="${tmp}.start"
end_file="${tmp}.end"
trap 'rm -f "$start_file" "$end_file"' EXIT INT TERM

echo "duration=${duration}s"
if [ -n "$src_ip" ]; then
  echo "src_ip=$src_ip"
fi
echo "ifaces=$ifaces"
echo ""

for iface in $ifaces; do
  v="$(read_dev_bytes "$iface" || true)"
  if [ -z "$v" ]; then
    echo "error: interface not found in /proc/net/dev: $iface" >&2
    exit 1
  fi
  rx="$(echo "$v" | awk '{print $1}')"
  tx="$(echo "$v" | awk '{print $2}')"
  echo "$iface $rx $tx" >>"$start_file"
done

sleep "$duration"

for iface in $ifaces; do
  v="$(read_dev_bytes "$iface" || true)"
  if [ -z "$v" ]; then
    echo "error: interface disappeared from /proc/net/dev: $iface" >&2
    exit 1
  fi
  rx="$(echo "$v" | awk '{print $1}')"
  tx="$(echo "$v" | awk '{print $2}')"
  echo "$iface $rx $tx" >>"$end_file"
done

printf "%-14s %10s %10s %11s\n" "iface" "rx_Mbps" "tx_Mbps" "total_Mbps"

sum_rx=0
sum_tx=0

while read -r iface s_rx s_tx; do
  e_line="$(awk -v ifc="$iface" '$1 == ifc {print $0}' "$end_file")"
  [ -n "$e_line" ] || continue

  e_rx="$(echo "$e_line" | awk '{print $2}')"
  e_tx="$(echo "$e_line" | awk '{print $3}')"

  d_rx=$((e_rx - s_rx))
  d_tx=$((e_tx - s_tx))
  sum_rx=$((sum_rx + d_rx))
  sum_tx=$((sum_tx + d_tx))

  awk -v iface="$iface" -v drx="$d_rx" -v dtx="$d_tx" -v dur="$duration" '
    BEGIN {
      rx=drx*8/dur/1000000
      tx=dtx*8/dur/1000000
      tt=(drx+dtx)*8/dur/1000000
      printf "%-14s %10.2f %10.2f %11.2f\n", iface, rx, tx, tt
    }'
done <"$start_file"

awk -v drx="$sum_rx" -v dtx="$sum_tx" -v dur="$duration" '
  BEGIN {
    rx=drx*8/dur/1000000
    tx=dtx*8/dur/1000000
    tt=(drx+dtx)*8/dur/1000000
    printf "%-14s %10.2f %10.2f %11.2f\n", "TOTAL", rx, tx, tt
  }'

