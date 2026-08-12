// SPDX-License-Identifier: Apache-2.0
'use strict';
'require view';
'require rpc';
'require ui';
'require view.netbird.dom-helpers as nb';

// 认证 Tab —— 顶部状态横幅（statusPill + 文案）+ 5 态空态引导；
// 在此基础上加认证表单：管理 URL + Setup Key + 连接 / 断开 / 注销。
//
// 状态判定：get_status 给 5 态字面量；connected 与否结合 get_connection_info 的
// management.connected（running 态才调）。
//
// 安全：Setup Key 仅作 do_up/do_login 的瞬时 RPC 参数流过，提交后不在前端留存
// （读完输入框值即提交，随后清空 .value）；管理 URL 非机密，可预填/持久化。

var callGetStatus   = rpc.declare({ object: 'luci.netbird', method: 'get_status' });
var callConnInfo    = rpc.declare({ object: 'luci.netbird', method: 'get_connection_info' });
var callAuthInfo    = rpc.declare({ object: 'luci.netbird', method: 'get_auth_info' });
var callEnableStart = rpc.declare({ object: 'luci.netbird', method: 'do_enable_and_start' });
var callDoUp        = rpc.declare({ object: 'luci.netbird', method: 'do_up',
	params: [ 'management_url', 'setup_key' ] });
var callDoDown      = rpc.declare({ object: 'luci.netbird', method: 'do_down' });
var callDoLogout    = rpc.declare({ object: 'luci.netbird', method: 'do_logout',
	params: [ 'local_only' ] });
var callBinaryInfo  = rpc.declare({ object: 'luci.netbird', method: 'get_binary_info',
	params: [ 'check_remote' ], expect: {} });
var callInstallIfaceBackend = rpc.declare({
	object: 'luci.netbird', method: 'install_iface_backend', expect: {}
});

function pkgMgrName(pkgMgr) {
	return (pkgMgr === 'apk') ? 'apk' : 'opkg';
}

// iface_backend.ready === false：后端高置信「内核 WG 与 TUN 都不可用」。
// 旧后端无此字段时不渲染（兼容旧 rpcd）。onInstall 有则显示一键安装按钮。
function renderIfaceBackendWarning(ifaceBackend, pkgMgr, onInstall) {
	if (!ifaceBackend || ifaceBackend.ready !== false)
		return null;
	var mgr = pkgMgrName(pkgMgr);
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
		_('Or install manually (for example: %s install kmod-wireguard), then reboot or start the service again.').format(mgr)));
	return E('div', { 'class': 'alert-message warning' }, kids);
}

// 横幅视图模型：state 字面量 → { pill, label, hint }。
// pill 取 dom-helpers.statusPill 白名单（connected/disconnected/error/
// not_installed/service_disabled/unknown）；非白名单态降级 'unknown' 灰胶囊。
function bannerModel(state, connected) {
	switch (state) {
	case 'running':
		return connected
			? { pill: 'connected',    label: _('Connected'),
			    hint: _('NetBird is connected to the management server.') }
			: { pill: 'disconnected', label: _('Disconnected'),
			    hint: _('The current session is disconnected, but your login identity is kept. Click Connect below to reconnect; no setup key is needed.') };
	case 'needs_login':
		return { pill: 'error', label: _('Login required'),
		         hint: _('Not connected to the server. Enter the management URL and key below to connect.') };
	case 'service_stopped':
		return { pill: 'disconnected', label: _('Service stopped'),
		         hint: _('The NetBird service is installed and enabled but not running.') };
	case 'service_disabled':
		return { pill: 'service_disabled', label: _('Service disabled'),
		         hint: _('The NetBird service is installed but disabled. Enable and start it to continue.') };
	case 'not_installed':
		return { pill: 'not_installed', label: _('Not installed'),
		         hint: _('The NetBird binary was not found. Install the netbird package, then return here.') };
	default:
		return { pill: 'unknown', label: _('Unknown'),
		         hint: _('Could not determine the NetBird service state.') };
	}
}

