#!/bin/bash
set -uo pipefail

log() { echo "[$(date -u '+%Y-%m-%d %H:%M:%S UTC')] $*"; }

RUN_MODE="${RUN_MODE:-cron}"
ADGUARD_URL="${ADGUARD_URL:-http://adguard:80}"
ADGUARD_USER="${ADGUARD_USER:-admin}"
ADGUARD_PASS="${ADGUARD_PASS:-}"
FEED_URL="${FEED_URL:-http://172.28.0.10/nrd.adblock}"
CONF_DIR="${CONF_DIR:-/app/adguard-conf}"
CRON_SCHEDULE="${CRON_SCHEDULE:-0 2 * * *}"

# ── Validate API key ──────────────────────────────────────────────────────────
API_KEY_FILE="${API_KEY_FILE:-/secrets/apikey}"
[[ -f "$API_KEY_FILE" ]] || { log "ERROR: API key file not found at $API_KEY_FILE"; exit 1; }
API_KEY=$(cat "$API_KEY_FILE" | tr -d '[:space:]')
[[ -n "$API_KEY" ]] || { log "ERROR: API key file is empty"; exit 1; }
log "API key loaded (${#API_KEY} chars)"

# ─────────────────────────────────────────────────────────────────────────────
# INIT MODE: fetch feed + write AdGuard config, then exit.
# AdGuard starts AFTER this completes (depends_on: service_completed_successfully)
# ─────────────────────────────────────────────────────────────────────────────
if [[ "$RUN_MODE" == "init" ]]; then
  log "=== INIT MODE: fetching feed and preparing AdGuard config ==="

  # Run the NRD fetch
  /app/fetch-nrd.sh || { log "ERROR: fetch failed"; exit 1; }

  # Write AdGuard config with filter entry baked in
  CONF_FILE="${CONF_DIR}/AdGuardHome.yaml"
  mkdir -p "$CONF_DIR"

  if [[ ! -f "$CONF_FILE" ]]; then
    log "No existing AdGuard config — will use setup wizard + patch approach"
    log "AdGuard will start on port 3000, complete setup, then we patch the filter in"
    # Leave config empty — AdGuard will run setup wizard
    # The feed-fetcher (cron mode) will patch the filter after setup completes
    mkdir -p "$CONF_DIR"
    log "=== INIT complete. AdGuard will start setup wizard on port 3000. ==="
    log "NOTE: Set ADGUARD_PASS in docker-compose.yml — feed-fetcher will complete setup automatically."
    exit 0

  else
    log "Existing AdGuard config found — patching NRD filter entry..."
    python3 - "$CONF_FILE" "$FEED_URL" "${WINDOW_DAYS:-10}" << 'PYEOF'
import sys, yaml

conf_file, feed_url, window = sys.argv[1], sys.argv[2], sys.argv[3]

with open(conf_file, 'r') as f:
    conf = yaml.safe_load(f) or {}

if 'filters' not in conf:
    conf['filters'] = []

# Remove stale NRD entries
conf['filters'] = [f for f in conf['filters']
                   if '172.28.0.10' not in f.get('url', '')
                   and 'whoisfreaks' not in f.get('name', '').lower()
                   and 'nrd-feed-server' not in f.get('url', '')]

max_id = max((f.get('id', 0) for f in conf['filters']), default=0)
conf['filters'].append({
    'enabled': True,
    'url': feed_url,
    'name': f'WhoisFreaks NRD ({window}-day)',
    'id': max_id + 1,
})

with open(conf_file, 'w') as f:
    yaml.dump(conf, f, default_flow_style=False, allow_unicode=True)

print(f"Patched: added NRD filter entry (id={max_id+1})")
PYEOF
    log "NRD filter entry patched into existing config."
  fi

  log "=== INIT complete. AdGuard will now start with NRD filter pre-loaded. ==="
  exit 0
fi

# ─────────────────────────────────────────────────────────────────────────────
# CRON MODE
# ─────────────────────────────────────────────────────────────────────────────
log "=== CRON MODE: daily refresh scheduler ==="

ADGUARD_SETUP_URL="${ADGUARD_SETUP_URL:-http://adguard:3000}"

