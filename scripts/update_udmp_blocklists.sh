#!/bin/sh
# POSIX / BusyBox kompatibel
set -eu

##############################################################################
# Konfiguration laden
##############################################################################
ENV_FILE="/etc/udmp_api.env"
[ -f "$ENV_FILE" ] && . "$ENV_FILE"

UNIFI_HOST_IP="${UNIFI_HOST_IP:-10.0.0.1}"
UNIFI_HOSTNAME="${UNIFI_HOSTNAME:-unifi.local}"
UNIFI_USER="${UNIFI_USER:-admin}"
UNIFI_SITE="${UNIFI_SITE:-default}"

# Gruppen-Namen
GROUP_DROP_V4="${GROUP_DROP_V4:-SpamhausDROP}"
GROUP_DROP_V6="${GROUP_DROP_V6:-SpamhausDROPv6}"
GROUP_DSHIELD="${GROUP_DSHIELD:-DShieldBlock}"
GROUP_FIREHOL_L1="${GROUP_FIREHOL_L1:-FireHOL_L1}"

# Feature-Flags
ENABLE_DROP_V4="${ENABLE_DROP_V4:-true}"
ENABLE_DROP_V6="${ENABLE_DROP_V6:-true}"
ENABLE_DSHIELD="${ENABLE_DSHIELD:-true}"
ENABLE_FIREHOL_L1="${ENABLE_FIREHOL_L1:-true}"

# Limits
MAX_GROUP_MEM_V4="${MAX_GROUP_MEM_V4:-1500}"
MAX_GROUP_MEM_V6="${MAX_GROUP_MEM_V6:-1500}"

# Logging
DEBUG="${DEBUG:-false}"
LOG_FILE="${LOG_FILE:-}"   # z.B. /var/log/update_udmp_spamhaus.log
SYSLOG_TAG="${SYSLOG_TAG:-udmp-blocklists}"

# Audit-Log Entbündelung (Sekunden Pause zwischen Updates)
SLEEP_BETWEEN_UPDATES="${SLEEP_BETWEEN_UPDATES:-0}"

##############################################################################
# Logging-Hilfen
##############################################################################
ts() { date '+%Y-%m-%d %H:%M:%S'; }

_syslog() {
  level="$1"; shift
  case "$level" in
    INFO|WARN) logger -t "$SYSLOG_TAG" "[$level] $*";;
  esac
}

log() {
  level="$1"; shift
  line="[$(ts)] [$level] $*"
  echo "$line" >&2
  [ -n "${LOG_FILE}" ] && { echo "$line" >>"$LOG_FILE" 2>/dev/null || true; }
}

info(){ log INFO "$@"; _syslog INFO "$@"; }
warn(){ log WARN "$@"; _syslog WARN "$@"; }
dbg(){ [ "$DEBUG" = "true" ] && log DEBUG "$@"; }

need() { command -v "$1" >/dev/null 2>&1 || { warn "Benötigtes Kommando fehlt: $1"; exit 1; }; }

##############################################################################
# Passwort
##############################################################################
SECRET_FILE="/etc/unifi-api.secret"
if [ -f "$SECRET_FILE" ]; then
  UNIFI_PASS="$(cat "$SECRET_FILE")"
else
  warn "Kein Passwort in $SECRET_FILE – Abbruch."
  exit 1
fi

# Werkzeuge prüfen
need curl
need awk
need grep
need sed
need jq

##############################################################################
# Tempfiles
##############################################################################
TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT
COOKIE="$TMPD/cookie.txt"
HDRS="$TMPD/headers.txt"
CA="$TMPD/unifi_local.pem"
TMP1="$TMPD/tmp1.txt"
TMP2="$TMPD/tmp2.txt"
PAYLOAD="$TMPD/payload.json"

##############################################################################
# Zertifikat
##############################################################################
info "Zertifikat: CN = ${UNIFI_HOSTNAME}"
if command -v openssl >/dev/null 2>&1; then
  if echo | openssl s_client -connect "${UNIFI_HOST_IP}:443" -servername "${UNIFI_HOSTNAME}" 2>/dev/null | openssl x509 > "$CA"; then
    :
  else
    warn "Konnte Zertifikat nicht ziehen – fahre ohne --cacert fort."
    CA=""
  fi
else
  warn "openssl nicht gefunden – fahre ohne --cacert fort."
  CA=""
fi

##############################################################################
# CURL-Basen
##############################################################################
CURL_CTRL="curl -sS --connect-timeout 10 --max-time 60 --retry 2 --retry-delay 1 --resolve ${UNIFI_HOSTNAME}:443:${UNIFI_HOST_IP}"
[ -n "$CA" ] && CURL_CTRL="$CURL_CTRL --cacert $CA"

API_BASE="https://${UNIFI_HOSTNAME}"
API_NET="${API_BASE}/proxy/network/api"

CURL_NET="curl -sS --connect-timeout 10 --max-time 60 --retry 2 --retry-delay 1 -A 'UDMPro-Blocklist-Updater/1.0'"

