// SPDX-License-Identifier: Apache-2.0
'use strict';
'require view';
'require rpc';
'require poll';
'require dom';
'require ui';
'require view.netbird.dom-helpers as nb';

// 状态 Tab —— 完整仪表盘（连接信息块 + Peers 表 + L.Poll 轮询）。
// 数据层：get_status(5 态闸) + get_connection_info(running 顶层概览) + list_peers(peer details 数组)。
// 软件版本 / 二进制来源管理已移到「版本管理」标签页（versions.js）。
// 渲染全程经 dom-helpers.pair() / E()，禁 innerHTML（XSS 安全基线）。

var callGetStatus   = rpc.declare({ object: 'luci.netbird', method: 'get_status' });
var callConnInfo    = rpc.declare({ object: 'luci.netbird', method: 'get_connection_info' });
var callListPeers   = rpc.declare({ object: 'luci.netbird', method: 'list_peers' });
var callInstallIfaceBackend = rpc.declare({
	object: 'luci.netbird', method: 'install_iface_backend', expect: {}
});
// 软件版本 / 二进制来源管理已移到「版本管理」标签页(versions.js)。

var STATE_LABEL = {
	running:          _('Running'),
	needs_login:      _('Needs login'),
	service_stopped:  _('Service stopped'),
	service_disabled: _('Service disabled'),
	not_installed:    _('NetBird not installed'),
	unknown:          _('Unknown')
};

// --- 格式化辅助（纯函数，无副作用）---

// formatBytes(n) — 人类可读流量（二进制单位）。
function formatBytes(n) {
	var b = Number(n);
	if (!isFinite(b) || b < 0) return '-';
	if (b < 1024) return b + ' B';
	var units = ['KiB', 'MiB', 'GiB', 'TiB'];
	var v = b, i = -1;
	do { v /= 1024; i++; } while (v >= 1024 && i < units.length - 1);
	return v.toFixed(v >= 100 ? 0 : 1) + ' ' + units[i];
}

// formatLatency(ns) — netbird status --json 的 latency 是纳秒整数；转 ms。
function formatLatency(ns) {
	var v = Number(ns);
	if (!isFinite(v) || v <= 0) return '-';
	var ms = v / 1e6;
	return (ms >= 100 ? ms.toFixed(0) : ms.toFixed(1)) + ' ms';
}

// relativeTime(iso) — 相对时间（参考 OPNsense getElapsedTime 的简洁版）。
function relativeTime(iso) {
	if (!iso) return '-';
	var then = Date.parse(iso);
	if (isNaN(then)) return String(iso);
	// netbird 对「从未握手」的 peer 回 Go 零时间(0001-01-01T00:00:00Z)→解析为负值；
	// 当作 Never 处理，避免渲染「739782 d ago」这类荒谬相对时间。
	if (then <= 0) return _('Never');
	var sec = Math.floor((Date.now() - then) / 1000);
	if (sec < 0) sec = 0;
	if (sec < 60)    return _('%d s ago').format(sec);
	var min = Math.floor(sec / 60);
	if (min < 60)    return _('%d min ago').format(min);
	var hr = Math.floor(min / 60);
	if (hr < 24)     return _('%d h ago').format(hr);
	var day = Math.floor(hr / 24);
	return _('%d d ago').format(day);
}

// yesNo(bool) — 布尔的 Yes/No 文案。
function yesNo(v) {
	return v ? _('Yes') : _('No');
}

// --- 渲染块（每个都返回 DOM 节点，不写 innerHTML）---

