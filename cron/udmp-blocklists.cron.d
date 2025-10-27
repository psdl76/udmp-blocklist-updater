# /etc/cron.d/udmp-blocklists
SHELL=/bin/sh
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
30 4 * * * root /usr/local/bin/update_udmp_blocklists.sh >/dev/null 2>&1
