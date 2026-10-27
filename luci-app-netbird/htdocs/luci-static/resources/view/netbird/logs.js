// SPDX-License-Identifier: Apache-2.0
'use strict';
'require view';
'require rpc';
'require dom';
'require view.netbird.dom-helpers as nb';

// 日志 Tab —— 改动 1：默认读 netbird 守护进程日志（对齐 OPNsense，显示真实 peer 活动）。
// 数据源：get_logs → { lines:[], source:'daemon'|'syslog', truncated, note }。
//
// source='daemon'（/var/log/netbird/client.log）行格式：
//   2026-06-16T11:44:57.501+08:00 INFO [peer: <pubkey>] client/internal/peer/wg_watcher.go:109: <消息>
//   即 <RFC3339时间> <LEVEL> [peer: <key>]?(可选) <源文件:行>: <消息>
//   列：时间 / 级别 / Peer（短前缀 8 字符，无则 '-'）/ 消息（含 源文件:行: 文本）
//
// source='syslog'（回退，logread -e netbird）行格式：
//   Mon Apr 20 12:04:44 2026 daemon.err process[pid]: message
//   列：时间 / 级别 / 进程 / 消息（沿用既有 busybox 解析）
//
// 功能：全文搜索、级别下拉过滤、客户端分页（默认50/页）、手动刷新、着色。

var callGetLogs = rpc.declare({
	object: 'luci.netbird',
	method: 'get_logs',
	params: ['limit'],
	expect: {}
});

// 每次拉取行数上限
var FETCH_LIMIT = 500;

// ── BusyBox logread（syslog 回退）行格式正则 ────────────────────────────────────
// "Mon Apr 20 12:04:44 2026 daemon.err process[pid]: message"
// 或 "Mon Apr 20 12:04:44 2026 daemon.err process: message"
var LOG_RE = /^(\w{3}\s+\w{3}\s+\d{1,2}\s+\d{2}:\d{2}:\d{2}\s+\d{4})\s+(\S+)\.(\S+)\s+(\S+?)(?:\[\d+\])?:\s*(.*)$/;

// ── netbird 守护日志行格式正则 ──────────────────────────────────────────────────
// 时间（RFC3339，无空格）+ 级别 + 可选 [peer: <key>] + 消息（含 源文件:行: 文本）。
// 级别容忍 netbird 常见写法（INFO/WARN/WARNING/ERROR/ERRO/DEBUG/DEBG/DEBU/TRACE/FATAL/PANIC）。
var DAEMON_RE = /^(\S+)\s+([A-Z]{3,7})\s+(?:\[peer:\s*([^\]]+)\]\s+)?(.*)$/;

// severity 规范化映射：各来源用词 → netbird 规范级别（忠实，不塌缩）。
// netbird daemon 日志的级别字段是 4 字符大写缩写：0.37.2 起为自定义写法（PANC/FATL/ERRO/WARN/
// INFO/DEBG/TRAC），更早是 logrus 截断（PANI/FATA/ERRO/WARN/INFO/DEBU/TRAC），两套都收。
// 这里统一还原为官方级别名。官方用户级别 5 个（trace/debug/info/warn/error）；
// fatal/panic 为 logrus 内部级别，日志里极少出现，若出现仍忠实显示并归入 error 阈值（见 SEV_RANK），
// 但不作为筛选下拉项（见 sevSelect）。
var SEV_MAP = {
	// netbird daemon 级别（4 字符缩写 + 全称）
	'trac':    'TRACE',   'trace':   'TRACE',
	'debg':    'DEBUG',   'debu':    'DEBUG',   'debug':   'DEBUG',
	'info':    'INFO',
	'warn':    'WARN',    'warning': 'WARN',
	'erro':    'ERROR',   'error':   'ERROR',
	'fatl':    'FATAL',   'fata':    'FATAL',   'fatal':   'FATAL',
	'panc':    'PANIC',   'pani':    'PANIC',   'panic':   'PANIC',
	// syslog facility.severity（回退源 logread）→ 最接近的级别
	'err':     'ERROR',
	'crit':    'FATAL',
	'emerg':   'PANIC',   'alert':   'PANIC',
	'notice':  'INFO'
};

