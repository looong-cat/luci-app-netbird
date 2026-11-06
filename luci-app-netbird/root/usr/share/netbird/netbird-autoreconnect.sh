#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
#
# netbird-autoreconnect.sh — 保守自动重连:
# - 只有 netbird.runtime.desired_connected=1 时才尝试恢复。
# - 已连接时自动 adopt desired_connected=1,并清理历史 transient 错误。
# - 认证 fatal / NeedsLogin 会置 desired_connected=0,避免无限重试。
# - 不保存 setup key;首次注册失败仍要求用户重新点击连接。

TAG="luci-netbird-watchdog"
INTERVAL="${NB_AUTORECONNECT_INTERVAL:-30}"
# 有界执行(timeout 不可用时的可移植实现)与 netbird-settings 共用。
. "${NB_LIBDIR:-/usr/share/netbird}/nb-run-bounded.sh"
# 守护进程日志级别下发(与 netbird-settings 共用)。
. "${NB_LIBDIR:-/usr/share/netbird}/nb-log-level.sh"
# 重连连续失败时指数退避(INTERVAL→2x→…→封顶 MAX_INTERVAL),连上即复位;
# 避免长时间 outage 每 INTERVAL 秒一次高成本 do_up + 日志刷屏。
MAX_INTERVAL="${NB_AUTORECONNECT_MAX_INTERVAL:-300}"
backoff="$INTERVAL"
attempt_wait=0   # 距下次重连尝试还需等待的秒数(按 INTERVAL 递减);轮询本身不退避,保证恢复/清错及时

# 收到 procd/系统 TERM/INT 立即退出,避免拖慢 stop/reboot。
# ash 要等前台子进程结束才执行 trap,前台 sleep 会让 TERM 拖满整个 INTERVAL、
# 被 procd 超时后 SIGKILL 并遗留孤儿 sleep;故等待一律走 _sleep(后台 sleep + wait,
# wait 可被信号打断),trap 里顺带结束该 sleep。status/ubus 调用仍是前台执行,
# 信号会推迟到其结束(各自有超时兜底)。
_sleep_pid=""

_on_signal() {
	[ -n "$_sleep_pid" ] && kill "$_sleep_pid" 2>/dev/null
	exit 0
}

trap _on_signal TERM INT

_sleep() {
	sleep "$1" &
	_sleep_pid=$!
	wait "$_sleep_pid"
	_sleep_pid=""
}

_log() {
	logger -t "$TAG" "$*"
}

_reset_backoff() {
	backoff="$INTERVAL"
}

_bump_backoff() {
	backoff=$((backoff * 2))
	[ "$backoff" -gt "$MAX_INTERVAL" ] && backoff="$MAX_INTERVAL"
}

_resolve_bin() {
	if command -v netbird >/dev/null 2>&1; then
		command -v netbird
		return 0
	fi
	for p in /usr/bin/netbird /usr/sbin/netbird; do
		[ -x "$p" ] && { echo "$p"; return 0; }
	done
	return 1
}

_desired() {
	uci -q get netbird.runtime.desired_connected 2>/dev/null
}

_runtime_set() {
	uci -q set "netbird.runtime.$1=$2" 2>/dev/null || return 1
	uci -q commit netbird 2>/dev/null || return 1
}

_set_desired() {
	_runtime_set desired_connected "$1" || _log "warning: failed to set desired_connected=$1"
}

_set_error() {
	_runtime_set last_error "$1" || _log "warning: failed to set last_error"
}

_clear_error() {
	_runtime_set last_error "" >/dev/null 2>&1 || true
}

# 参数:bin 之后的其余参数原样传给 status(如 --json)。daemon 卡住时 6 秒后放弃本轮采样。
_with_timeout_status() {
	bin="$1"
	shift
	nb_run_bounded 6 "$bin" status "$@" 2>&1
}

# JSON 采样字段提取(sed 即可,不引入 jsonfilter 依赖)。
# daemonStatus 是 status --json 顶层字段;management.connected 的字段序由上游结构体
# 固定(url→connected→error),用 [^}]* 防御字段增插。
_json_daemon_status() {
	printf '%s' "$1" | sed -n 's/.*"daemonStatus":"\([^"]*\)".*/\1/p'
}