// runAction(btn, promise, okMsg, failMsg) — 统一动作按钮流转：转圈+禁用 →
//   then(ok：通知 okMsg + 800ms 刷新 / 否则：通知 _(res.message)||failMsg + 复位)
//   → catch：通知异常 + 复位。集中原 4 个 handler 的重复样板。
function responseMessage(res, fallback) {
	var msg = (res && res.message) ? _(res.message) : fallback;
	if (res && res.hint)
		return [ msg, E('br'), E('span', { 'class': 'cbi-value-description' }, _('Hint:') + ' ' + _(res.hint)) ];
	return msg;
}

function exceptionMessage(e) {
	// 超时类(客户端 rpctimeout / uhttpd 60s 掐断)统一友好化,其余透传。
	return nb.friendlyRpcError(e);
}

function runAction(btn, promise, okMsg, failMsg) {
	btn.classList.add('spinning');
	btn.disabled = true;
	return promise.then(function (res) {
		if (res && res.ok) {
			ui.addNotification(null, E('p', {}, okMsg), 'info');
			window.setTimeout(function () { location.reload(); }, 800);
		} else {
			ui.addNotification(null, E('p', {}, responseMessage(res, failMsg)), 'error');
			btn.classList.remove('spinning');
			btn.disabled = false;
		}
	}).catch(function (e) {
		ui.addNotification(null, E('p', {}, exceptionMessage(e)), 'error');
		btn.classList.remove('spinning');
		btn.disabled = false;
	});
}