// severity → CSS class（用于着色；fatal/panic 复用 error 色,trace 复用 debug 色）
var SEV_CLASS = {
	'PANIC':  'nb-sev-error',
	'FATAL':  'nb-sev-error',
	'ERROR':  'nb-sev-error',
	'WARN':   'nb-sev-warn',
	'INFO':   'nb-sev-info',
	'DEBUG':  'nb-sev-debug',
	'TRACE':  'nb-sev-debug'
};

// 严重性序（数字越大越严重）：用于"最低严重性"阈值过滤。
// 选中某级别 → 显示该级别及更严重的行（对齐 netbird 官方阈值语义「debug 也含 info」）。
var SEV_RANK = { 'TRACE': 0, 'DEBUG': 1, 'INFO': 2, 'WARN': 3, 'ERROR': 4, 'FATAL': 5, 'PANIC': 6 };

// 时间范围快捷窗口（毫秒）：下拉选中后，下界 = 当前时刻 - 窗口（相对 now 的滑动窗）。
// 空 key = 不按时间过滤。档位对齐 OPNsense 日志页「时间范围」常用值。
var TIME_WINDOWS = { '15m': 15 * 60 * 1000, '1h': 60 * 60 * 1000, '24h': 24 * 60 * 60 * 1000 };

// 当前数据源（'daemon'|'syslog'），决定第 3 列表头（Peer vs 进程）与解析器。
var _source = 'daemon';

// parseDaemonLine(raw) → { time, severity, sevClass, peer, message } | null
// netbird 守护日志解析；peer 列取 key 短前缀（前 8 字符），无 peer 则 '-'。
function parseDaemonLine(raw) {
	var m = raw.match(DAEMON_RE);
	if (!m) return null;
	var sevRaw = m[2].toLowerCase();
	var sevLabel = SEV_MAP[sevRaw] || m[2].toUpperCase();
	var peerKey = m[3] ? m[3].trim() : '';
	var peerShort = peerKey ? peerKey.slice(0, 8) : '-';
	return {
		time:     m[1],
		severity: sevLabel,
		sevClass: SEV_CLASS[sevLabel] || '',
		peer:     peerShort,
		peerFull: peerKey,
		message:  m[4]
	};
}

// parseSyslogLine(raw) → { time, severity, sevClass, process, message } | null
// BusyBox logread 回退解析。
function parseSyslogLine(raw) {
	var m = raw.match(LOG_RE);
	if (!m) return null;
	var sevRaw = m[3].toLowerCase();
	var sevLabel = SEV_MAP[sevRaw] || '-';
	return {
		time:     m[1],
		facility: m[2],
		severity: sevLabel,
		sevClass: SEV_CLASS[sevLabel] || '',
		process:  m[4],
		message:  m[5]
	};
}

// _parseEpoch(timeStr) → epoch ms | NaN —— 解析行时间为毫秒，供时间范围过滤用。
// - daemon 源是 RFC3339 带时区（2026-06-16T11:44:57.501+08:00），Date.parse 原生识别偏移；
// - syslog 源是 BusyBox 文本时间（Mon Apr 20 12:04:44 2026），Date.parse 按浏览器本地时区尽力解析；
// - 未解析行 time='-'、或 Go 零时间（0001-01-01 → Date.parse ≤ 0）→ NaN。
//   时间过滤激活时 NaN 行一律排除出窗口，避免污染（仅「所有时间」档显示，见 _filtered）。
function _parseEpoch(timeStr) {
	if (!timeStr || timeStr === '-') return NaN;
	var ms = Date.parse(timeStr);
	if (isNaN(ms) || ms <= 0) return NaN;
	return ms;
}

