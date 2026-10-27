#!/bin/sh
# luci-app-netbird — remove the packages, the feed entry, and the signing key.
# NetBird itself (the `netbird` package) and its config/identity are left untouched.
# Usage:  wget -O - https://luci-app-netbird.okk.sh/uninstall.sh | sh

REPO="https://luci-app-netbird.okk.sh"

if [ -x /bin/opkg ]; then
	opkg remove luci-i18n-netbird-zh-cn luci-app-netbird 2>/dev/null
	sed -i "\\#$REPO#d" /etc/opkg/customfeeds.conf 2>/dev/null
	opkg update 2>/dev/null
	zh_left=$(opkg list-installed 2>/dev/null | grep -c '^luci-i18n-.*-zh-cn ')
elif [ -x /usr/bin/apk ]; then
	# apk removes no-longer-needed dependencies together with the named
	# packages. If netbird was pulled in as a dependency of the LuCI app,
	# removing the app would silently take the VPN client (and its kernel
	# modules) down with it — pin netbird as explicitly installed first.
	apk list --installed 2>/dev/null | grep -q '^netbird-' &&
		{ apk add --no-network netbird 2>/dev/null || apk add netbird 2>/dev/null; }
	apk del luci-i18n-netbird-zh-cn luci-app-netbird 2>/dev/null
	sed -i "\\#$REPO#d" /etc/apk/repositories.d/customfeeds.list 2>/dev/null
	rm -f /etc/apk/keys/luci-app-netbird.pem
	# The app keeps the key across sysupgrade via /etc/sysupgrade.conf; drop that line too.
	sed -i '\#^/etc/apk/keys/luci-app-netbird\.pem$#d' /etc/sysupgrade.conf 2>/dev/null
	zh_left=$(apk list --installed 2>/dev/null | grep -c '^luci-i18n-.*-zh-cn-')
fi

# LuCI i18n packages register their language in /etc/config/luci via a
# uci-defaults script, but nothing unregisters it on removal — the entry
# would linger in the LuCI language dropdown. Drop it once no Simplified
# Chinese language pack (from any LuCI app) remains installed.
if [ "${zh_left:-1}" -eq 0 ] && uci -q get luci.languages.zh_cn >/dev/null; then
	uci -q delete luci.languages.zh_cn
	[ "$(uci -q get luci.main.lang)" = "zh_cn" ] && uci -q set luci.main.lang='auto'
	uci -q commit luci
fi

echo "Removed luci-app-netbird and its feed. NetBird and your settings are untouched."
echo "To use NetBird in the LuCI Network/Firewall, remove its zone from the Network tab first."
