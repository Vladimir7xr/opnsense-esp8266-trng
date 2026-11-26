#!/bin/sh
set -e

if [ "$(id -u)" -ne 0 ]; then
    echo "Error: This script must be run as root."
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="$SCRIPT_DIR/opnsense/usr/local"

if [ ! -d "$SRC_DIR" ]; then
    echo "Error: Source directory $SRC_DIR not found."
    exit 1
fi

echo "[1/6] Creating target directories under /usr/local..."
mkdir -p /usr/local/etc/devd
mkdir -p /usr/local/etc/rc.syshook.d/start
mkdir -p /usr/local/etc/rc.syshook.d/stop
mkdir -p /usr/local/etc/inc/plugins.inc.d
mkdir -p /usr/local/sbin
mkdir -p /usr/local/opnsense/service/conf/actions.d
mkdir -p /usr/local/opnsense/mvc/app/controllers/OPNsense/EspTrng/Api
mkdir -p /usr/local/opnsense/mvc/app/models/OPNsense/EspTrng/ACL
mkdir -p /usr/local/opnsense/www/js/widgets/Metadata

echo "[2/6] Copying integration files..."
cp -R "$SRC_DIR/"* /usr/local/

echo "[3/6] Setting file permissions..."
chmod 755 /usr/local/sbin/esp-trng-feeder.sh
chmod 755 /usr/local/sbin/esp-trng-test.sh
chmod 755 /usr/local/etc/rc.syshook.d/start/90-esp-trng
chmod 755 /usr/local/etc/rc.syshook.d/stop/90-esp-trng

chmod 644 /usr/local/etc/devd/esp_trng.conf
chmod 644 /usr/local/etc/inc/plugins.inc.d/esp_trng.inc
chmod 644 /usr/local/opnsense/service/conf/actions.d/actions_esp_trng.conf
chmod 644 /usr/local/opnsense/mvc/app/controllers/OPNsense/EspTrng/Api/ServiceController.php
chmod 644 /usr/local/opnsense/mvc/app/models/OPNsense/EspTrng/ACL/ACL.xml
chmod 644 /usr/local/opnsense/www/js/widgets/Metadata/EspTrng.xml
chmod 644 /usr/local/opnsense/www/js/widgets/EspTrng.js

echo "[4/6] Validating PHP syntax..."
php -l /usr/local/etc/inc/plugins.inc.d/esp_trng.inc
php -l /usr/local/opnsense/mvc/app/controllers/OPNsense/EspTrng/Api/ServiceController.php

echo "[5/6] Reloading devd, plugins, ACL cache, and configd..."
service devd restart
for idx in $(sysctl -N dev.uslcom 2>/dev/null | sed -n 's/^dev\.uslcom\.\([0-9]*\)\.%pnpinfo$/\1/p'); do
    pnp=$(sysctl -n "dev.uslcom.${idx}.%pnpinfo" 2>/dev/null)
    case "$pnp" in
        *"vendor=0x10c4"*"product=0xea60"*|*"product=0xea60"*"vendor=0x10c4"*)
            tty=$(sysctl -n "dev.uslcom.${idx}.ttyname" 2>/dev/null)
            if [ -n "$tty" ] && [ -c "/dev/cua${tty}" ]; then
                ln -sf "/dev/cua${tty}" /dev/trng_esp
                break
            fi
            ;;
    esac
done

rm -f /tmp/opnsense_acl_cache.json
/usr/local/etc/rc.configure_plugins
service configd restart
configctl webgui restart

echo "[6/6] Starting ESP8266 TRNG feeder..."
/usr/local/etc/rc.syshook.d/stop/90-esp-trng 2>/dev/null || true
sleep 1
/usr/local/etc/rc.syshook.d/start/90-esp-trng

echo ""
echo "[OK] Installation complete!"
echo "Please log out and log back into the OPNsense Web GUI, then add the 'ESP8266 Hardware TRNG' widget."
