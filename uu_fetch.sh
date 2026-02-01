#!/usr/bin/env bash
set -euo pipefail

TYPE="openwrt"
MODEL=""
ARCH=""
SN=""
OUT_DIR="./uu_artifacts"
ONLY_MONITOR="0"
VERBOSE="0"

usage() {
  cat <<'USAGE'
Usage: uu_fetch.sh [options]

Downloads the UU monitor script and attempts to locate/download the uuplugin binary
for offline analysis on macOS.

Options:
  --type <router>     Router type (default: openwrt)
  --model <model>     Router model (optional)
  --arch <arch>       Target arch (optional, e.g. mips, mipsel, arm, armv7, arm64, aarch64, x86_64)
  --sn <sn>           Device serial/mac (optional, used by some endpoints)
  --out <dir>         Output directory (default: ./uu_artifacts)
  --only-monitor      Only download the monitor script
  --verbose           Verbose logs
  -h, --help          Show this help

Examples:
  ./uu_fetch.sh --type openwrt --arch mipsel --out ./uu
  ./uu_fetch.sh --type openwrt --model R3G --sn AA:BB:CC:DD:EE:FF
USAGE
}

log() {
  printf "%s\n" "$*" >&2
}

vlog() {
  if [ "${VERBOSE}" = "1" ]; then
    log "$@"
  fi
}

md5_file() {
  if command -v md5sum >/dev/null 2>&1; then
    md5sum "$1" | awk '{print $1}'
  else
    md5 -q "$1"
  fi
}

fetch_text() {
  local url="$1"
  curl -fsSL -H "Accept:text/plain" "$url" 2>/dev/null || \
    curl -fsSL -k -H "Accept:text/plain" "$url" 2>/dev/null
}

fetch_to_file() {
  local url="$1"
  local out="$2"
  curl -fSL -o "$out" "$url" 2>/dev/null || \
    curl -fSL -k -o "$out" "$url" 2>/dev/null
}

append_param() {
  local url="$1"
  local key="$2"
  local value="$3"

  if [ -z "$value" ]; then
    printf "%s" "$url"
    return 0
  fi

  case "$url" in
    *"${key}="*)
      printf "%s" "$url"
      ;;
    *\?*)
      printf "%s&%s=%s" "$url" "$key" "$value"
      ;;
    *)
      printf "%s?%s=%s" "$url" "$key" "$value"
      ;;
  esac
}

normalize_url() {
  local url="$1"
  if [[ "$url" != http*://* ]]; then
    printf "https://%s" "$url"
  else
    printf "%s" "$url"
  fi
}

parse_plugin_info() {
  # Output: URL then MD5 on two lines if detected
  local data="$1"
  local line

  line=$(printf "%s" "$data" | tr -d '\r' | head -n 1)

  # Format: url,md5
  if [[ "$line" =~ ^https?://.*,[0-9a-fA-F]{32}$ ]]; then
    printf "%s\n" "${line%%,*}"
    printf "%s\n" "${line##*,}"
    return 0
  fi

  # Try JSON on single line
  local json
  json=$(printf "%s" "$data" | tr -d '\r\n')
  if [[ "$json" == *"\"url\""* && "$json" == *"\"md5\""* ]]; then
    local url md5
    url=$(printf "%s" "$json" | sed -n 's/.*"url"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
    md5=$(printf "%s" "$json" | sed -n 's/.*"md5"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
    if [ -n "$url" ] && [ -n "$md5" ]; then
      printf "%s\n" "$url"
      printf "%s\n" "$md5"
      return 0
    fi
  fi

  return 1
}

extract_candidate_urls() {
  local file="$1"
  {
    grep -oE 'https?://[^"'"'"' )]+' "$file" || true
    grep -oE 'router\.uu\.163\.com[^"'"'"' )]+' "$file" || true
  } | sed 's/[;,]$//' | sort -u
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --type)
      TYPE="$2"; shift 2 ;;
    --model)
      MODEL="$2"; shift 2 ;;
    --arch)
      ARCH="$2"; shift 2 ;;
    --sn)
      SN="$2"; shift 2 ;;
    --out)
      OUT_DIR="$2"; shift 2 ;;
    --only-monitor)
      ONLY_MONITOR="1"; shift ;;
    --verbose)
      VERBOSE="1"; shift ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      log "Unknown argument: $1"; usage; exit 1 ;;
  esac
