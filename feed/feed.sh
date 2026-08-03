#!/bin/sh
# luci-app-netbird — add the signed package feed (opkg or apk).
# Usage:  wget -O - https://luci-app-netbird.okk.sh/feed.sh | sh
set -e

REPO="https://luci-app-netbird.okk.sh"
NAME="netbird"

if [ ! -x /bin/opkg ] && [ ! -x /usr/bin/apk ]; then
	echo "This needs OpenWrt/ImmortalWrt with opkg or apk." >&2
	exit 1
fi

# branch by release; the package is arch-independent (PKGARCH:=all)
. /etc/openwrt_release
case "$DISTRIB_RELEASE" in
	# 22.03 and 23.05 are opkg-based and the package is arch-independent, so the
	# 24.10 ipk feed installs there unchanged (all runtime deps —
	# rpcd-mod-ucode, ucode, conntrack, netbird — exist in both feeds).
	# 22.03 is the oldest supported release: it is the first one shipping ucode
	# and rpcd-mod-ucode, which the backend of this app is written in.
	*22.03*) BRANCH="openwrt-24.10" ;;
	*23.05*) BRANCH="openwrt-24.10" ;;
	*24.10*) BRANCH="openwrt-24.10" ;;
	*25.12*) BRANCH="openwrt-25.12" ;;
	*SNAPSHOT*)
		if [ -x /usr/bin/apk ]; then
			# main snapshot builds are apk-only and package-arch-independent,
			# so the 25.12 apk feed installs there unchanged.
			BRANCH="openwrt-25.12"
		else
			echo "opkg-based snapshot builds are not supported; use a 22.03/23.05/24.10/25.12 release or a current apk-based snapshot." >&2
			exit 1
		fi
		;;
	# 21.02 and older ship no ucode / rpcd-mod-ucode, so the backend cannot run there.
	*) echo "Unsupported release: $DISTRIB_RELEASE (supported: 22.03, 23.05, 24.10, 25.12, snapshot)." >&2; exit 1 ;;
esac
FEED="$REPO/$BRANCH/all/$NAME"

if [ -x /bin/opkg ]; then
	echo "Adding opkg feed..."
	wget -O /tmp/netbird-key.pub "$REPO/key-build.pub"
	opkg-key add /tmp/netbird-key.pub
	rm -f /tmp/netbird-key.pub
	sed -i "\\#$REPO#d" /etc/opkg/customfeeds.conf
	echo "src/gz $NAME $FEED" >> /etc/opkg/customfeeds.conf
	opkg update
else
	echo "Adding apk feed..."
	wget -O /etc/apk/keys/luci-app-netbird.pem "$REPO/public-key.pem"
	mkdir -p /etc/apk/repositories.d
	LIST=/etc/apk/repositories.d/customfeeds.list
	[ -f "$LIST" ] && sed -i "\\#$REPO#d" "$LIST"
	echo "$FEED/packages.adb" >> "$LIST"
	apk update
fi

echo "Feed added: $FEED"
echo "Install:  opkg install luci-app-netbird"
echo "    (apk: apk add luci-app-netbird)"