// ── 组件状态（模块级，随 render 生命周期复用）──────────────────────────────────
var _allParsed  = [];  // 解析后的全量行（最近一次 fetch 结果）
var _pageSize   = 50;  // 当前分页大小
var _curPage    = 0;   // 当前页（0-based）
var _filterText = '';  // 搜索关键词（小写）
var _filterSev  = '';  // 严重性过滤（'ERROR'/'WARN'/…；空=全部）
var _filterRange   = '';    // 时间范围 key（''=全部 / '15m' / '1h' / '24h'）
var _filterSinceMs = null;  // 时间下界（epoch ms；null=不按时间过滤）

// ── DOM 引用（render 时设置）────────────────────────────────────────────────────
var _tableContainer = null;  // <div> 容器，dom.content 替换其内的完整 <table>
var _pagerEl        = null;  // 分页控件容器
var _statusEl       = null;  // 状态/提示行
var _truncEl        = null;  // truncated 提示

// _recomputeSinceMs() —— 依当前时间范围 key 重算下界（相对「现在」）。
// 在「时间下拉变更」与「每次拉取/刷新」时调用：使「近 N」相对加载时刻冻结、
// 不随搜索按键滑动（稳定）；手动刷新时随新 now 更新窗口。
function _recomputeSinceMs() {
	var win = TIME_WINDOWS[_filterRange];
	_filterSinceMs = win ? (Date.now() - win) : null;
}

// _filtered() → 经时间范围+搜索+严重性过滤后的行数组
// 搜索串覆盖第 3 列（daemon=peer 全 key / syslog=process）+ 时间/级别/消息。
function _filtered() {
	return _allParsed.filter(function (r) {
		// 时间范围过滤：选中快捷档后，仅显示下界之后的行；无法解析时间（NaN，含 '-'
		// 与 Go 零时间）的行在时间过滤激活时排除，避免污染窗口。
		if (_filterSinceMs != null) {
			if (isNaN(r.epoch) || r.epoch < _filterSinceMs) return false;
		}
		// 严重性过滤：阈值语义——显示「所选级别及更严重」的行（对齐 netbird 官方
		// 「debug 也含 info」;修掉旧精确匹配下 daemon=info 时选 DEBUG 显示 0 条的问题）。
		if (_filterSev) {
			var selRank = SEV_RANK[_filterSev];
			var rowRank = SEV_RANK[r.severity];
			if (selRank != null && (rowRank == null || rowRank < selRank)) return false;
		}
		if (_filterText) {
			var col3 = (r.peerFull != null) ? r.peerFull : (r.process != null ? r.process : '');
			var haystack = (r.time + ' ' + r.severity + ' ' + col3 + ' ' + r.message).toLowerCase();
			if (haystack.indexOf(_filterText) < 0) return false;
		}
		return true;
	});
}

// _buildTable(rows) → 完整 <table> 元素（thead + tbody 合并，避免 childNodes 问题）
// 第 3 列随数据源变化：daemon=Peer（短前缀，title 显示全 key）/ syslog=进程。
function _buildTable(rows) {
	var col3Title = (_source === 'syslog') ? _('Process') : _('Peer');
	var thead = E('thead', {}, [
		E('tr', { 'class': 'tr table-titles' }, [
			E('th', { 'class': 'th', 'style': 'white-space:nowrap;min-width:160px' }, _('Time')),
			E('th', { 'class': 'th', 'style': 'min-width:60px'  }, _('Severity')),
			E('th', { 'class': 'th', 'style': 'min-width:90px'  }, col3Title),
			E('th', { 'class': 'th' }, _('Message'))
		])
	]);

	var bodyRows;
	if (!rows.length) {
		bodyRows = [
			E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td', 'colspan': '4', 'style': 'text-align:center;color:#888' },
					_('No log entries match the current filter.'))
			])
		];
	} else {
		bodyRows = rows.map(function (r) {
			// 第 3 列值：daemon 用 peer 短前缀（title=全 key 便于复制核对）；syslog 用进程。
			var col3Val = (r.peer != null) ? r.peer : (r.process != null ? r.process : '-');
			var col3Cell = E('td', {
				'class': 'td nb-log-proc',
				'title': (r.peerFull && r.peerFull.length) ? r.peerFull : null
			}, col3Val);
			return E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td nb-log-time'                 }, r.time),
				E('td', { 'class': 'td nb-log-sev ' + r.sevClass    }, r.severity),
				col3Cell,
				E('td', { 'class': 'td nb-log-msg'                  }, r.message)
			]);
		});
	}
	return E('table', { 'class': 'table', 'style': 'table-layout:auto;width:100%' },
		[thead, E('tbody', {}, bodyRows)]);
}

