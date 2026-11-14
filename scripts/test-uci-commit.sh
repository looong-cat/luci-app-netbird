#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# 在一次性 OpenWrt 容器中,用系统自带的 ucode、libuci 和 uci 命令验证后端的 UCI 提交辅助函数,
# 禁止在路由器上运行(会改写 /etc/config)。22.03 的 ucode 带配置名提交会失败,至少在 22.03
# 和一个新版本上各跑一次:
# docker run --rm --platform linux/amd64 -v "$PWD:/src:ro" \
#   openwrt/rootfs:x86-64-22.03.6 sh /src/scripts/test-uci-commit.sh
set -eu
[ -f /.dockerenv ] || { echo '需要一次性容器环境' >&2; exit 1; }
src="${1:-/src}/luci-app-netbird/root/usr/share/rpcd/ucode/netbird.uc"
work=/tmp/nb-uci-test
rm -rf "$work" /tmp/.uci; mkdir -p "$work" /etc/config

# 只提取 _uci_commit 本身;shell_quote 用与后端同样语义的最小实现
helper=$(awk '/^function _uci_commit\(/{f=1} f{print} f&&/^}/{exit}' "$src")
[ -n "$helper" ] || { echo '源码里找不到 _uci_commit' >&2; exit 1; }

printf "config netbird 'settings'\n\toption management_url ''\n" > /etc/config/netbird
# 同一游标里只读不改的配置:提交后注释必须还在,说明没被重写,也没留下暂存改动
printf "# keep-this-comment\nconfig zone 'z'\n\toption name 'lan'\n" > /etc/config/nbtestfw

cat > "$work/t.uc" <<EOF
import * as uci from 'uci';
function shell_quote(s) { return "'" + replace(s, "'", "'\\\\''") + "'"; }
$helper
let c = uci.cursor();
c.get('nbtestfw', 'z', 'name');
c.set('netbird', 'settings', 'management_url', 'https://b.example');
print('helper=', _uci_commit(c, 'netbird') ? 'ok' : 'fail', '\n');
EOF
# 22.03 镜像没有 timeout:后台运行,超时就杀掉并判失败(防止死循环把测试挂住)
ucode "$work/t.uc" > "$work/out" 2>&1 &
pid=$!; i=0
while kill -0 "$pid" 2>/dev/null; do
	i=$((i + 1))
	[ "$i" -ge 15 ] && { kill -9 "$pid"; echo '失败:ucode 15 秒未结束(死循环)' >&2; exit 1; }
	sleep 1
done
wait "$pid" || { cat "$work/out"; echo '失败:ucode 退出码非 0' >&2; exit 1; }
cat "$work/out"
grep -qx 'helper=ok' "$work/out" || { echo '失败:辅助函数没有提交成功' >&2; exit 1; }
[ "$(uci -q get netbird.settings.management_url)" = 'https://b.example' ] || { echo '失败:配置文件里读不到写入的值' >&2; exit 1; }
[ -z "$(uci changes)" ] || { uci changes; echo '失败:留下了未提交的暂存改动' >&2; exit 1; }
grep -q '^# keep-this-comment$' /etc/config/nbtestfw || { echo '失败:没改动的配置被重写了' >&2; exit 1; }
echo 'UCI 提交回归通过'