return view.extend({
	load: function () {
		return Promise.all([
			L.resolveDefault(callGetStatus(), { ok: false }),
			// 改动 2：get_auth_info 同时给展示用管理 URL（UCI→config.json 回退）与打码 hint。
			L.resolveDefault(callAuthInfo(), { ok: false }),
			L.resolveDefault(callBinaryInfo(false), { ok: false })
		]).then(function (res) {
			var statusRes = res[0];
			var authRes = res[1];
			var binRes = res[2];
			var state = (statusRes && statusRes.ok && statusRes.data && statusRes.data.status) || 'unknown';
			var ifaceBackend = (statusRes && statusRes.ok && statusRes.data && statusRes.data.iface_backend) || null;
			var authData = (authRes && authRes.ok && authRes.data) ? authRes.data : {};
			var binData = (binRes && binRes.ok && binRes.data) ? binRes.data : {};
			var mgmtUrl = authData.management_url || '';
			var keyHint = authData.setup_key_hint || '';
			var lastAuthError = authData.last_error || '';
			var pkgMgr = binData.pkg_mgr || '';
			// 仅 running 态拉 connection info 判 management.connected。
			if (state === 'running')
				return L.resolveDefault(callConnInfo(), { ok: false }).then(function (ci) {
					return { state: state, connInfo: ci, mgmtUrl: mgmtUrl, keyHint: keyHint, lastAuthError: lastAuthError, pkgMgr: pkgMgr, ifaceBackend: ifaceBackend };
				});
			return { state: state, connInfo: null, mgmtUrl: mgmtUrl, keyHint: keyHint, lastAuthError: lastAuthError, pkgMgr: pkgMgr, ifaceBackend: ifaceBackend };
		});
	},

		// LuCI rpc.js 只读取全局 L.env.rpctimeout,没有 per-call timeout。认证命令会
		// 等后端归因与收敛,临时覆盖到 90s,避免前端先报 XHR timeout。
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

	// 「启用并启动」按钮回调：调 do_enable_and_start，成功刷新页面。
	handleEnableStart: function (ev) {
		return runAction(ev.currentTarget, callEnableStart(),
			_('NetBird service enabled and started.'), _('Operation failed.'));
	},

	// 一键安装 WireGuard/TUN kmod：仅告警可见时渲染；后端再闸 ready。
	// 包管理可能较慢（update+install），临时抬高 rpctimeout；失败弹窗展示真实 message/hint。
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
			var body = [
				E('p', {}, responseMessage(res,
					_('Failed to install WireGuard / TUN packages.')))
			];
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
			ui.addNotification(null, E('p', {}, exceptionMessage(e)), 'error');
			btn.classList.remove('spinning');
			btn.disabled = false;
		});
	},

	// 「连接」回调：读输入框值 → do_up({management_url, setup_key})。
	// 安全：读取后立即清空 Setup Key 输入框 .value（前端不留存密钥）。
	handleConnect: function (ev) {
		var btn = ev.currentTarget;
		var urlEl = document.getElementById('nb-mgmt-url');
		var keyEl = document.getElementById('nb-setup-key');
		var mgmtUrl = urlEl ? String(urlEl.value || '').trim() : '';
		var setupKey = keyEl ? String(keyEl.value || '') : '';

		// 提交即清空 Setup Key 输入框（前端不留存瞬时密钥）
		if (keyEl) keyEl.value = '';

		// 传入 RPC 后立即弃局部密钥引用（不带进 runAction 闭包）
		var self = this;
			var p = self._withRpcTimeout(90, function () {
				return callDoUp(mgmtUrl, setupKey);
			});
		setupKey = '';
		return runAction(btn, p, _('Connected to NetBird.'), _('Connection failed.'));
	},

	// 「断开」回调：do_down（保留认证，仅断当前会话）。
	handleDisconnect: function (ev) {
		return runAction(ev.currentTarget, callDoDown(),
			_('NetBird disconnected.'), _('Operation failed.'));
	},

	// 「重新连接」回调：do_down → do_up（空参=持久身份重连，无需密钥）。仅已连接态出现。
	// do_up 内置 _flush_reconnect_conntrack（等路由恢复后定向冲在途 conntrack），故重连后转发流自愈。
	// 用途：一键重连;或在 daemon 自发重连未覆盖的边角(WAN 抖动等)手动触发让转发流恢复。
	handleReconnect: function (ev) {
		var self = this;
		// 空参 do_up → 持久身份重连(do_up 解析已存管理 URL)
		return runAction(ev.currentTarget,
				self._withRpcTimeout(90, function () {
					return callDoDown().then(function () { return callDoUp('', ''); });
				}),
			_('NetBird reconnected.'), _('Operation failed.'));
	},

	// 「注销/登出」回调：二次确认（警告会删本机身份）后 do_logout。
	handleLogout: function () {
		var self = this;
		ui.showModal(_('Deregister this NetBird device?'), [
			E('p', {}, _('This will deregister this device and remove the local NetBird identity. You will need a setup key to log in again. This is different from "Disconnect", which keeps your credentials.')),
			E('div', { 'class': 'right' }, [
				E('button', {
					'class': 'btn',
					'click': ui.hideModal
				}, _('Cancel')),
				' ',
				E('button', {
					'class': 'btn cbi-button cbi-button-negative',
					'click': ui.createHandlerFn(self, 'doLogoutConfirmed')
				}, _('Deregister'))
			])
		]);
	},

	doLogoutConfirmed: function (ev) {
		var self = this;
		var btn = ev.currentTarget;
		btn.classList.add('spinning');
		btn.disabled = true;
		return callDoLogout('').then(function (res) {
			ui.hideModal();
			if (res && res.ok) {
				ui.addNotification(null, E('p', {}, _('Logged out. The local NetBird identity was removed.')), 'info');
				window.setTimeout(function () { location.reload(); }, 800);
			} else {
				var msg = (res && res.message) ? _(res.message) : _('Operation failed.');
				self.showLocalWipeModal(responseMessage(res, msg));
			}
		}).catch(function (e) {
			ui.hideModal();
			ui.addNotification(null, E('p', {}, exceptionMessage(e)), 'error');
		});
	},

	// 注销失败兜底：deregister 依赖管理服务器配合;服务器重建/不可达/已删本机时永远失败,
	// 旧身份会卡死在设备上。此弹窗提供「仅清除本地身份」出路(do_logout local_only='1')。
	showLocalWipeModal: function (errText) {
		var self = this;
		ui.showModal(_('Deregister failed'), [
			E('p', {}, errText),
			E('p', {}, _('The management server could not deregister this device — it may be unreachable, rebuilt, or it no longer knows this peer. You can remove the local identity only and then log in again with a new setup key. If the device is still listed on the server, remove it there manually.')),
			E('div', { 'class': 'right' }, [
				E('button', { 'class': 'btn', 'click': ui.hideModal }, _('Cancel')),
				' ',
				E('button', {
					'class': 'btn cbi-button cbi-button-negative',
					'click': ui.createHandlerFn(self, 'doLocalWipeConfirmed')
				}, _('Remove local identity only'))
			])
		]);
	},

	doLocalWipeConfirmed: function (ev) {
		var btn = ev.currentTarget;
		btn.classList.add('spinning');
		btn.disabled = true;
		return callDoLogout('1').then(function (res) {
			ui.hideModal();
			if (res && res.ok) {
				ui.addNotification(null, E('p', {}, _('Local NetBird identity removed. Use a setup key to log in again.')), 'info');
				window.setTimeout(function () { location.reload(); }, 800);
			} else {
				var msg = (res && res.message) ? _(res.message) : _('Operation failed.');
				ui.addNotification(null, E('p', {}, responseMessage(res, msg)), 'error');
			}
		}).catch(function (e) {
			ui.hideModal();
			ui.addNotification(null, E('p', {}, exceptionMessage(e)), 'error');
		});
	},

	// 认证表单：管理 URL（预填实际 URL，可编辑）+ Setup Key（password，始终留空）+ 连接按钮。
	// 改动 2：
	//   - 管理 URL value 预填 get_auth_info 给的实际 URL（断开态也显示已保存的实际 URL）。
	//   - Setup Key 输入框保持空（供输入新 key，避免误提交打码串）；若有 setup_key_hint，
	//     在输入框下方 helptext 显示「上次使用：<hint>」。
	//   - logged-in 态（running / needs_login，即已有身份）文案提示「留空即用现有身份」。
	// 在 not_installed 态不渲染（无可操作对象）。
	renderAuthForm: function (state, mgmtUrl, keyHint, lastAuthError) {
		if (state === 'not_installed')
			return E('div', {});

		// 已有本地身份（service 在跑或仅需登录）→ 提示留空即复用现有身份。
		var loggedInHint = (state === 'running' || state === 'needs_login');
		var keyPlaceholder = loggedInHint
			? _('Logged in, leave blank to keep the current identity')
			: _('Leave blank if already logged in');

		// Setup Key 输入框下方说明：基础说明 + 可选「上次使用：<hint>」。
		var keyDescChildren = [
			_('Key from the NetBird console — one-time use, not shown again.')
		];
		if (keyHint) {
			keyDescChildren.push(E('br'));
			// hint 作为 E() children 传入，浏览器当 Text node 处理（防 XSS）。
			keyDescChildren.push(E('span', { 'class': 'nb-key-hint' },
				_('Last used:') + ' ' + keyHint));
		}

		var rows = [ E('h3', {}, _('Authentication')) ];
		if (lastAuthError)
			rows.push(E('div', { 'class': 'alert-message warning' }, [
				E('strong', {}, _('Last authentication error:')), ' ', _(lastAuthError)
			]));
		rows.push(
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title', 'for': 'nb-mgmt-url' }, _('Management URL')),
				E('div', { 'class': 'cbi-value-field' }, [
					E('input', {
						'id': 'nb-mgmt-url',
						'type': 'text',
						'class': 'cbi-input-text',
						'value': mgmtUrl || '',
						'placeholder': 'https://api.netbird.io:443'
					}),
					E('div', { 'class': 'cbi-value-description' },
						_('Management server URL — self-hosted or the official one.'))
				])
			])
		);
		rows.push(
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title', 'for': 'nb-setup-key' }, _('Setup Key')),
				E('div', { 'class': 'cbi-value-field' }, [
					E('input', {
						'id': 'nb-setup-key',
						'type': 'password',
						'class': 'cbi-input-password',
						'autocomplete': 'off',
						'placeholder': keyPlaceholder
					}),
					E('div', { 'class': 'cbi-value-description' }, keyDescChildren)
				])
			])
		);
		rows.push(
			E('div', { 'class': 'cbi-value' }, [
				E('div', { 'class': 'cbi-value-field' }, [
					E('button', {
						'class': 'btn cbi-button cbi-button-action',
						'click': ui.createHandlerFn(this, 'handleConnect')
					}, _('Connect'))
				])
			])
		);
		return E('div', { 'class': 'cbi-section' }, rows);
	},

	// 已连接操作区：断开 + 注销。
	renderConnectedControls: function () {
		return E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, _('Connection control')),
			E('div', { 'class': 'cbi-value' }, [
				E('div', { 'class': 'cbi-value-field' }, [
					E('button', {
						'class': 'btn cbi-button cbi-button-action',
						'click': ui.createHandlerFn(this, 'handleReconnect')
					}, _('Reconnect')),
					' ',
					E('button', {
						'class': 'btn cbi-button cbi-button-action',
						'click': ui.createHandlerFn(this, 'handleDisconnect')
					}, _('Disconnect')),
					' ',
					E('button', {
						'class': 'btn cbi-button cbi-button-negative',
						'click': ui.createHandlerFn(this, 'handleLogout')
					}, _('Deregister'))
				])
			]),
			E('p', { 'class': 'cbi-value-description' },
				_('Reconnect re-establishes the NetBird session while keeping your identity (down then up).')),
			E('p', { 'class': 'cbi-value-description' },
				_('Disconnect keeps your credentials; Log out removes the local NetBird identity (requires a setup key to reconnect).'))
		]);
	},

	// 5 态引导操作区：按 state 给对应 CTA（认证表单/已连接控制独立渲染）。
	renderGuidance: function (state, pkgMgr) {
		switch (state) {
		case 'service_disabled':
		case 'service_stopped':
			return E('div', { 'class': 'cbi-section' }, [
				E('p', {}, _('Enable the NetBird service and start it now.')),
				E('button', {
					'class': 'btn cbi-button cbi-button-action',
					'click': ui.createHandlerFn(this, 'handleEnableStart')
				}, _('Enable and start'))
			]);
		case 'not_installed':
			return E('div', { 'class': 'cbi-section' }, [
				E('p', {}, _('Install the netbird package (e.g. via %s), then reload this page.').format(pkgMgrName(pkgMgr)))
			]);
		default:
			return E('div', {});
		}
	},

	render: function (data) {
		var state = data.state || 'unknown';
		var mgmtUrl = data.mgmtUrl || '';
		var keyHint = data.keyHint || '';
		var lastAuthError = data.lastAuthError || '';
		var pkgMgr = data.pkgMgr || '';
		var ifaceBackend = data.ifaceBackend || null;
		var connected = !!(data.connInfo && data.connInfo.ok && data.connInfo.data &&
			data.connInfo.data.management && data.connInfo.data.management.connected);
		var m = bannerModel(state, connected);

		var children = [
			E('h2', {}, _('NetBird') + ' — ' + _('Authentication')),
			E('div', { 'class': 'cbi-section' }, [
				E('div', { 'class': 'nb-banner' }, [
					nb.statusPill(m.pill, m.label),
					E('span', { 'class': 'nb-banner-hint' }, ' ' + m.hint)
				])
			])
		];
		var backendWarn = renderIfaceBackendWarning(ifaceBackend, pkgMgr,
			ui.createHandlerFn(this, 'handleInstallIfaceBackend'));
		if (backendWarn)
			children.push(backendWarn);
		children.push(this.renderGuidance(state, pkgMgr));

		// connected 时显示断开/注销控制；否则（且非 not_installed）显示认证表单。
		if (connected)
			children.push(this.renderConnectedControls());
		else
			children.push(this.renderAuthForm(state, mgmtUrl, keyHint, lastAuthError));

		return E('div', { 'class': 'cbi-map' }, children);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