// _renderPager(total, pageSize, curPage, onChange) → <div> 分页控件
function _renderPager(total, pageSize, curPage, onChange) {
	var pages = Math.ceil(total / pageSize) || 1;
	if (pages <= 1) return E('div', {});

	var items = [];
	// 「上一页」
	var prevBtn = E('button', {
		'class': 'cbi-button',
		'disabled': curPage === 0 ? 'disabled' : null,
		'click': function () { if (curPage > 0) onChange(curPage - 1); }
	}, '‹');
	items.push(prevBtn);

	// 页码（最多显示 7 个窗口）
	var start = Math.max(0, curPage - 3);
	var end   = Math.min(pages - 1, start + 6);
	if (end - start < 6) start = Math.max(0, end - 6);
	for (var i = start; i <= end; i++) {
		(function (pg) {
			var btn = E('button', {
				'class': 'cbi-button' + (pg === curPage ? ' cbi-button-action' : ''),
				'click': function () { onChange(pg); }
			}, String(pg + 1));
			items.push(btn);
		})(i);
	}

	// 「下一页」
	var nextBtn = E('button', {
		'class': 'cbi-button',
		'disabled': curPage >= pages - 1 ? 'disabled' : null,
		'click': function () { if (curPage < pages - 1) onChange(curPage + 1); }
	}, '›');
	items.push(nextBtn);

	// 每页条数选择
	var sizeSelect = E('select', {
		'class': 'cbi-input-select',
		'style': 'margin-left:12px',
		'change': function (ev) {
			_pageSize = parseInt(ev.target.value, 10);
			_curPage = 0;
			_repaint();
		}
	}, [50, 100, 200].map(function (n) {
		return E('option', { 'value': String(n), 'selected': n === pageSize ? 'selected' : null }, String(n) + ' / ' + _('page'));
	}));

	return E('div', { 'class': 'nb-pager', 'style': 'margin-top:8px;display:flex;align-items:center;gap:4px;flex-wrap:wrap' },
		items.concat([sizeSelect]));
}

// _repaint() — 根据当前 _allParsed / 过滤 / 分页 状态刷新表格 + 分页器
function _repaint() {
	if (!_tableContainer || !_pagerEl || !_statusEl) return;

	var filtered = _filtered();
	var total    = filtered.length;
	var pages    = Math.ceil(total / _pageSize) || 1;
	if (_curPage >= pages) _curPage = pages - 1;

	var start    = _curPage * _pageSize;
	var pageRows = filtered.slice(start, start + _pageSize);

	// 用 dom.content 把整个 table 换掉（不用 childNodes，避免 NodeList 序列化 bug）
	dom.content(_tableContainer, _buildTable(pageRows));
	dom.content(_pagerEl, _renderPager(total, _pageSize, _curPage, function (pg) {
		_curPage = pg;
		_repaint();
	}));

	var statusText = _('%d entries').format(total);
	if (total !== _allParsed.length)
		statusText += ' ' + _('(%d total)').format(_allParsed.length);
	dom.content(_statusEl, statusText);
}