_json_mgmt_connected() {
	printf '%s' "$1" | sed -n 's/.*"management":{[^}]*"connected":\([a-z]*\).*/\1/p'
}

_match() {
	printf '%s\n' "$1" | grep -Eiq "$2"
}

_is_connected() {
	_match "$1" 'Management:[[:space:]]*Connected'
}

_is_needs_login() {
	_match "$1" 'NeedsLogin|needs login|login required|no peer auth method provided'
}

_is_auth_fatal() {
	_match "$1" 'setup key is invalid|invalid setup key|setup key.*(expired|revoked|disabled|usage limit|not found|already used)|PermissionDenied|Unauthenticated|code[[:space:]]*=[[:space:]]*NotFound|peer not found|not registered|removed from network|login has expired'
}

_is_transient_disconnect() {
	_match "$1" 'Management:[[:space:]]*Disconnected|Unavailable|DeadlineExceeded|connection refused|i/o timeout|network is unreachable|no such host|temporary failure|TLS handshake timeout|context deadline exceeded|keepalive ping failed|transport is closing|connection reset|timeout after'
}

# 连接不是经 do_up 建立时(命令行手动连接、daemon 自行恢复),没有别的入口处理待应用标记。
# 连续 4 轮(90 秒以上)已连接且标记仍在才应用,避开 do_up 正在等待确认、稍后会自行补应用的窗口。
pending_rounds=0
_maybe_apply_pending_settings() {
	if [ ! -f /etc/netbird-settings.pending ]; then
		pending_rounds=0
		return 0
	fi
	pending_rounds=$((pending_rounds + 1))
	[ "$pending_rounds" -lt 4 ] && return 0
	pending_rounds=0
	_log "connected with pending settings; applying them"
	/etc/init.d/netbird-settings reload >/dev/null 2>&1
}

_attempt_reconnect() {
	_log "management disconnected; trying do_up with existing identity"
	out="$(ubus -t 90 call luci.netbird do_up '{"management_url":"","setup_key":"","caller":"watchdog"}' 2>&1)"
	rc=$?
	if [ "$rc" -ne 0 ]; then
		first_line="$(printf '%s\n' "$out" | sed -n '1p')"
		_log "do_up failed rc=$rc: $first_line"
	fi
}

# exit node 开机恢复:LuCI 选择持久化在 netbird.settings.exit_node,而 daemon 自己的
# 选择态(state.json)在 tmpfs、重启必丢(GitHub #10)。连接态下每 boot 恢复一次:
# 标志文件在 /var/run(tmpfs),重启自动清零。restore_exit_node 幂等;终态
# (restored/already-selected/not-configured/not-found)落标志不再重试,
# not-connected/error/超时留待下轮。同 boot 内用户经 CLI 的手动调整不会被反复覆盖。
EXITNODE_FLAG="/var/run/netbird-luci-exitnode.restored"

_maybe_restore_exit_node() {
	[ -f "$EXITNODE_FLAG" ] && return 0
	en="$(uci -q get netbird.settings.exit_node 2>/dev/null)"
	if [ -z "$en" ]; then
		touch "$EXITNODE_FLAG" 2>/dev/null
		return 0
	fi
	out="$(ubus -t 30 call luci.netbird restore_exit_node 2>/dev/null)"
	case "$out" in
	*'"result": "restored"'*)
		touch "$EXITNODE_FLAG" 2>/dev/null
		_log "restored exit node \"$en\" after restart" ;;
	*'"result": "already-selected"'*|*'"result": "not-configured"'*)
		touch "$EXITNODE_FLAG" 2>/dev/null ;;
	*'"result": "not-found"'*)
		touch "$EXITNODE_FLAG" 2>/dev/null
		_log "configured exit node \"$en\" is not available on this network; leaving it unselected" ;;
	*)
		: ;;
	esac
}

last_unknown=""   # 已记录过的"未识别状态"签名,同形态只记一次日志