function renderConnInfo(res) {
	// res 非 ok（理论上 running 态不会发生，防御性处理）→ 简短提示。
	if (!res || !res.ok || !res.data) {
		var code = (res && res.code) ? res.code : 'unknown';
		return E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, _('Connection')),
			E('p', {}, _('No connection details (%s).').format(STATE_LABEL[code] || code))
		]);
	}
	var d = res.data;
	var mgmt   = d.management || {};
	var signal = d.signal || {};
	var relays = d.relays || {};
	var peers  = d.peers || {};
	var nets   = Array.isArray(d.networks) ? d.networks : [];

	var rows = [
		nb.pair(_('Daemon version'), d.daemonVersion),
		nb.pair(_('CLI version'),    d.cliVersion),
		nb.pair(_('Management server'),     (mgmt.connected ? _('Connected') : _('Disconnected')) + (mgmt.url ? (' — ' + mgmt.url) : '')),
		nb.pair(_('Signal server'),         (signal.connected ? _('Connected') : _('Disconnected')) + (signal.url ? (' — ' + signal.url) : '')),
		nb.pair(_('Relays'),         _('%d / %d available').format(relays.available || 0, relays.total || 0)),
		nb.pair(_('FQDN'),           d.fqdn),
		nb.pair(_('NetBird IP'),     d.netbirdIp || '-')
	];
	if (d.netbirdIpv6)
		rows.push(nb.pair(_('NetBird IPv6'), d.netbirdIpv6));
	rows.push(
		nb.pair(_('Interface type'),     d.usesKernelInterface ? _('Kernel') : _('Userspace')),
		nb.pair(_('Quantum resistance'), yesNo(d.quantumResistance)),
		nb.pair(_('Lazy connection'),    yesNo(d.lazyConnectionEnabled)),
		nb.pair(_('Networks'),           nets.length ? nets.join(', ') : '-'),
		nb.pair(_('Forwarding rules'),   d.forwardingRules || 0),
		nb.pair(_('Profile'),            d.profileName || '-'),
		nb.pair(_('Peers'),              _('%d / %d connected').format(peers.connected || 0, peers.total || 0))
	);

	return E('div', { 'class': 'cbi-section' }, [
		E('h3', {}, _('Connection')),
		E('div', { 'class': 'nb-conn-info' }, rows),
		E('div', { 'class': 'cbi-section-descr' }, _('Daemon version is the running daemon; CLI version is the binary on disk. They match unless the binary was switched without restarting the daemon.'))
	]);
}

function renderPeers(res) {
	if (!res || !res.ok || !res.data) {
		return E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, _('Peers')),
			E('p', {}, _('Peer details unavailable.'))
		]);
	}
	var peers = Array.isArray(res.data.peers) ? res.data.peers : [];
	if (!peers.length) {
		return E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, _('Peers')),
			E('p', {}, _('No peers.'))
		]);
	}

	var head = E('tr', { 'class': 'tr table-titles' }, [
		E('th', { 'class': 'th' }, _('Name')),
		E('th', { 'class': 'th' }, _('Status')),
		E('th', { 'class': 'th' }, _('IP')),
		E('th', { 'class': 'th' }, _('Connection mode')),
		E('th', { 'class': 'th' }, _('Latency')),
		E('th', { 'class': 'th' }, _('Last handshake')),
		E('th', { 'class': 'th' }, _('Received')),
		E('th', { 'class': 'th' }, _('Sent'))
	]);

	var rows = peers.map(function (p) {
		p = p || {};
		return E('tr', { 'class': 'tr' }, [
			E('td', { 'class': 'td' }, p.fqdn || '-'),
			E('td', { 'class': 'td' }, p.status ? _(p.status) : '-'),
			E('td', { 'class': 'td' }, p.netbirdIp || '-'),
			E('td', { 'class': 'td' }, p.connectionType || '-'),
			E('td', { 'class': 'td' }, formatLatency(p.latency)),
			E('td', { 'class': 'td' }, relativeTime(p.lastWireguardHandshake)),
			E('td', { 'class': 'td' }, formatBytes(p.transferReceived)),
			E('td', { 'class': 'td' }, formatBytes(p.transferSent))
		]);
	});

	return E('div', { 'class': 'cbi-section' }, [
		E('h3', {}, _('Peers')),
		E('table', { 'class': 'table' }, [head].concat(rows))
	]);
}

// 版本块(handleUpdate/renderVersions)已移到「版本管理」标签页(versions.js)。

function renderEmpty(state) {
	return E('div', { 'class': 'cbi-section' }, [
		nb.pair(_('Backend state'), STATE_LABEL[state] || state),
		E('p', { 'class': 'cbi-section-descr' },
			_('Status details are available only when the NetBird service is running. See the Authentication tab to enable, start, or log in.'))
	]);
}

// iface_backend.ready === false：高置信缺少内核 WireGuard 与 TUN。
// 旧后端无该字段时跳过，保持向前/向后兼容。onInstall 有则显示一键安装按钮。
function renderIfaceBackendWarning(ifaceBackend, onInstall) {
	if (!ifaceBackend || ifaceBackend.ready !== false)
		return null;
	var kids = [
		E('p', {}, [
			E('strong', {}, _('WireGuard / TUN backend missing')),
			E('br'),
			_('NetBird needs either the WireGuard kernel module or a TUN device to create its interface. Neither is available on this device.')
		])
	];
	if (onInstall) {
		kids.push(E('p', {}, [
			E('button', {
				'class': 'btn cbi-button cbi-button-action',
				'click': onInstall
			}, _('Install WireGuard / TUN packages')),
			' ',
			E('span', { 'class': 'cbi-value-description' },
				_('Installs the kernel packages required for NetBird interfaces. This may take a minute.'))
		]));
	}
	kids.push(E('p', { 'class': 'cbi-value-description' },
		_('Or install manually (for example: %s install kmod-wireguard), then reboot or start the service again.').format('opkg')));
	return E('div', { 'class': 'alert-message warning' }, kids);
}

