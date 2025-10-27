#!/bin/sh
# clear_udmp_firewallgroups.sh  (bewährte "saubere" Version, pre-GitHub)
# Löscht eure vier Blocklist-Gruppen (oder mit --all wirklich alle) über die UniFi REST API.
# Voraussetzungen: jq vorhanden; Passwort in /etc/unifi-api.secret; Basis-Config in /etc/udmp_api.env

set -eu

ENV_FILE="/etc/udmp_api.env"
SECRET_FILE="/etc/unifi-api.secret"

# Defaults (werden ggf. durch ENV überschrieben)
UNIFI_HOST_IP="${UNIFI_HOST_IP:-10.0.0.1}"
UNIFI_HOSTNAME="${UNIFI_HOSTNAME:-unifi.local}"
UNIFI_USER="${UNIFI_USER:-admin}"
UNIFI_SITE="${UNIFI_SITE:-default}"

GROUP_DROP_V4="${GROUP_DROP_V4:-SpamhausDROP}"
GROUP_DROP_V6="${GROUP_DROP_V6:-SpamhausDROPv6}"
GROUP_DSHIELD="${GROUP_DSHIELD:-DShieldBlock}"
GROUP_FIREHOL_L1="${GROUP_FIREHOL_L1:-FireHOL_L1}"

MODE="named"   # nur die 4 bekannten Gruppen
[ "${1-}" = "--all" ] && MODE="all"

# ----- ENV laden -----
[ -f "$ENV_FILE" ] && . "$ENV_FILE" || true

# ----- Hilfsfunktionen -----
mktemp_safely(){ mktemp 2>/dev/null || mktemp -t udmpclear; }

fail(){ echo "[ERROR] $*" >&2; exit 1; }

# ----- Zertifikat des Controllers ziehen -----
echo "[INFO] Lade Controller-Zertifikat ..."
CA="$(mktemp_safely)"
echo | openssl s_client -connect "${UNIFI_HOST_IP}:443" -servername "${UNIFI_HOSTNAME}" 2>/dev/null \
  | openssl x509 > "$CA" || fail "Konnte Zertifikat nicht auslesen."

# ----- Login -----
[ -s "$SECRET_FILE" ] || fail "Passwortdatei fehlt/leer: $SECRET_FILE"
PASS="$(cat "$SECRET_FILE")"

echo "[INFO] Login an https://${UNIFI_HOSTNAME} ..."
COOKIE="$(mktemp_safely)"; HDRS="$(mktemp_safely)"
curl -sS --fail \
  --resolve "${UNIFI_HOSTNAME}:443:${UNIFI_HOST_IP}" --cacert "$CA" \
  -c "$COOKIE" -D "$HDRS" -H 'Content-Type: application/json' \
  --data "{\"username\":\"${UNIFI_USER}\",\"password\":\"${PASS}\"}" \
  "https://${UNIFI_HOSTNAME}/api/auth/login" >/dev/null || fail "Login fehlgeschlagen."

CSRF="$(sed -n 's/^x-csrf-token: \(.*\)\r\?$/\1/ip' "$HDRS" | tail -n1 | tr -d '\r')"
[ -n "$CSRF" ] || fail "Kein CSRF-Token erhalten."

# ----- Gruppen holen -----
echo "[INFO] Lade Firewallgruppen ..."
JSON="$(mktemp_safely)"
curl -sS --fail \
  --resolve "${UNIFI_HOSTNAME}:443:${UNIFI_HOST_IP}" --cacert "$CA" \
  -b "$COOKIE" -H "X-CSRF-Token: ${CSRF}" \
  "https://${UNIFI_HOSTNAME}/proxy/network/api/s/${UNIFI_SITE}/rest/firewallgroup" > "$JSON" \
  || fail "Abruf /rest/firewallgroup fehlgeschlagen."

# ----- Auswahl vorbereiten -----
if [ "$MODE" = "all" ]; then
  # Alle Gruppen: id|name Liste
  LIST="$(mktemp_safely)"
  jq -r '.data[] | [.["_id"], .name] | @tsv' "$JSON" | sed 's/\t/|/' > "$LIST"
else
  # Nur die vier gewünschten Namen
  LIST="$(mktemp_safely)"
  jq -r --arg a "$GROUP_DROP_V4" \
        --arg b "$GROUP_DROP_V6" \
        --arg c "$GROUP_DSHIELD" \
        --arg d "$GROUP_FIREHOL_L1" \
        '.data[] | select(.name==$a or .name==$b or .name==$c or .name==$d)
         | [.["_id"], .name] | @tsv' "$JSON" | sed 's/\t/|/' > "$LIST"
fi

FOUND="$(wc -l < "$LIST" | tr -d ' ')"
echo "[INFO] Es wurden ${FOUND} Gruppen gefunden."

# ----- Löschen -----
DELETED=0
while IFS='|' read -r ID NAME; do
  [ -n "${ID:-}" ] || continue
  echo "[INFO] Lösche Gruppe: ${NAME} (${ID}) ..."
  CODE="$(curl -sS --write-out '%{http_code}' --output /dev/null \
    --resolve "${UNIFI_HOSTNAME}:443:${UNIFI_HOST_IP}" --cacert "$CA" \
    -b "$COOKIE" -H "X-CSRF-Token: ${CSRF}" \
    -H 'X-Requested-With: XMLHttpRequest' \
    -X DELETE "https://${UNIFI_HOSTNAME}/proxy/network/api/s/${UNIFI_SITE}/rest/firewallgroup/${ID}")"
  case "$CODE" in
    200|204) DELETED=$((DELETED+1)) ;;
    409)     echo "[WARN] Gruppe in Benutzung (HTTP 409): ${NAME}" ;;
    *)       echo "[WARN] DELETE fehlgeschlagen (HTTP ${CODE}) für ${NAME}" ;;
  esac
done < "$LIST"

echo "[INFO] Erfolgreich gelöscht: ${DELETED}"
echo "[INFO] Alle Firewall-Gruppen gelöscht."

# ----- Cleanup -----
rm -f "$JSON" "$LIST" "$COOKIE" "$HDRS" "$CA" 2>/dev/null || true
exit 0
