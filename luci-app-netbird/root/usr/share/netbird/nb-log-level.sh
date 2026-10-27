# SPDX-License-Identifier: Apache-2.0
#
# nb_sync_log_level <netbird 路径> —— 把 netbird.settings.log_level 下发到运行中的守护进程。
# 供 netbird-settings 与自动重连 watchdog 以 `.` 引入共用(调用方须先引入 nb-run-bounded.sh、定义 TAG)。
#
# 守护进程由 netbird 软件包的 /etc/init.d/netbird 以 `netbird service run` 启动,不带 --log-level,
# 级别固定是 info;`netbird up --log-level` 只影响 up 这个 CLI 进程自己的控制台输出。
# netbird 0.27.4 起 `netbird debug log level <级别>` 经 RPC 修改守护进程当前级别,对之后的
# up/down 一直有效,但守护进程重启后回到 info。故记录「已下发到哪个守护进程(PID)、哪个级别」,
# 两者都没变时不再调用(每次调用守护进程都会记一条 INFO 日志);任一变化才重新下发。
# 0.27.4 之前没有这条命令:记一次日志后不再尝试。

NB_LOG_LEVEL_APPLIED="/var/run/netbird-loglevel.applied"

# 守护进程 PID 取自 procd 的服务表;取不到时为空(仍可下发,只是无法察觉重启)。
_nb_daemon_pid() {
	ubus call service list '{"name":"netbird"}' 2>/dev/null |
		jsonfilter -e '@.netbird.instances.*.pid' 2>/dev/null | sed -n 1p
}

# 状态文件在 tmpfs;写不进去(目录缺失等)只会导致下一轮再下发一次,不报错。
_nb_log_level_mark() {
	printf '%s\n' "$1" > "$NB_LOG_LEVEL_APPLIED"
} 2>/dev/null

nb_sync_log_level() {
	local bin="$1" level pid key out rc
	level="$(uci -q get netbird.settings.log_level 2>/dev/null)"
	case "$level" in
		error|warn|info|debug|trace) ;;
		*) level=info ;;
	esac
	pid="$(_nb_daemon_pid)"
	key="${pid:-unknown} $level"
	[ "$key" = "$(cat "$NB_LOG_LEVEL_APPLIED" 2>/dev/null)" ] && return 0

	# 能力探测:有这条命令时其帮助的用法行是 `netbird debug log level <level> [flags]`;
	# 老版本没有 debug 子命令,输出的是 unknown command 或根命令帮助,不含该用法。
	if ! nb_run_bounded 10 "$bin" debug log level --help 2>&1 | grep -q 'debug log level <level>'; then
		_nb_log_level_mark "$key"
		logger -t "$TAG" "this netbird version cannot change the daemon log level; it stays at info"
		return 0
	fi

	out="$(nb_run_bounded 10 "$bin" debug log level "$level" 2>&1)"
	rc=$?
	if [ "$rc" -eq 0 ]; then
		_nb_log_level_mark "$key"
		logger -t "$TAG" "daemon log level set to $level"
		return 0
	fi
	logger -t "$TAG" "failed to set daemon log level to $level (exit $rc): $(printf '%s\n' "$out" | sed -n 1p)"
	return 1
}
