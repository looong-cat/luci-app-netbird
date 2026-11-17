#!/bin/sh
# luci-app-netbird — one-click install (adds the feed, then installs the app).
# Usage:  sh -c "$(curl -fsSL https://luci-app-netbird.okk.sh/install.sh)"
#    or:  wget -O - https://luci-app-netbird.okk.sh/install.sh | sh
set -e

REPO="https://luci-app-netbird.okk.sh"

# add the feed. Download feed.sh to a file first: with `wget | sh` a failed download
# feeds sh empty input, which exits 0, and installation would continue without the feed.
FEED_SH="$(mktemp)"
trap 'rm -f "$FEED_SH"' EXIT
if command -v wget >/dev/null 2>&1; then
	wget -O "$FEED_SH" "$REPO/feed.sh"
else
	curl -fsSL -o "$FEED_SH" "$REPO/feed.sh"
fi
[ -s "$FEED_SH" ] || { echo "Could not download $REPO/feed.sh" >&2; exit 1; }
sh "$FEED_SH"

# install the app
if [ -x /bin/opkg ]; then
	opkg install luci-app-netbird
else
	apk add luci-app-netbird
fi

# OpenWrt 22.03/23.05 ship a uclient-fetch that stops reading on github.com's 4KB+ response
# headers, so without curl the app cannot download the official NetBird release. Install curl
# there (about 250KB with libcurl). A failure here does not undo the installation.
if ! command -v curl >/dev/null 2>&1 && command -v uclient-fetch >/dev/null 2>&1 \
	&& ! uclient-fetch --help 2>&1 | grep -q -- '--header'; then
	echo "Installing curl, needed to download the official NetBird release on this OpenWrt version..."
	if [ -x /bin/opkg ]; then
		opkg install curl || echo "Warning: could not install curl; install it later with \"opkg install curl\" to use the official NetBird release." >&2
	else
		apk add curl || echo "Warning: could not install curl; install it later with \"apk add curl\" to use the official NetBird release." >&2
	fi
fi

echo ""
echo "Done. Open LuCI -> Services -> NetBird."
