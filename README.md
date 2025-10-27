🛡️ UDM Pro – Automatische Firewall-Blocklisten (Spamhaus, DShield, FireHOL Level 1)
==================================================================================

Dieses Projekt stellt zwei Shell-Skripte für die UniFi Dream Machine Pro (UDM Pro) bereit, die automatisch IP-Blocklisten abrufen, in Firewall-Gruppen einpflegen und optional wieder löschen können. Sie sind vollständig BusyBox-/POSIX-kompatibel, nutzen die UniFi Controller REST-API und wurden für Stabilität, Sicherheit und Transparenz entwickelt.

## 📦 Enthaltene Skripte

| Datei | Beschreibung |
| --- | --- |
| `/usr/local/bin/update_udmp_blocklists.sh` | Hauptskript: Lädt IP-Blocklisten, aktualisiert Firewallgruppen |
| `/usr/local/bin/clear_udmp_firewallgroups.sh` | Hilfsskript: Löscht zuvor angelegte Gruppen sicher |
| `/etc/udmp_api.env` | Konfigurationsdatei mit Host-, Benutzer- und Gruppenparametern |
| `/etc/unifi-api.secret` | Datei mit UniFi-Adminpasswort (nur der reine Text) |

## ⚙️ Voraussetzungen

- UniFi Dream Machine Pro (UDM Pro) oder UDM SE
- Firmware ≥ 3.0.x mit funktionierender REST-API
- `curl`, `openssl`, `awk`, `grep`, `sort`, `head` (Standard auf der UDM vorhanden)
- Optional für `clear_udmp_firewallgroups.sh`: `jq`

## 🧩 1. Konfiguration anlegen

### 📄 `/etc/unifi-api.secret`

Diese Datei enthält nur das Passwort deines UniFi-Benutzers (z. B. `admin` oder `pseidl`):

```bash
echo "meinPasswort123" > /etc/unifi-api.secret
chmod 600 /etc/unifi-api.secret
```

## 🧩 2. Umgebungsdatei `/etc/udmp_api.env`

Diese Datei steuert alle Parameter und Limits.

```bash
UNIFI_HOST_IP=10.0.0.1
UNIFI_HOSTNAME=unifi.local
UNIFI_USER=pseidl
UNIFI_SITE=default
DEBUG=true
LOG_FILE=/var/log/update_udmp_spamhaus.log
GROUP_DROP_V4=SpamhausDROP
GROUP_DROP_V6=SpamhausDROPv6
GROUP_DSHIELD=DShieldBlock
GROUP_FIREHOL_L1=FireHOL_L1
ENABLE_DROP_V4=true
ENABLE_DROP_V6=true
ENABLE_DSHIELD=true
ENABLE_FIREHOL_L1=true
# Begrenzung pro Liste (empfohlen: ≤1500 Einträge)
MAX_GROUP_MEM_V4=1500
MAX_GROUP_MEM_V6=1500
```

> Hinweis: Die Variablen `MAX_GROUP_MEM_V4` und `MAX_GROUP_MEM_V6` verhindern, dass zu große Listen die WebUI beschädigen.

## 🚀 3. Skripte installieren

```bash
install -m 755 update_udmp_blocklists.sh /usr/local/bin/
install -m 755 clear_udmp_firewallgroups.sh /usr/local/bin/
```

Die Skripte sollten mit Root-Rechten ausgeführt werden:

```bash
/usr/local/bin/update_udmp_blocklists.sh
```

Wenn alles korrekt läuft, siehst du Logmeldungen wie:

```text
[INFO] Starte Update (Site=default, Host=unifi.local, max v4=1500, max v6=1500)
[INFO] Lade Liste https://www.spamhaus.org/drop/drop.txt …
[INFO] Aktualisiere Gruppe 'SpamhausDROP' mit 1469 Einträgen …
[INFO] Alle konfigurierten Listen verarbeitet.
```

## ⏱️ 4. Automatische Aktualisierung (Cronjob)

Lege einen Cronjob an, um die Listen regelmäßig zu aktualisieren (z. B. täglich um 2 Uhr nachts):

```bash
echo "0 2 * * * root /usr/local/bin/update_udmp_blocklists.sh >/dev/null 2>&1" >> /etc/crontab
```

## 🧹 5. Rücksetzen / Bereinigung

Wenn das WebUI oder die API nicht mehr reagiert oder Gruppen beschädigt wurden:

```bash
/usr/local/bin/clear_udmp_firewallgroups.sh
```

Oder um alle Firewallgruppen zu löschen:

```bash
/usr/local/bin/clear_udmp_firewallgroups.sh --all
```

Dieses Skript entfernt alle erstellten Gruppen sicher über die REST-API.

## 🧠 6. Funktionsweise

1. Das Update-Skript authentifiziert sich über die REST-API (`/api/auth/login`).
2. Es lädt die Blocklisten:
   - Spamhaus DROP (IPv4)
   - Spamhaus DROPv6 (IPv6)
   - DShield Blocklist
   - FireHOL Level 1 (Basis-Schutz)
3. Es legt fehlende Firewallgruppen automatisch an.
4. Es ersetzt die Gruppenmitglieder durch die neuen IP-/Netz-Einträge.
5. Alle Aktionen werden ins Log und Syslog geschrieben.

## 🧩 7. Empfohlene Firewall-Policies

Erstelle im UniFi Controller pro Blocklist folgende Richtungen:

| Quelle → Ziel | Beschreibung |
| --- | --- |
| External → Internal | Blockiert externe IPs aus den Blocklisten |
| External → Gateway | Schützt den Controller selbst |
| VPN → Internal | Blockiert infizierte VPN-Clients im LAN |
| VPN → External | Optional: Kontrolle des ausgehenden VPN-Verkehrs |
| VPN → Gateway | Verhindert direkte Zugriffe auf das Gateway |

> Diese Richtungen decken 95 % der relevanten Schutzszenarien ab. Zusätzliche VLAN- oder IoT-Isolation kann separat definiert werden.

## ⚙️ 8. Regelreihenfolge im Controller

Die UDM arbeitet mit stateful inspection. Das heißt: einmal aufgebaute Verbindungen dürfen zurückkehren. Daher ist die Regel “Allow Return Traffic” kein Sicherheitsrisiko – sie erlaubt lediglich Antwortpakete, die zu bestehenden Verbindungen gehören.

### 🧭 Empfohlene Reihenfolge

| Priorität | Regel |
| :---: | --- |
| 30001 | Allow Return Traffic |
| 30002 | Block Invalid Traffic |
| 10000–10003 | DShieldBlock, SpamhausDROP, SpamhausDROPv6, FireHOL_L1 |
| 30003+ | Eigene Allow- oder Routing-Regeln |
| 39999 | Block All Traffic (Default) |

## 🧰 9. Troubleshooting

### 🔹 WebUI lädt nicht mehr

```bash
/usr/local/bin/clear_udmp_firewallgroups.sh
```

Danach `update_udmp_blocklists.sh` neu starten.

### 🔹 Keine Listen geladen

Prüfe Internetverbindung, DNS-Auflösung und `curl`-Ausgabe.

### 🔹 Logdatei prüfen

```bash
tail -f /var/log/update_udmp_spamhaus.log
```

### 🔹 Debug aktivieren

In `/etc/udmp_api.env`:

```bash
DEBUG=true
```

Damit werden alle API-Calls und HTTP-Codes sichtbar.

## 🔄 10. Backup & Wiederherstellung

Vor größeren Änderungen kannst du Gruppen exportieren:

```bash
curl -sS -b /tmp/unifi_cookie.txt \
  -H "X-CSRF-Token: $CSRF" \
  "https://unifi.local/proxy/network/api/s/default/rest/firewallgroup" > /root/fw_backup.json
```

Wiederherstellung:

```bash
curl -sS -b /tmp/unifi_cookie.txt \
  -H "X-CSRF-Token: $CSRF" \
  -X POST -d @fw_backup.json \
  "https://unifi.local/proxy/network/api/s/default/rest/firewallgroup"
```

## 🧩 11. Sicherheitshinweise

- Die UDM Pro API ist nicht offiziell dokumentiert — Änderungen durch Firmwareupdates möglich.
- Firewallgruppen mit mehr als 1500 Einträgen können das WebUI beschädigen.
- Deshalb im Skript begrenzen (`MAX_GROUP_MEM_V4`, `MAX_GROUP_MEM_V6`).
- Passwortdatei niemals mit 777-Rechten speichern – nur Root darf lesen.

## 🧾 12. Lizenz

MIT License © 2025 – Erstellt von Peter

Letztes Update: 27. Oktober 2025 — Version: 1.0-stable