// _loadAndRender() → Promise — 拉取 get_logs，解析，更新模块状态，重绘
function _loadAndRender() {
	// L.resolveDefault：RPC/传输层拒绝时降级为 {ok:false}(走下方非 ok 分支),
	// 避免未捕获 rejection + 日志页永久卡在「Loading…」(对齐 status/overview 写法)。
	return L.resolveDefault(callGetLogs(FETCH_LIMIT), { ok: false }).then(function (res) {
		// 时间窗下界相对「本次拉取时刻」冻结（手动刷新随新 now 更新）。
		_recomputeSinceMs();
		// 提示清空
		if (_truncEl) dom.content(_truncEl, []);

		if (!res || !res.ok) {
			// RPC/传输/权限等非 ok 态：服务停/未登录等「服务态」由后端 get_logs 走 ok:true 兜底，
			// 故走到这里主要是传输/权限/RPC 失败 → 文案用通用「Logs unavailable」比「Service not
			// running」更准。
			var note  = (res && res.data && res.data.note)  ? res.data.note  : '';
			var state = (res && res.data && res.data.state) ? res.data.state : '';
			var msg   = note || state || (res && res.code)  || 'unavailable';
			_allParsed = [];
			_source = (res && res.data && res.data.source) ? res.data.source : 'daemon';
			// 提示写进 _truncEl（_repaint 不覆盖它）；_statusEl 仅作计数会被 _repaint 盖掉。
			if (_truncEl) dom.content(_truncEl, E('p', { 'class': 'alert-message warning' },
				_('Logs unavailable: %s').format(msg)));
			_repaint();
			return;
		}

		var data     = res.data || {};
		var rawLines = Array.isArray(data.lines) ? data.lines : [];

		// 数据源决定解析器与第 3 列（daemon=client.log peer / syslog=logread 进程）。
		_source = (data.source === 'syslog') ? 'syslog' : 'daemon';
		var parseLine = (_source === 'syslog') ? parseSyslogLine : parseDaemonLine;

		// 解析：能解析的解析，解析不了的保留原始行（第 3 列 '-', severity '-'）。
		_allParsed = rawLines.map(function (ln) {
			var parsed = parseLine(ln);
			if (!parsed)
				parsed = (_source === 'syslog')
					? { time: '-', facility: '', severity: '-', sevClass: '', process: '-', message: ln }
					: { time: '-', severity: '-', sevClass: '', peer: '-', peerFull: '', message: ln };
			parsed.epoch = _parseEpoch(parsed.time);
			return parsed;
		});

		// truncated 提示
		if (data.truncated && _truncEl) {
			dom.content(_truncEl, E('p', { 'class': 'alert-message warning' },
				_('Log output truncated to last %d lines.').format(FETCH_LIMIT)));
		}

		// 文件/缓冲区里没有 netbird 相关日志
		if (data.note === 'no_logs_in_ring') {
			_allParsed = [];
			var emptyMsg = (_source === 'syslog')
				? _('No NetBird log entries in syslog ring buffer.')
				: _('No NetBird daemon log entries yet.');
			// 同上：空日志态提示也写 _truncEl（_repaint 不覆盖）；benign 故用中性 alert-message。
			if (_truncEl) dom.content(_truncEl, E('p', { 'class': 'alert-message' }, emptyMsg));
		}

		// 服务未运行：后端兜底返回 ok:true + state + note（见 get_logs），前端在此明确提示
		// 而非只显示空表。提示写进 _truncEl（_repaint 不覆盖它；_statusEl 仅作
		// 计数、会被 _repaint 盖掉）。data.state 仅在非 running 的兜底 envelope 里出现。
		if (data.state && data.state !== 'running' && _truncEl) {
			_allParsed = [];
			dom.content(_truncEl, E('p', { 'class': 'alert-message warning' },
				_('NetBird service is not running; no logs are available.')));
		}

		_curPage = 0;
		_repaint();
	});
}