##############################################################################
# Login / CSRF
##############################################################################
info "Login an ${API_BASE} ..."
$CURL_CTRL -c "$COOKIE" -D "$HDRS" \
  -H 'Content-Type: application/json' \
  --data "{\"username\":\"${UNIFI_USER}\",\"password\":\"${UNIFI_PASS}\"}" \
  "${API_BASE}/api/auth/login" >/dev/null

CSRF="$(awk 'BEGIN{IGNORECASE=1}/^x-csrf-token:/{print $2}' "$HDRS" | tr -d '\r')"
[ -z "$CSRF" ] && { warn "Kein CSRF-Token."; exit 1; }
dbg "CSRF: $CSRF"

##############################################################################
# Site-ID
##############################################################################
SITE_JSON="$($CURL_CTRL -b "$COOKIE" -H "X-CSRF-Token: $CSRF" "${API_NET}/self/sites")"
SITE_ID="$(printf '%s' "$SITE_JSON" | jq -r --arg n "$UNIFI_SITE" '.data[] | select(.name==$n)._id' | head -n1)"
[ -z "$SITE_ID" ] && { warn "Site-ID nicht gefunden."; exit 1; }
dbg "Site-ID: $SITE_ID"

info "Starte Update (Site=${UNIFI_SITE}, Host=${UNIFI_HOSTNAME}, max v4=${MAX_GROUP_MEM_V4}, max v6=${MAX_GROUP_MEM_V6})"

##############################################################################
# Download / Filter
##############################################################################
download_list() {
  url="$1"; is6="$2"; max="$3"; out="$4"
  if ! $CURL_NET "$url" > "$TMP1"; then
    warn "Download fehlgeschlagen: $url"; : > "$out"; return
  fi
  if [ "$is6" = "true" ]; then
    awk '!/^[[:space:]]*($|;|#)/ {print $1}' "$TMP1" |
      grep -iE '^[0-9a-f:]+(/[0-9]{1,3})?$' |
      sort -u | head -n "$max" > "$out" || true
  else
    awk '!/^[[:space:]]*($|;|#)/ {print $1}' "$TMP1" |
      grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]+)?$' |
      grep -Ev '^0\.|^10\.|^100\.64\.|^127\.|^169\.254\.|^172\.(1[6-9]|2[0-9]|3[0-1])\.|^192\.0\.0\.|^192\.0\.2\.|^192\.168\.|^198\.18\.|^198\.51\.100\.|^203\.0\.113\.|^(22[4-9]|23[0-9])\.|^24[0-9]\.|^25[0-5]\.' |
      sort -u | head -n "$max" > "$out" || true
  fi
}

##############################################################################
# Gruppen-Funktionen (robust via jq)
##############################################################################
get_group_obj_by_name() {
  # stdout: komplettes Objekt oder leer
  name="$1"
  $CURL_CTRL -b "$COOKIE" -H "X-CSRF-Token: $CSRF" \
    "${API_NET}/s/${UNIFI_SITE}/rest/firewallgroup" \
    | jq -c --arg n "$name" '.data[] | select(.name==$n)'
}

find_group_id() {
  name="$1"
  get_group_obj_by_name "$name" | jq -r '._id' | head -n1
}

ensure_group() {
  gtype="$1"; name="$2"

  # Gibt es die Gruppe?
  obj="$(get_group_obj_by_name "$name" || true)"
  if [ -n "$obj" ]; then
    # Prüfen, ob der Typ passt
    cur_type="$(printf '%s' "$obj" | jq -r '.group_type')"
    gid="$(printf '%s' "$obj" | jq -r '._id')"
    if [ "$cur_type" = "$gtype" ]; then
      printf '%s\n' "$gid"
      return 0
    fi
    # Typ passt nicht → neu anlegen (oder alternativ Typ ändern – API erlaubt i. d. R. nicht)
    warn "Gruppe '$name' existiert mit Typ '$cur_type' ≠ '$gtype' – lege neu an."
  fi

  # Anlegen
  payload='{"name":"'"$name"'","group_type":"'"$gtype"'","site_id":"'"$SITE_ID"'"}'
  RESP="$($CURL_CTRL -b "$COOKIE" -H "X-CSRF-Token: $CSRF" \
         -H 'X-Requested-With: XMLHttpRequest' -H 'Content-Type: application/json' \
         -d "$payload" "${API_NET}/s/${UNIFI_SITE}/rest/firewallgroup")"
  gid="$(printf '%s' "$RESP" | jq -r '.data[0]._id // ""')"
  [ -z "$gid" ] && { warn "Gruppe '$name' konnte nicht angelegt werden."; return 1; }
  dbg "Created group '$name' with ID=$gid"
  printf '%s\n' "$gid"
}

