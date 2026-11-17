#!/bin/sh
# luci-app-netbird —— 一键安装(添加软件源,安装本插件 + 简体中文语言包)。
# 用法:  sh -c "$(curl -fsSL https://luci-app-netbird.okk.sh/install-zh.sh)"
#   或:  wget -O - https://luci-app-netbird.okk.sh/install-zh.sh | sh
set -e

REPO="https://luci-app-netbird.okk.sh"

# 添加软件源。先把 feed.sh 下载到文件再执行:`wget | sh` 在下载失败时 sh 读到空输入、
# 退出码为 0,会在没有软件源的情况下继续安装。
FEED_SH="$(mktemp)"
trap 'rm -f "$FEED_SH"' EXIT
if command -v wget >/dev/null 2>&1; then
	wget -O "$FEED_SH" "$REPO/feed.sh"
else
	curl -fsSL -o "$FEED_SH" "$REPO/feed.sh"
fi
[ -s "$FEED_SH" ] || { echo "无法下载 $REPO/feed.sh" >&2; exit 1; }
sh "$FEED_SH"

# 安装本插件 + 简体中文语言包
if [ -x /bin/opkg ]; then
	opkg install luci-app-netbird luci-i18n-netbird-zh-cn
else
	apk add luci-app-netbird luci-i18n-netbird-zh-cn
fi

# OpenWrt 22.03/23.05 自带的 uclient-fetch 遇到 github.com 4KB 以上的响应头就停住,
# 没有 curl 时插件下载不了官方版 NetBird,所以在这类系统上顺带装 curl(连同 libcurl 约 250KB)。
# 这一步失败不影响已经装好的插件。
if ! command -v curl >/dev/null 2>&1 && command -v uclient-fetch >/dev/null 2>&1 \
	&& ! uclient-fetch --help 2>&1 | grep -q -- '--header'; then
	echo "正在安装 curl(在这个 OpenWrt 版本上下载官方版 NetBird 需要它)..."
	if [ -x /bin/opkg ]; then
		opkg install curl || echo "警告:curl 安装失败;之后可以用 \"opkg install curl\" 补装,补装后才能使用官方版 NetBird。" >&2
	else
		apk add curl || echo "警告:curl 安装失败;之后可以用 \"apk add curl\" 补装,补装后才能使用官方版 NetBird。" >&2
	fi
fi

echo ""
echo "完成。打开 LuCI -> 服务 -> NetBird。"
