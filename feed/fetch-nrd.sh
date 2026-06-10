#!/bin/bash
# fetch-nrd.sh — Fetches WhoisFreaks NRD data and rebuilds adblock feed.
# Called by both init and cron modes. Does NOT touch AdGuard config.

set -euo pipefail

API_KEY_FILE="${API_KEY_FILE:-/secrets/apikey}"
CACHE_DIR="${CACHE_DIR:-/app/cache}"
OUTPUT="${OUTPUT:-/app/output/nrd.adblock}"
WINDOW_DAYS="${WINDOW_DAYS:-10}"
FEED_TYPES="${FEED_TYPES:-gtld cctld}"
ADGUARD_URL="${ADGUARD_URL:-http://adguard:80}"
ADGUARD_USER="${ADGUARD_USER:-admin}"
ADGUARD_PASS="${ADGUARD_PASS:-}"

log() { echo "[$(date -u +%FT%TZ)] $*"; }

# ── Read API key ──────────────────────────────────────────────────────────────
[[ -f "$API_KEY_FILE" ]] || { log "ERROR: API key file not found at $API_KEY_FILE"; exit 1; }
API_KEY=$(cat "$API_KEY_FILE" | tr -d '[:space:]')
[[ -n "$API_KEY" ]] || { log "ERROR: API key is empty"; exit 1; }
log "API key loaded (${#API_KEY} chars)"

mkdir -p "$CACHE_DIR" "$(dirname "$OUTPUT")"

log "Starting NRD fetch | window=${WINDOW_DAYS}d | feeds=${FEED_TYPES}"

# ── Build list of dates ───────────────────────────────────────────────────────
WANTED_DATES=()
for ((i=1; i<=WINDOW_DAYS; i++)); do
  WANTED_DATES+=("$(date -u -d "@$(($(date -u +%s) - i * 86400))" +%Y-%m-%d)")
done

# ── Fetch missing days ────────────────────────────────────────────────────────
NEW_DOWNLOADS=0
FAILED_FETCHES=0

for date in "${WANTED_DATES[@]}"; do
  for feed in $FEED_TYPES; do
    cache_file="${CACHE_DIR}/${date}_${feed}.txt"

    if [[ -s "$cache_file" ]]; then
      log "  ${feed}/${date}: cache hit ($(wc -l < "$cache_file") domains)"
      continue
    fi

    log "  ${feed}/${date}: downloading..."
    URL="https://files.whoisfreaks.com/v3.1/download/domainer/${feed}?apiKey=${API_KEY}&date=${date}&whois=false"

    tmp_gz="$(mktemp)"
    tmp_txt="$(mktemp)"

    if curl -sS --fail --max-time 300 -o "$tmp_gz" "$URL"; then
      if zcat "$tmp_gz" \
           | tr -d '\r' \
           | tr '[:upper:]' '[:lower:]' \
           | grep -E '^[a-z0-9][a-z0-9.-]*\.[a-z]{2,}$' \
           | sort -u > "$tmp_txt" \
         && [[ -s "$tmp_txt" ]]; then
        mv "$tmp_txt" "$cache_file"
        NEW_DOWNLOADS=$((NEW_DOWNLOADS + 1))
        log "    cached $(wc -l < "$cache_file") domains -> $(basename "$cache_file")"
      else
        log "    WARN: ${feed}/${date} returned empty or invalid data"
        FAILED_FETCHES=$((FAILED_FETCHES + 1))
        rm -f "$tmp_txt"
      fi
    else
      log "    WARN: download failed for ${feed}/${date}"
      FAILED_FETCHES=$((FAILED_FETCHES + 1))
    fi
    rm -f "$tmp_gz"
  done
done

# ── Prune old cache ───────────────────────────────────────────────────────────
KEEP_PATTERN="$(IFS='|'; echo "${WANTED_DATES[*]}")"
PRUNED=0
shopt -s nullglob
for f in "${CACHE_DIR}"/*.txt; do
  file_date="$(basename "$f" | cut -c1-10)"
  if [[ "$file_date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
    if ! [[ "|${KEEP_PATTERN}|" == *"|${file_date}|"* ]]; then
      rm -f "$f"; PRUNED=$((PRUNED + 1))
    fi
  fi
done
shopt -u nullglob

TOTAL_EXPECTED=$(( WINDOW_DAYS * $(echo "$FEED_TYPES" | wc -w) ))
CACHED_COUNT=$(( TOTAL_EXPECTED - NEW_DOWNLOADS - FAILED_FETCHES ))
log "Cache: ${NEW_DOWNLOADS} new, ${CACHED_COUNT} cached, ${FAILED_FETCHES} failed, ${PRUNED} pruned"

# ── Rebuild adblock output ────────────────────────────────────────────────────
if ! compgen -G "${CACHE_DIR}/*.txt" > /dev/null; then
  log "ERROR: no cache files found"; exit 1
fi

TOTAL=$(cat "${CACHE_DIR}"/*.txt | sort -u | wc -l | tr -d ' ')
log "Writing ${TOTAL} unique domains..."

{
  echo "! Title: WhoisFreaks NRD Feed — ${WINDOW_DAYS}-day rolling window"
  echo "! Description: Newly Registered Domains blocklist"
  echo "! Homepage: https://whoisfreaks.com"
  echo "! Expires: 24 hours"
  echo "! Last modified: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "! Version: $(date -u +%Y%m%d%H%M%S)"
  echo "! Total domains: ${TOTAL}"
  echo "!"
  cat "${CACHE_DIR}"/*.txt | sort -u | awk '{print "||" $0 "^"}'
} > "${OUTPUT}.tmp"
mv "${OUTPUT}.tmp" "$OUTPUT"

log "Feed written: $OUTPUT (${TOTAL} rules)"

# ── Trigger AdGuard refresh (only in cron mode, AdGuard already running) ──────
[[ -z "$ADGUARD_PASS" ]] && { log "Done (no AdGuard refresh — ADGUARD_PASS not set)"; exit 0; }

AUTH=$(echo -n "${ADGUARD_USER}:${ADGUARD_PASS}" | base64 | tr -d '\n')
HTTP=$(curl -s -o /dev/null -w "%{http_code}" \
  -H "Authorization: Basic ${AUTH}" \
  "${ADGUARD_URL}/control/status" 2>/dev/null || echo "000")

if [[ "$HTTP" == "200" ]]; then
  RESULT=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
    -H "Authorization: Basic ${AUTH}" \
    -H "Content-Type: application/json" \
    -d '{"whitelist": false}' \
    "${ADGUARD_URL}/control/filtering/refresh")
  log "AdGuard filter refresh: HTTP ${RESULT}"
else
  log "AdGuard not reachable (HTTP ${HTTP}) — skipping refresh"
fi

log "Done. ${TOTAL} domains in NRD feed."
exit 0