# Wait for AdGuard to be up (either setup wizard or main UI)
log "Waiting for AdGuard Home..."
for i in $(seq 1 30); do
  if curl -sf --max-time 2 "${ADGUARD_SETUP_URL}/" > /dev/null 2>&1 || \
     curl -sf --max-time 2 "${ADGUARD_URL}/" > /dev/null 2>&1; then
    log "AdGuard is up."
    break
  fi
  [[ $i -eq 30 ]] && { log "ERROR: AdGuard didn't start in 60s"; exit 1; }
  sleep 2
done

# Auto-complete setup wizard if needed
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  "${ADGUARD_SETUP_URL}/control/install/get_addresses" 2>/dev/null || echo "000")

if [[ "$HTTP_CODE" == "200" ]]; then
  log "Setup wizard detected — auto-completing..."
  [[ -z "$ADGUARD_PASS" ]] && { log "ERROR: ADGUARD_PASS not set"; exit 1; }

  RESULT=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
    -H "Content-Type: application/json" \
    -d "{\"web\":{\"ip\":\"0.0.0.0\",\"port\":80},\"dns\":{\"ip\":\"0.0.0.0\",\"port\":53},\"username\":\"${ADGUARD_USER}\",\"password\":\"${ADGUARD_PASS}\"}" \
    "${ADGUARD_SETUP_URL}/control/install/configure" 2>/dev/null || echo "000")
  [[ "$RESULT" == "200" ]] || { log "ERROR: setup configure returned HTTP ${RESULT}"; exit 1; }
  log "Setup complete (user=${ADGUARD_USER})"

  # Wait for AdGuard on port 80
  for i in $(seq 1 30); do
    HTTP=$(curl -s -o /dev/null -w "%{http_code}" "${ADGUARD_URL}/" 2>/dev/null || echo "000")
    [[ "$HTTP" == "200" || "$HTTP" == "302" ]] && { log "AdGuard ready on :80"; break; }
    [[ $i -eq 30 ]] && { log "ERROR: AdGuard didn't come up on :80"; exit 1; }
    sleep 2
  done

  # Now patch the NRD filter into the freshly-generated config
  CONF_FILE="${CONF_DIR}/AdGuardHome.yaml"
  if [[ -f "$CONF_FILE" ]]; then
    log "Patching NRD filter into AdGuard config..."
    python3 - "$CONF_FILE" "$FEED_URL" "${WINDOW_DAYS:-10}" << 'PYEOF'
import sys, yaml

conf_file, feed_url, window = sys.argv[1], sys.argv[2], sys.argv[3]
with open(conf_file, 'r') as f:
    conf = yaml.safe_load(f) or {}

if 'filters' not in conf:
    conf['filters'] = []

# Remove any stale NRD entries
conf['filters'] = [f for f in conf['filters']
                   if '172.28.0.10' not in f.get('url', '')
                   and 'whoisfreaks' not in f.get('name', '').lower()
                   and 'nrd-feed-server' not in f.get('url', '')]

max_id = max((f.get('id', 0) for f in conf['filters']), default=0)
conf['filters'].append({
    'enabled': True,
    'url': feed_url,
    'name': f'WhoisFreaks NRD ({window}-day)',
    'id': max_id + 1,
})

with open(conf_file, 'w') as f:
    yaml.dump(conf, f, default_flow_style=False, allow_unicode=True)
print(f"NRD filter entry added (id={max_id+1})")
PYEOF

    AUTH=$(echo -n "${ADGUARD_USER}:${ADGUARD_PASS}" | base64 | tr -d '\n')

    # AdGuard is freshly set up and 172.28.0.10 is in /etc/hosts.
    # Use the filtering API to add the NRD feed directly.
    log "Adding NRD filter via AdGuard API..."
    RESULT=$(curl -s -w "\n%{http_code}" -X POST \
      -H "Authorization: Basic ${AUTH}" \
      -H "Content-Type: application/json" \
      -d "{\"name\":\"WhoisFreaks NRD (${WINDOW_DAYS:-10}-day)\",\"url\":\"${FEED_URL}\"}" \
      "${ADGUARD_URL}/control/filtering/add_url" 2>/dev/null)
    HTTP=$(echo "$RESULT" | tail -1)
    BODY=$(echo "$RESULT" | head -1)
    log "API add_url response: HTTP ${HTTP} — ${BODY}"

    if [[ "$HTTP" == "200" ]]; then
      log "NRD filter added successfully via API."
    else
      # Fallback: patch YAML directly + restart
      log "API add failed — patching config directly..."
      CONF_FILE="${CONF_DIR}/AdGuardHome.yaml"
      sleep 3  # let AdGuard finish settling
      python3 - "$CONF_FILE" "$FEED_URL" "${WINDOW_DAYS:-10}" << 'PYEOF'