while :; do
	bin="$(_resolve_bin 2>/dev/null)"
	if [ -z "$bin" ]; then
		_sleep "$INTERVAL"
		continue
	fi

	# 状态采样:JSON 优先。NeedsLogin/LoginFailed/SessionExpired 三态下 status 的
	# **文本**输出会早退成一段 SSO 提示文案(不含 "Management:" 行),文本正则全部
	# 落空;--json 不受早退影响。老版本 netbird 在部分状态下 --json 也返回纯文本,
	# 此时 daemonStatus 解析为空 → 回退文本输出,走旧文本正则。
	raw="$(_with_timeout_status "$bin" --json)"
	ds="$(_json_daemon_status "$raw")"
	if [ -z "$ds" ]; then
		raw="$(_with_timeout_status "$bin")"
	fi

	# 守护进程重启(崩溃被 procd 拉起、手动 restart、换二进制)后日志级别回到 info;
	# 守护进程能响应时按设置补下发,PID 与级别都没变时不调用 netbird。
	if [ -n "$ds" ] || _match "$raw" 'Daemon status|Management:'; then
		nb_sync_log_level "$bin"
	fi

	want="$(_desired)"

	if [ "$(_json_mgmt_connected "$raw")" = "true" ] || _is_connected "$raw"; then
		[ "$want" = "1" ] || _set_desired 1
		_clear_error
		_reset_backoff
		attempt_wait=0
		last_unknown=""
		_maybe_restore_exit_node
		_maybe_apply_pending_settings
		_sleep "$INTERVAL"
		continue
	fi
	pending_rounds=0

	# 服务在设置里被关闭(netbird-settings 已 down+stop+disable)时不重连;不改写期望连接位,
	# 重新启用服务后自动恢复。
	if [ "$want" != "1" ] || [ "$(uci -q get netbird.settings.service_enabled)" = "0" ]; then
		_reset_backoff
		attempt_wait=0
		_sleep "$INTERVAL"
		continue
	fi

	if _is_auth_fatal "$raw"; then
		_set_desired 0
		_set_error "Authentication failed: the management server rejected this peer."
		"$bin" down >/dev/null 2>&1 || true
		_log "authentication fatal; stopped automatic reconnect"
		_sleep "$INTERVAL"
		continue
	fi

	if [ "$ds" = "NeedsLogin" ] || _is_needs_login "$raw"; then
		_set_desired 0
		_set_error "Authentication failed: NetBird did not receive a valid setup key."
		_log "needs login; stopped automatic reconnect"
		_sleep "$INTERVAL"
		continue
	fi

	# desired=1 且未连接、又不属于上面的停止类:一律按退避重试(默认重试)。
	# LoginFailed / SessionExpired / Idle / Connecting 与未知形态都在此列——
	# 一次失败的重连尝试可能把 daemon 推进 LoginFailed(文本早退态),若只对
	# "已知瞬时错误"重试,这类形态会静默空转、永不自愈。未识别形态记一条日志
	# (同形态只记一次)供后续归类,绝不静默 no-op。
	case "$ds" in
		LoginFailed|SessionExpired|Idle|Connecting|Connected) : ;;
		*)
			if [ -n "$ds" ] || { [ -n "$raw" ] && ! _is_transient_disconnect "$raw"; }; then
				sig="${ds:-$(printf '%s\n' "$raw" | sed -n 1p)}"
				if [ "$sig" != "$last_unknown" ]; then
					_log "unrecognized status (retrying anyway): $sig"
					last_unknown="$sig"
				fi
			fi
			;;
	esac
	# 退避只作用于"重连尝试"频率,不拖慢轮询:仅当 attempt_wait 归零才发起一次 do_up,
	# 随后按当前 backoff 设定下次尝试等待并增长 backoff;期间每 INTERVAL 仍轮询状态,
	# 故 outage 恢复(daemon 自愈)后能在一个 INTERVAL 内检测到并清错复位。
	if [ "$attempt_wait" -le 0 ]; then
		_attempt_reconnect
		attempt_wait="$backoff"
		_bump_backoff
	fi

	[ "$attempt_wait" -gt 0 ] && attempt_wait=$(( attempt_wait - INTERVAL ))
	_sleep "$INTERVAL"
done