done

mkdir -p "$OUT_DIR"

# Step 1: download monitor script
MONITOR_API_HTTPS="https://router.uu.163.com/api/script/monitor?type=${TYPE}"
MONITOR_API_HTTP="http://router.uu.163.com/api/script/monitor?type=${TYPE}"

vlog "Fetching monitor info: $MONITOR_API_HTTPS"
monitor_info=$(fetch_text "$MONITOR_API_HTTPS" || true)
if [ -z "$monitor_info" ]; then
  vlog "HTTPS failed, trying HTTP: $MONITOR_API_HTTP"
  monitor_info=$(fetch_text "$MONITOR_API_HTTP" || true)
fi

if [ -z "$monitor_info" ]; then
  log "Failed to fetch monitor info from API."
  exit 2
fi

monitor_info=$(printf "%s" "$monitor_info" | tr -d '\r')
monitor_info_line=$(printf "%s" "$monitor_info" | head -n 1)

if ! monitor_parsed=$(parse_plugin_info "$monitor_info" 2>/dev/null); then
  log "Monitor API response not in expected format."
  log "Response: $monitor_info_line"
  exit 3
fi

monitor_url=$(printf "%s" "$monitor_parsed" | head -n 1)
monitor_md5=$(printf "%s" "$monitor_parsed" | tail -n 1)
monitor_url=$(normalize_url "$monitor_url")

monitor_path="$OUT_DIR/uuplugin_monitor.sh"
log "Downloading monitor script: $monitor_url"
fetch_to_file "$monitor_url" "$monitor_path"

if [ -n "$monitor_md5" ]; then
  calc_md5=$(md5_file "$monitor_path")
  if [ "${calc_md5}" != "${monitor_md5}" ]; then
    log "Monitor MD5 mismatch: expected $monitor_md5, got $calc_md5"
    exit 4
  fi
fi

chmod +x "$monitor_path"
log "Monitor saved to: $monitor_path"

if [ "${ONLY_MONITOR}" = "1" ]; then
  exit 0
fi

# Step 2: extract candidate URLs and probe for uuplugin
log "Scanning monitor script for candidate endpoints..."

candidate_urls=$(extract_candidate_urls "$monitor_path" || true)
if [ -z "$candidate_urls" ]; then
  log "No candidate URLs found in monitor script."
  exit 5
fi

found_plugin="0"
for raw_url in $candidate_urls; do
  url=$(normalize_url "$raw_url")

  case "$url" in
    *monitor*|*uninstall*)
      continue
      ;;
  esac

  # Add required params if missing
  url=$(append_param "$url" "type" "$TYPE")
  url=$(append_param "$url" "model" "$MODEL")
  url=$(append_param "$url" "sn" "$SN")
  url=$(append_param "$url" "arch" "$ARCH")
  url=$(append_param "$url" "output" "text")

  vlog "Probing: $url"
  resp=$(fetch_text "$url" || true)
  if [ -z "$resp" ]; then
    continue
  fi

  if ! parsed=$(parse_plugin_info "$resp" 2>/dev/null); then
    continue
  fi

  plugin_url=$(printf "%s" "$parsed" | head -n 1)
  plugin_md5=$(printf "%s" "$parsed" | tail -n 1)
  plugin_url=$(normalize_url "$plugin_url")

  out_name="uuplugin"
  if [ -n "$ARCH" ]; then
    out_name="uuplugin_${ARCH}"
  fi
  plugin_path="$OUT_DIR/$out_name"

  log "Downloading uuplugin: $plugin_url"
  fetch_to_file "$plugin_url" "$plugin_path"

  if [ -n "$plugin_md5" ]; then
    calc_md5=$(md5_file "$plugin_path")
    if [ "${calc_md5}" != "${plugin_md5}" ]; then
      log "uuplugin MD5 mismatch: expected $plugin_md5, got $calc_md5"
      exit 6
    fi
  fi

  log "uuplugin saved to: $plugin_path"
  found_plugin="1"
  break

done

if [ "$found_plugin" = "0" ]; then
  log "No uuplugin download endpoint succeeded."
  log "Try passing --arch/--model/--sn or inspect $monitor_path manually."
  exit 7
fi
