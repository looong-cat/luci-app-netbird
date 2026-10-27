#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
#
# check-flags.sh —— NetBird `up` flag 同步检查(跟进上游新功能的确定性工具)。
#
# 对比「`netbird up --help` 暴露的 flag」与「本插件已映射的设置项」,报告:
#   🆕 上游有、插件未映射  → 评审是否加入(设置页字段 + init.d 渲染行 + i18n)
#   ⚠️ 插件映射、此二进制没有 → 旧版属正常(init.d 能力门控会跳过);若在最新版出现 = 被重命名/移除,需跟进
#
# 维护用途:每次跟随 NetBird release 升级时跑一次,把「跟进上游」从「凭记忆」变成 diff。
#   「已映射」的权威来源 = root/etc/init.d/netbird-settings 的渲染/门控行(不是凭记忆的清单)。
#
# 取 help 文本(优先级):
#   1) ./check-flags.sh /path/to/netbird          指定二进制
#   2) NETBIRD=/path/to/netbird ./check-flags.sh   环境变量指定
#   3) NB_HELP_FILE=help.txt ./check-flags.sh       离线:预存的 `netbird up --help` 文本
#   4) 都没有 → 从 PATH 找 netbird
#
# 退出码:0 = 无未映射新 flag;1 = 有(可作 CI 门禁);2 = 用法/环境错误。

set -u

ROOT="$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)"
INITD="$ROOT/root/etc/init.d/netbird-settings"
if [ ! -f "$INITD" ] && [ -f "$ROOT/luci-app-netbird/root/etc/init.d/netbird-settings" ]; then
	INITD="$ROOT/luci-app-netbird/root/etc/init.d/netbird-settings"
fi

# ── 已知跳过清单(非设置项 / 有意不暴露)—— 改变决策时更新这里 ────────────────────
# 操作/认证类 flag(不属于「设置」页范畴)。--log-level 只作用于 up 这个 CLI 进程自身,
# 设置页的日志级别经 `netbird debug log level` 下发到守护进程(见 nb-log-level.sh):
SKIP_OPERATIONAL="--admin-url --anonymize --anonymize-level --config --daemon-addr --foreground-mode --help --log-file --log-level --no-browser --profile --qr --service --setup-key --setup-key-file"
# 有意不暴露的设置 flag(评审后决定暂不做;若改主意,从此处移除并去 UI/init.d/i18n 添加):
#   --mtu                                              错配致服务假死(脚枪),不暴露
#   --external-ip-map --extra-dns-labels
#   --extra-iface-blacklist --dns-router-interval
#   --ssh-jwt-cache-ttl                                冷门/高级
#   --network-monitor --disable-auto-connect
#   --dns-resolver-address                             待评估,暂未做(候选)
#   --enable-lazy-connection                           上游 0.74.1 起退役(help 已移除,旧调用 inert):
#                                                      lazy connection 改由管理端 feature flag 驱动,
#                                                      本地覆盖走 NB_LAZY_CONN 环境变量(on/off),
#                                                      不再是 up flag;条目保留以兼容 ≤0.73 的 help
#   --enable-local-metrics --local-metrics-address     本机 metrics 端点,路由器场景价值低
SKIP_OMITTED="--mtu --external-ip-map --extra-dns-labels --extra-iface-blacklist --dns-router-interval --ssh-jwt-cache-ttl --network-monitor --disable-auto-connect --enable-lazy-connection --dns-resolver-address --enable-local-metrics --local-metrics-address"
SKIP=" $SKIP_OPERATIONAL $SKIP_OMITTED "

# ── 取 `netbird up --help` 文本 ───────────────────────────────────────────────
get_help() {
	if [ -n "${NB_HELP_FILE:-}" ]; then
		[ -f "$NB_HELP_FILE" ] || { echo "ERR: NB_HELP_FILE 不存在: $NB_HELP_FILE" >&2; exit 2; }
		cat "$NB_HELP_FILE"
		return 0
	fi
	nb="${1:-}"
	[ -n "$nb" ] || nb="${NETBIRD:-}"
	[ -n "$nb" ] || nb="$(command -v netbird 2>/dev/null || true)"
	if [ -z "$nb" ] || [ ! -x "$nb" ]; then
		echo "ERR: 找不到 netbird 二进制。用 '$0 /path/to/netbird'、NETBIRD=... 或 NB_HELP_FILE=... 指定。" >&2
		exit 2
	fi
	"$nb" up --help 2>&1
}

[ -f "$INITD" ] || { echo "ERR: 找不到 init.d 渲染脚本: $INITD" >&2; exit 2; }

HELP="$(get_help "${1:-}")" || exit $?

# 可用 flag:从 help 抽所有长 flag
AVAIL="$(printf '%s\n' "$HELP" | grep -oE '\-\-[a-z][a-z0-9-]+' | sort -u)"
# 已映射 flag:从 init.d 的**非注释行**抽 flag(排除注释行避免取反矩阵/示例里的 flag 名混入)。
# 不限定 set--/_has_flag 行:因 --preshared-key 出于安全设计不走 set--、而在执行行追加(见 init.d),
# 限定 set-- 会漏掉它(会误报)。非注释行只含真实渲染/门控/执行用到的 flag,无噪音。
MAPPED="$(grep -vE '^[[:space:]]*#' "$INITD" | grep -oE '\-\-[a-z][a-z0-9-]+' | sort -u)"

[ -n "$AVAIL" ] || { echo "ERR: 未能从 help 文本解析出任何 flag(格式异常?)" >&2; exit 2; }

MAPPED_SP=" $(printf '%s ' $MAPPED)"
AVAIL_SP=" $(printf '%s ' $AVAIL)"
in_list() { case "$2" in *" $1 "*) return 0;; *) return 1;; esac; }

NEW=""
for f in $AVAIL; do
	in_list "$f" "$MAPPED_SP" && continue
	in_list "$f" "$SKIP" && continue
	NEW="$NEW $f"
done

GONE=""
for f in $MAPPED; do
	in_list "$f" "$AVAIL_SP" && continue
	GONE="$GONE $f"
done

echo "=== NetBird up flag 同步检查 ==="
echo "  help 暴露 flag 数 : $(printf '%s\n' "$AVAIL" | grep -c .)"
echo "  插件已映射 flag 数: $(printf '%s\n' "$MAPPED" | grep -c .)"
echo "  已知跳过 flag 数  : $(printf '%s\n' $SKIP | grep -c .)"
echo

rc=0
if [ -n "$NEW" ]; then
	echo "🆕 上游有、插件未映射(评审是否加:设置页字段 + init.d 渲染 + i18n):"
	for f in $NEW; do echo "     $f"; done
	rc=1
else
	echo "✅ 无未映射的新 flag(上游 flag 均已映射或在已知跳过清单)。"
fi
echo
if [ -n "$GONE" ]; then
	echo "⚠️ 插件映射了、但此二进制没有此 flag:"
	echo "   (跑旧版二进制属正常 —— init.d 能力门控会静默跳过;若在最新版出现 = flag 被重命名/移除,需跟进)"
	for f in $GONE; do echo "     $f"; done
fi

exit $rc