update_group_members() {
  id="$1"; name="$2"; gtype="$3"; file="$4"

  # JSON-Payload bauen
  {
    echo -n '{"_id":"'"$id"'","site_id":"'"$SITE_ID"'","name":"'"$name"'","group_type":"'"$gtype"'","group_members":['
    first=1
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      [ "$first" -eq 1 ] && first=0 || printf ','
      printf '"%s"' "$line"
    done < "$file"
    echo ']}'
  } > "$PAYLOAD"

  sz="$(wc -c < "$PAYLOAD" 2>/dev/null || echo 0)"
  dbg "Sende '${name}' (ID=${id}, type=${gtype}) Payload=${sz} Bytes"

  # PUT mit zusätzlichem Header + Audit-Log-Entbündelung
  set +e
  $CURL_CTRL -b "$COOKIE" -H "X-CSRF-Token: $CSRF" \
    -H 'Content-Type: application/json' \
    -H 'X-Requested-With: XMLHttpRequest' \
    -X PUT --data-binary @"$PAYLOAD" \
    -w '%{http_code}' -o "$TMPD/put_${id}.out" \
    "${API_NET}/s/${UNIFI_SITE}/rest/firewallgroup/${id}" > "$TMPD/put_${id}.code"
  rc=$?
  set -e

  code="$(cat "$TMPD/put_${id}.code" 2>/dev/null || echo "")"
  [ -z "$code" ] && code="000"
  dbg "HTTP PUT '${name}' → rc=${rc}, http=${code}"

  if [ "$rc" -ne 0 ]; then
    warn "Update für '${name}' abgebrochen (curl rc=${rc}). Weiter mit nächster Liste."
    return
  fi

  if [ "$code" -lt 200 ] || [ "$code" -ge 300 ]; then
    head -c 400 "$TMPD/put_${id}.out" 2>/dev/null | sed 's/[^[:print:]\t]/?/g' | while IFS= read -r l; do dbg "RESP: $l"; done
    warn "Update für '${name}' fehlgeschlagen (HTTP ${code}). Weiter mit nächster Liste."
    return
  fi

  ok="$(grep -c '"meta":{"rc":"ok"}' "$TMPD/put_${id}.out" 2>/dev/null || true)"
  if [ "$ok" -eq 0 ]; then
    head -c 400 "$TMPD/put_${id}.out" 2>/dev/null | sed 's/[^[:print:]\t]/?/g' | while IFS= read -r l; do dbg "RESP: $l"; done
    warn "Update für '${name}' vermutlich nicht übernommen (kein rc=ok)."
  fi

  # kleine Pause für getrennte Audit-Log-Einträge
  if [ "${SLEEP_BETWEEN_UPDATES}" -gt 0 ]; then
    sleep "${SLEEP_BETWEEN_UPDATES}"
  fi
}

##############################################################################
# Verarbeitung
##############################################################################
process_ipv4() {
  title="$1"; url="$2"; group="$3"
  info "Lade Liste ${url} …"
  download_list "$url" "false" "$MAX_GROUP_MEM_V4" "$TMP2"
  cnt="$(wc -l <"$TMP2" | tr -d ' ')"
  dbg "IPv4-Liste hat ${cnt} Einträge (≤ ${MAX_GROUP_MEM_V4})."
  [ "$cnt" -eq 0 ] && { warn "${title} (IPv4) ergab 0 Einträge – überspringe Update."; return; }
  gid="$(ensure_group "address-group" "$group")"
  info "Aktualisiere Gruppe '${group}' mit ${cnt} Einträgen …"
  update_group_members "$gid" "$group" "address-group" "$TMP2"
}

process_ipv6() {
  title="$1"; url="$2"; group="$3"
  info "Lade Liste ${url} …"
  download_list "$url" "true" "$MAX_GROUP_MEM_V6" "$TMP2"
  cnt="$(wc -l <"$TMP2" | tr -d ' ')"
  dbg "IPv6-Liste hat ${cnt} Einträge (≤ ${MAX_GROUP_MEM_V6})."
  [ "$cnt" -eq 0 ] && { warn "${title} (IPv6) ergab 0 Einträge – überspringe Update."; return; }
  gid="$(ensure_group "ipv6-address-group" "$group")"
  info "Aktualisiere Gruppe '${group}' mit ${cnt} Einträgen …"
  update_group_members "$gid" "$group" "ipv6-address-group" "$TMP2"
}

##############################################################################
# RUN
##############################################################################
if [ "$ENABLE_DROP_V4" = "true" ]; then
  process_ipv4 "Spamhaus DROP" "https://www.spamhaus.org/drop/drop.txt" "$GROUP_DROP_V4"
else
  dbg "DROP v4 deaktiviert."
fi

if [ "$ENABLE_DROP_V6" = "true" ]; then
  process_ipv6 "Spamhaus DROPv6" "https://www.spamhaus.org/drop/dropv6.txt" "$GROUP_DROP_V6"
else
  dbg "DROP v6 deaktiviert."
fi

if [ "$ENABLE_DSHIELD" = "true" ]; then
  process_ipv4 "DShield" "https://www.dshield.org/block.txt" "$GROUP_DSHIELD"
else
  dbg "DShield deaktiviert."
fi

if [ "$ENABLE_FIREHOL_L1" = "true" ]; then
  process_ipv4 "FireHOL L1" "https://iplists.firehol.org/files/firehol_level1.netset" "$GROUP_FIREHOL_L1"
else
  dbg "FireHOL L1 deaktiviert."
fi

info "Alle konfigurierten Listen verarbeitet."
exit 0