#!/bin/sh
set -e

if [ "$(id -u)" -ne 0 ]; then
    echo "Error: This script must be run as root."
    exit 1
fi

echo "[1/3] Stopping ESP8266 TRNG feeder..."
if [ -x /usr/local/etc/rc.syshook.d/stop/90-esp-trng ]; then
    /usr/local/etc/rc.syshook.d/stop/90-esp-trng
fi

echo "[2/3] Removing installed files..."
rm -f /usr/local/etc/devd/esp_trng.conf
rm -f /usr/local/sbin/esp-trng-feeder.sh
rm -f /usr/local/sbin/esp-trng-test.sh
rm -f /usr/local/etc/rc.syshook.d/start/90-esp-trng
rm -f /usr/local/etc/rc.syshook.d/stop/90-esp-trng
rm -f /usr/local/opnsense/service/conf/actions.d/actions_esp_trng.conf
rm -f /usr/local/etc/inc/plugins.inc.d/esp_trng.inc
rm -rf /usr/local/opnsense/mvc/app/controllers/OPNsense/EspTrng
rm -rf /usr/local/opnsense/mvc/app/models/OPNsense/EspTrng
rm -f /usr/local/opnsense/www/js/widgets/Metadata/EspTrng.xml
rm -f /usr/local/opnsense/www/js/widgets/EspTrng.js
rm -f /dev/trng_esp
rm -f /tmp/esp_trng_stats.json /tmp/esp_trng_dd.log

echo "[3/3] Reloading OPNsense services..."
service devd restart
rm -f /tmp/opnsense_acl_cache.json
/usr/local/etc/rc.configure_plugins
service configd restart
configctl webgui restart

echo "[OK] ESP8266 Hardware TRNG removed."