// L.Poll 节奏：running+connected 5s；running 但未连 30s；非 running 不轮询。
function pollInterval(state, connected) {
	if (state !== 'running') return 0;
	return connected ? 5 : 30;
}

return view.extend({
	load: function () {
		return L.resolveDefault(callGetStatus(), { ok: false });
	},

	// LuCI rpc.js 只读 L.env.rpctimeout；装包可能超过默认 20s。
	_withRpcTimeout: function (seconds, fn) {
		var had = Object.prototype.hasOwnProperty.call(L.env, 'rpctimeout');
		var old = L.env.rpctimeout;
		L.env.rpctimeout = Math.max(Number(old) || 20, seconds);
		return fn().then(function (res) {
			if (had) L.env.rpctimeout = old;
			else delete L.env.rpctimeout;
			return res;
		}, function (err) {
			if (had) L.env.rpctimeout = old;
			else delete L.env.rpctimeout;
			throw err;
		});
	},

	handleInstallIfaceBackend: function (ev) {
		var self = this;
		var btn = ev.currentTarget;
		btn.classList.add('spinning');
		btn.disabled = true;
		ui.showModal(_('Installing WireGuard / TUN packages'), [
			E('p', { 'class': 'spinning' },
				_('Updating package lists and installing kernel modules…'))
		]);
		return L.resolveDefault(self._withRpcTimeout(180, function () {
			return callInstallIfaceBackend();
		}), { ok: false }).then(function (res) {
			ui.hideModal();
			if (res && res.ok && res.data && res.data.iface_backend &&
				res.data.iface_backend.ready === true) {
				ui.addNotification(null, E('p', {},
					_('WireGuard / TUN packages installed. Reloading…')), 'info');
				window.setTimeout(function () { location.reload(); }, 800);
				return;
			}
			var msg = (res && res.message) ? _(res.message) : _('Failed to install WireGuard / TUN packages.');
			var body = [ E('p', {}, msg) ];
			if (res && res.hint)
				body.push(E('p', { 'class': 'cbi-value-description' }, _('Hint:') + ' ' + _(res.hint)));
			if (res && res.message)
				body.push(E('pre', {
					'style': 'white-space:pre-wrap;word-break:break-word;max-height:16em;overflow:auto'
				}, String(res.message)));
			body.push(E('div', { 'class': 'right' }, [
				E('button', { 'class': 'btn', 'click': ui.hideModal }, _('Close'))
			]));
			ui.showModal(_('Install failed'), body);
			btn.classList.remove('spinning');
			btn.disabled = false;
		}, function (e) {
			ui.hideModal();
			var em = nb.friendlyRpcError(e);
			ui.addNotification(null, E('p', {}, em), 'error');
			btn.classList.remove('spinning');
			btn.disabled = false;
		});
	},

	render: function (statusRes) {
		var state = (statusRes && statusRes.ok && statusRes.data && statusRes.data.status) || 'unknown';
		var ifaceBackend = (statusRes && statusRes.ok && statusRes.data && statusRes.data.iface_backend) || null;
		var container = E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, _('NetBird') + ' — ' + _('Status'))
		]);

		var backendWarn = renderIfaceBackendWarning(ifaceBackend,
			ui.createHandlerFn(this, 'handleInstallIfaceBackend'));
		if (backendWarn)
			container.appendChild(backendWarn);

		// 非 running：空态引导（软件版本已移到「版本管理」标签页 versions.js），不轮询连接信息。
		if (state !== 'running') {
			container.appendChild(renderEmpty(state));
			return container;
		}

		// running：可变块容器，refresh() 用 dom.content 原地替换连接信息 + peers。
		var connBox  = E('div', {});
		var peersBox = E('div', {});
		container.appendChild(connBox);
		container.appendChild(peersBox);

		function refresh() {
			return Promise.all([
				L.resolveDefault(callConnInfo(), { ok: false }),
				L.resolveDefault(callListPeers(), { ok: false })
			]).then(function (r) {
				dom.content(connBox, renderConnInfo(r[0]));
				dom.content(peersBox, renderPeers(r[1]));
				return r[0];
			});
		}

		// 首次渲染连接信息 + peers，再按连接态决定轮询间隔挂 poll（只轮询连接/peers）。
		return refresh().then(function (connInfo) {
			var connected = !!(connInfo && connInfo.ok && connInfo.data &&
				connInfo.data.management && connInfo.data.management.connected);
			var sec = pollInterval(state, connected);
			if (sec > 0)
				poll.add(refresh, sec);
			return container;
		});
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