import sys, yaml
conf_file, feed_url, window = sys.argv[1], sys.argv[2], sys.argv[3]
with open(conf_file, 'r') as f:
    conf = yaml.safe_load(f) or {}
if 'filters' not in conf:
    conf['filters'] = []
conf['filters'] = [f for f in conf['filters']
                   if '172.28.0.10' not in f.get('url','')
                   and 'whoisfreaks' not in f.get('name','').lower()]
max_id = max((f.get('id',0) for f in conf['filters']), default=0)
conf['filters'].append({'enabled':True,'url':feed_url,
    'name':f'WhoisFreaks NRD ({window}-day)','id':max_id+1})
with open(conf_file,'w') as f:
    yaml.dump(conf,f,default_flow_style=False,allow_unicode=True)
print(f"Patched config: NRD filter id={max_id+1}")
PYEOF
      log "Restarting AdGuard to apply patched config..."
      curl -s -X POST -H "Authorization: Basic ${AUTH}" \
        "${ADGUARD_URL}/control/restart" > /dev/null 2>&1 || true
      sleep 3
      # Patch again after restart (AdGuard rewrites config on boot)
      sleep 5
      python3 - "${CONF_DIR}/AdGuardHome.yaml" "$FEED_URL" "${WINDOW_DAYS:-10}" << 'PYEOF'
import sys, yaml
conf_file, feed_url, window = sys.argv[1], sys.argv[2], sys.argv[3]
with open(conf_file, 'r') as f:
    conf = yaml.safe_load(f) or {}
if 'filters' not in conf:
    conf['filters'] = []
already = any('172.28.0.10' in f.get('url','') for f in conf['filters'])
if not already:
    max_id = max((f.get('id',0) for f in conf['filters']), default=0)
    conf['filters'].append({'enabled':True,'url':feed_url,
        'name':f'WhoisFreaks NRD ({window}-day)','id':max_id+1})
    with open(conf_file,'w') as f:
        yaml.dump(conf,f,default_flow_style=False,allow_unicode=True)
    print(f"Post-restart patch applied (id={max_id+1})")
else:
    print("Filter already present after restart")
PYEOF
      curl -s -X POST -H "Authorization: Basic ${AUTH}" \
        "${ADGUARD_URL}/control/restart" > /dev/null 2>&1 || true
      for i in $(seq 1 20); do
        HTTP2=$(curl -s -o /dev/null -w "%{http_code}" "${ADGUARD_URL}/control/status" 2>/dev/null || echo "000")
        [[ "$HTTP2" == "200" ]] && { log "AdGuard up with NRD filter."; break; }
        sleep 2
      done
    fi
  fi
else
  log "AdGuard setup already complete."
fi

# Run fetch once now to pick up today's domains and trigger refresh
log "Running initial refresh..."
/app/fetch-nrd.sh || log "WARNING: initial fetch failed"

# Write cron job
log "Setting up cron: ${CRON_SCHEDULE}"
mkdir -p /etc/crontabs
printenv | grep -E '^(WINDOW_DAYS|FEED_TYPES|ADGUARD_URL|ADGUARD_USER|ADGUARD_PASS|API_KEY_FILE|FEED_URL|CONF_DIR)=' > /etc/cron-env
echo "${CRON_SCHEDULE} . /etc/cron-env && /app/fetch-nrd.sh >> /proc/1/fd/1 2>&1" > /etc/crontabs/root
log "Cron job written. Starting crond..."

exec /usr/sbin/crond -f -d 8 -c /etc/crontabs