return view.extend({
	load: function () {
		// 初始化模块状态（每次页面加载重置，避免切 Tab 后状态串）
		_allParsed  = [];
		_pageSize   = 50;
		_curPage    = 0;
		_filterText = '';
		_filterSev  = '';
		_filterRange   = '';
		_filterSinceMs = null;
		_source     = 'daemon';
		return Promise.resolve();
	},

	render: function () {
		// ── 控件区 ──────────────────────────────────────────────────────────────
		var searchInput = E('input', {
			'type': 'text',
			'class': 'cbi-input-text',
			'placeholder': _('Search logs…'),
			'style': 'width:280px',
			'input': function (ev) {
				_filterText = ev.target.value.toLowerCase();
				_curPage = 0;
				_repaint();
			}
		});

		var sevSelect = E('select', {
			'class': 'cbi-input-select',
			'change': function (ev) {
				_filterSev = ev.target.value;
				_curPage = 0;
				_repaint();
			}
		}, [
			E('option', { 'value': '' }, _('All severities')),
			E('option', { 'value': 'ERROR' }, 'ERROR'),
			E('option', { 'value': 'WARN'  }, 'WARN'),
			E('option', { 'value': 'INFO'  }, 'INFO'),
			E('option', { 'value': 'DEBUG' }, 'DEBUG'),
			E('option', { 'value': 'TRACE' }, 'TRACE')
		]);

		// 时间范围快捷过滤（纯客户端，仅作用于已取的最近 FETCH_LIMIT 行）。
		var timeSelect = E('select', {
			'class': 'cbi-input-select',
			'change': function (ev) {
				_filterRange = ev.target.value;
				_recomputeSinceMs();
				_curPage = 0;
				_repaint();
			}
		}, [
			E('option', { 'value': ''    }, _('All times')),
			E('option', { 'value': '15m' }, _('Last 15 minutes')),
			E('option', { 'value': '1h'  }, _('Last hour')),
			E('option', { 'value': '24h' }, _('Last 24 hours'))
		]);

		var refreshBtn = E('button', {
			'class': 'cbi-button cbi-button-action',
			'click': function () { _loadAndRender(); }
		}, _('Refresh'));

		var toolbar = E('div', {
			'class': 'nb-log-toolbar',
			'style': 'display:flex;align-items:center;gap:8px;flex-wrap:wrap;margin-bottom:8px'
		}, [searchInput, sevSelect, timeSelect, refreshBtn]);

		// ── 状态行 ──────────────────────────────────────────────────────────────
		_statusEl = E('span', { 'style': 'color:#888;font-size:0.9em' }, _('Loading…'));

		// ── Truncated 提示容器 ────────────────────────────────────────────────────
		_truncEl = E('div', {});

		// ── 表格容器（dom.content 替换整个 <table>）─────────────────────────────
		_tableContainer = E('div', {}, _buildTable([]));

		// ── 分页器容器 ───────────────────────────────────────────────────────────
		_pagerEl = E('div', {});

		// ── 页面容器 ──────────────────────────────────────────────────────────────
		var container = E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, _('NetBird') + ' — ' + _('Logs')),
			E('div', { 'class': 'cbi-section' }, [
				toolbar,
				// 阈值过滤 + 调级别引导(常见困惑:三个低级别看着一样=daemon 跑 info 级、文件
				// 里没有 DEBUG/TRACE 行;选 INFO 见 WARN/选 WARN 见 ERROR=阈值语义)。纯文本不含 %s 防译文 hash 漂移。
				E('p', { 'class': 'cbi-section-descr', 'style': 'margin:4px 0 8px;color:#888' },
					_('The severity filter is a minimum threshold: choosing a level also shows all more severe levels. To capture DEBUG or TRACE lines, raise the log level on the Settings page.')),
				E('div', { 'style': 'margin-bottom:4px' }, [_statusEl]),
				_truncEl,
				_tableContainer,
				_pagerEl
			])
		]);

		// 首次加载
		_loadAndRender();

		return container;
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
