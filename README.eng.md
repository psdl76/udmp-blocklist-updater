🛡️ UDM Pro – Automatic Firewall Blocklists (Spamhaus, DShield, FireHOL Level 1)
==================================================================================

This project provides two shell scripts for the UniFi Dream Machine Pro (UDM Pro) that automatically retrieve IP blocklists, inject them into firewall groups, and optionally remove them again. They are fully BusyBox/POSIX compatible, use the UniFi Controller REST API, and are built for stability, security, and transparency.

## 📦 Included Scripts

| File | Description |
| --- | --- |
| `/usr/local/bin/update_udmp_blocklists.sh` | Main script: Downloads IP blocklists, updates firewall groups |
| `/usr/local/bin/clear_udmp_firewallgroups.sh` | Helper script: Safely removes previously created groups |
| `/etc/udmp_api.env` | Configuration file with host, user, and group parameters |
| `/etc/unifi-api.secret` | File containing the UniFi admin password (plain text only) |

## ⚙️ Requirements

- UniFi Dream Machine Pro (UDM Pro) or UDM SE
- Firmware ≥ 3.0.x with a working REST API
- `curl`, `openssl`, `awk`, `grep`, `sort`, `head` (available by default on the UDM)
- Optional for `clear_udmp_firewallgroups.sh`: `jq`

## 🧩 1. Create Configuration

### 📄 `/etc/unifi-api.secret`

This file contains only the password of your UniFi user (e.g., `admin` or `pseidl`):

```bash
echo "myPassword123" > /etc/unifi-api.secret
chmod 600 /etc/unifi-api.secret
```

## 🧩 2. Environment File `/etc/udmp_api.env`

This file controls all parameters and limits.

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
# Limit per list (recommended: ≤1500 entries)
MAX_GROUP_MEM_V4=1500
MAX_GROUP_MEM_V6=1500
```

> Note: The variables `MAX_GROUP_MEM_V4` and `MAX_GROUP_MEM_V6` prevent oversized lists from breaking the web UI.

## 🚀 3. Install Scripts

```bash
install -m 755 update_udmp_blocklists.sh /usr/local/bin/
install -m 755 clear_udmp_firewallgroups.sh /usr/local/bin/
```

The scripts should be executed with root privileges:

```bash
/usr/local/bin/update_udmp_blocklists.sh
```

If everything runs correctly, you will see log messages like:

```text
[INFO] Starting update (Site=default, Host=unifi.local, max v4=1500, max v6=1500)
[INFO] Downloading list https://www.spamhaus.org/drop/drop.txt …
[INFO] Updating group 'SpamhausDROP' with 1469 entries …
[INFO] Processed all configured lists.
```

## ⏱️ 4. Automatic Updates (Cron Job)

Create a cron job to refresh the lists regularly (e.g., daily at 2 a.m.):

```bash
echo "0 2 * * * root /usr/local/bin/update_udmp_blocklists.sh >/dev/null 2>&1" >> /etc/crontab
```

## 🧹 5. Reset / Cleanup

If the web UI or the API stops responding or groups become corrupted:

```bash
/usr/local/bin/clear_udmp_firewallgroups.sh
```

To remove all firewall groups:

```bash
/usr/local/bin/clear_udmp_firewallgroups.sh --all
```

This script safely removes all created groups via the REST API.

## 🧠 6. How It Works

1. The update script authenticates via the REST API (`/api/auth/login`).
2. It downloads the blocklists:
   - Spamhaus DROP (IPv4)
   - Spamhaus DROPv6 (IPv6)
   - DShield blocklist
   - FireHOL Level 1 (baseline protection)
3. It automatically creates missing firewall groups.
4. It replaces the group members with the new IP/network entries.
5. All actions are written to the log file and syslog.

## 🧩 7. Recommended Firewall Policies

Create the following directions per blocklist in the UniFi Controller:

| Source → Destination | Description |
| --- | --- |
| External → Internal | Blocks external IPs from the blocklists |
| External → Gateway | Protects the controller itself |
| VPN → Internal | Blocks infected VPN clients in the LAN |
| VPN → External | Optional: Control outbound VPN traffic |
| VPN → Gateway | Prevents direct access to the gateway |

> These directions cover 95% of relevant protection scenarios. Additional VLAN or IoT isolation can be defined separately.

## ⚙️ 8. Rule Order in the Controller

The UDM operates with stateful inspection. This means that once a connection is established, return traffic is allowed. Therefore, the “Allow Return Traffic” rule is not a security risk—it only permits response packets that belong to existing connections.

### 🧭 Recommended Order

| Priority | Rule |
| :---: | --- |
| 30001 | Allow Return Traffic |
| 30002 | Block Invalid Traffic |
| 10000–10003 | DShieldBlock, SpamhausDROP, SpamhausDROPv6, FireHOL_L1 |
| 30003+ | Custom allow or routing rules |
| 39999 | Block All Traffic (default) |

## 🧰 9. Troubleshooting

### 🔹 Web UI no longer loads

```bash
/usr/local/bin/clear_udmp_firewallgroups.sh
```

Then restart `update_udmp_blocklists.sh`.

### 🔹 No lists downloaded

Check internet connectivity, DNS resolution, and the `curl` output.

### 🔹 Inspect the log file

```bash
tail -f /var/log/update_udmp_spamhaus.log
```

### 🔹 Enable debug mode

In `/etc/udmp_api.env`:

```bash
DEBUG=true
```

This exposes all API calls and HTTP status codes.

## 🔄 10. Backup & Restore

Before major changes, you can export the groups:

```bash
curl -sS -b /tmp/unifi_cookie.txt \
  -H "X-CSRF-Token: $CSRF" \
  "https://unifi.local/proxy/network/api/s/default/rest/firewallgroup" > /root/fw_backup.json
```

Restoration:

```bash
curl -sS -b /tmp/unifi_cookie.txt \
  -H "X-CSRF-Token: $CSRF" \
  -X POST -d @fw_backup.json \
  "https://unifi.local/proxy/network/api/s/default/rest/firewallgroup"
```

## 🧩 11. Security Notes

- The UDM Pro API is not officially documented—firmware updates may introduce changes.
- Firewall groups with more than 1,500 entries can break the web UI.
- Therefore, enforce limits in the script (`MAX_GROUP_MEM_V4`, `MAX_GROUP_MEM_V6`).
- Never store the password file with 777 permissions—only root should read it.

## 🧾 12. License

MIT License © 2025 – Created by Peter

Last update: 27 October 2025 — Version: 1.0-stable
