// SPDX-License-Identifier: Apache-2.0
'use strict';
'require view';
'require rpc';
'require ui';
'require dom';
'require view.netbird.dom-helpers as nb';

// Network Tab —— OpenWRT 防火墙自动化（本项目相对 OPNsense 的核心价值）。
//
// （根治远程锁死的设计）：zone 直接 `list device 'wt0'` 绑定 netbird 自管设备，
// **不创建 OpenWRT network 接口** → 只 reload firewall、绝不 reload network → wt0 数据面
// 永不被 flush（旧设计建 proto=none 接口 + reload network 会瞬断 mesh、远程管理锁死）。
//
// 两块互相独立的能力（「接水管」vs「开阀门」物理分离）：
//   1) 一键配置：setup_firewall_zone —— 创建绑定 netbird 设备的 firewall zone（「水管」）。
//      非破坏性，不开任何 LAN↔mesh 互通。
//   2) Forwarding：两个独立 checkbox（默认全不勾）→ setup_forwarding。**开启互通会把 LAN
//      暴露给 mesh peer**，附红字告警，用户显式确认。
//
// 顶部用 get_automation_status 展示当前装配；每个动作前文案级预览会改哪些 UCI；
// 操作后重新拉 get_automation_status 刷新。渲染全程 E() / dom-helpers（XSS 安全基线）。

var callStatus      = rpc.declare({ object: 'luci.netbird', method: 'get_automation_status' });
var callSetupZone   = rpc.declare({ object: 'luci.netbird', method: 'setup_firewall_zone' });
var callSetupFwd    = rpc.declare({
	object: 'luci.netbird',
	method: 'setup_forwarding',
	params: ['lan_to_netbird', 'netbird_to_lan']
});
var callTeardown    = rpc.declare({ object: 'luci.netbird', method: 'teardown_automation' });
var callListExit    = rpc.declare({ object: 'luci.netbird', method: 'list_exit_nodes' });
var callSelectExit  = rpc.declare({
	object: 'luci.netbird',
	method: 'select_exit_node',
	params: ['id']
});

// yesPill(bool) — 装配态胶囊：已装配=绿(connected)，未装配=红(disconnected)。
// 复用 dom-helpers.statusPill 白名单内的颜色键，不引入新 CSS。
function yesPill(on) {
	return on ? nb.statusPill('connected', _('Configured'))
	          : nb.statusPill('disconnected', _('Not configured'));
}

// onOffPill(bool) — forwarding 开关态胶囊：开=橙(needs_login 复用橙底)，关=灰(unknown)。
function onOffPill(on) {
	return on ? nb.statusPill('needs_login', _('On'))
	          : nb.statusPill('unknown', _('Off'));
}

return view.extend({
	load: function () {
		return Promise.all([
			L.resolveDefault(callStatus(), { ok: false }),
			L.resolveDefault(callListExit(), { ok: false })
		]);
	},

	render: function (loaded) {
		var self = this;
		var statusRes = loaded[0];
		var exitRes = loaded[1];

		var container = E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, _('NetBird') + ' — ' + _('Network')),
			E('div', { 'class': 'cbi-map-descr' },
				_('Configure the OpenWrt firewall zone and forwarding rules for NetBird, and select the exit node.'))
		]);

		// 顶部装配态块（refresh 用 dom.content 原地替换）。
		var statusBox = E('div', {});
		container.appendChild(statusBox);

		// ── Exit node 块（日常操作控件,放防火墙一次性装配之前）──────────────────
		// 即时生效:选择状态由 netbird daemon 持久化,不进 UCI,与本页其他按钮同为
		// 直接动作模型。refresh 用 dom.content 原地替换。
		this._exitBox = E('div', {});
		container.appendChild(this._exitBox);
		this.renderExitNodes(exitRes);

		// ── 一键配置块 ────────────────────────────────────────────────────────
		container.appendChild(E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, _('One-click setup')),
			E('p', { 'class': 'cbi-section-descr' },
				_('Creates a dedicated firewall zone bound to the NetBird device so NetBird traffic can flow.')),
			E('ul', {}, [
				E('li', {}, [
					nb.code('/etc/config/firewall'), ': ',
					_('add/update zone %s bound to the NetBird device (input/output/forward=ACCEPT, masq, mtu_fix).').format('netbird')
				])
			]),
			E('div', { 'class': 'cbi-value' }, [
				E('div', { 'class': 'cbi-value-field' }, [
					E('button', {
						'class': 'btn cbi-button cbi-button-action important',
						'click': ui.createHandlerFn(self, 'handleSetup')
					}, _('Create firewall zone'))
				])
			])
		]));

		// ── Forwarding 块（默认全不勾 + 红字告警）─────────────────────────────
		// checkbox 引用保存在 self 上，应用时读其 .checked。
		this._cbL2N = E('input', { 'type': 'checkbox', 'id': 'nb-fwd-l2n' });
		this._cbN2L = E('input', { 'type': 'checkbox', 'id': 'nb-fwd-n2l' });

		container.appendChild(E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, _('LAN ↔ NetBird forwarding')),
			E('div', { 'class': 'alert-message warning' }, [
				E('strong', {}, _('Caution:')), ' ',
				_('Enabling forwarding exposes your LAN to NetBird mesh peers (and vice-versa).')
			]),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title', 'for': 'nb-fwd-l2n' }, _('LAN → NetBird')),
				E('div', { 'class': 'cbi-value-field' }, [
					this._cbL2N, ' ',
					E('span', { 'class': 'cbi-value-description' },
						_('Allow hosts on your LAN to reach NetBird peers (src=lan, dest=netbird).'))
				])
			]),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title', 'for': 'nb-fwd-n2l' }, _('NetBird → LAN')),
				E('div', { 'class': 'cbi-value-field' }, [
					this._cbN2L, ' ',
					E('span', { 'class': 'cbi-value-description' },
						_('Allow NetBird peers to reach your LAN (src=netbird, dest=lan). Higher exposure, enable with care. No effect if Block Inbound is enabled on the Settings Firewall tab.'))
				])
			]),
			E('div', { 'class': 'cbi-value' }, [
				E('div', { 'class': 'cbi-value-field' }, [
					E('button', {
						'class': 'btn cbi-button cbi-button-action',
						'click': ui.createHandlerFn(self, 'handleForwarding')
					}, _('Apply forwarding'))
				])
			])
		]));

		// ── 移除块（破坏性，二次确认；清理的唯一入口，覆盖断开残留/卸载前清理/撤销）──
		// 删 OpenWRT 对 netbird 的封装（zone + 两条 forwarding），不动 lan/wan、
		// 不杀 netbird daemon 的 wtX 设备。按钮在无任何装配时禁用（renderStatus 同步）。
		this._removeBtn = E('button', {
			'class': 'btn cbi-button cbi-button-negative',
			'click': ui.createHandlerFn(self, 'handleTeardown')
		}, _('Remove firewall zone'));

		container.appendChild(E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, _('Remove automation')),
			E('p', { 'class': 'cbi-section-descr' },
				_('Removes the NetBird firewall zone and both forwarding rules from OpenWrt. It does not stop the NetBird daemon or remove its wtX device; only the OpenWrt firewall plumbing is removed. Use this before uninstalling, or to undo the setup.')),
			E('div', { 'class': 'cbi-value' }, [
				E('div', { 'class': 'cbi-value-field' }, [ this._removeBtn ])
			])
		]));

		// 首次渲染装配态（含同步 checkbox 到当前实际状态）。
		this.renderStatus(statusBox, statusRes);

		return container;
	},

	// renderExitNodes(res) — 渲染 Exit node 块（dom.content 原地替换 _exitBox）。
	// res 为 list_exit_nodes 信封,四态:非 running(err)→提示先启动;running 未连接
	// →提示先连接;无 exit node→提示去管理控制台配置;有→当前态 + 下拉 + 应用按钮。
	renderExitNodes: function (res) {
		var self = this;
		var nodes = (res && res.ok && res.data && res.data.exit_nodes) ? res.data.exit_nodes : [];
		var connected = !!(res && res.ok && res.data && res.data.connected);
		var body;

		// 当前生效节点 = 第一个 selected 条目(正常互斥下至多一个;遗留多选态取第一个展示)。
		var current = null;
		for (var i = 0; i < nodes.length; i++) {
			if (nodes[i].selected) { current = nodes[i]; break; }
		}

		if (!res || !res.ok) {
			// 按错误类别给指引:非 running 系(含 needs_login)指向认证页;
			// 运行时错误(cli_error 等)显示后端 message,避免误导成"未运行"。
			var offline = { not_installed: 1, service_disabled: 1, service_stopped: 1, needs_login: 1 };
			body = E('p', { 'class': 'cbi-section-descr' },
				(res && res.code && !offline[res.code] && res.message)
					? _('Could not read exit nodes:') + ' ' + res.message
					: _('NetBird is not running. Start it and connect from the Authentication page first.'));
		} else if (!connected) {
			body = E('p', { 'class': 'cbi-section-descr' },
				_('NetBird is not connected. Connect from the Authentication page first.'));
		} else if (!nodes.length) {
			body = E('p', { 'class': 'cbi-section-descr' },
				_('No exit nodes are available. Set up a peer as an exit node in the NetBird management console first.'));
		} else {
			this._exitSelect = E('select', { 'class': 'cbi-input-select' },
				[ E('option', { 'value': '' }, _('Off (direct internet access)')) ].concat(
					nodes.map(function (n) {
						var opt = E('option', { 'value': n.id }, n.id + (n.range ? ' (' + n.range + ')' : ''));
						if (current && n.id === current.id)
							opt.selected = true;
						return opt;
					})));

			body = E('div', {}, [
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, _('Active exit node')),
					E('div', { 'class': 'cbi-value-field' }, [
						current ? nb.statusPill('connected', current.id)
						        : nb.statusPill('unknown', _('Off'))
					])
				]),
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, _('Switch to')),
					E('div', { 'class': 'cbi-value-field' }, [
						this._exitSelect, ' ',
						E('button', {
							'class': 'btn cbi-button cbi-button-action',
							'click': ui.createHandlerFn(self, 'handleExitApply')
						}, _('Apply exit node'))
					])
				])
			]);
		}

		this._exitCurrent = current ? current.id : '';

		dom.content(this._exitBox, E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, _('Exit node')),
			E('p', { 'class': 'cbi-section-descr' },
				_('Route all internet traffic from this router and its clients through a NetBird peer. Exit nodes are defined in the NetBird management console. Changes take effect immediately; the selection made here is saved and re-applied automatically after the router reboots.')),
			body
		]));
	},

	// refreshExitNodes() — 重新拉 list_exit_nodes 并刷新 Exit node 块（操作后调用）。
	refreshExitNodes: function () {
		var self = this;
		return L.resolveDefault(callListExit(), { ok: false }).then(function (res) {
			self.renderExitNodes(res);
		});
	},

	// handleExitApply — 「应用」入口:改默认路由是重后果操作,弹确认 modal 后才执行。
	// 不做「已是当前节点」拦截:旧版 netbird(<0.73)缺 exit node 对账,无显式选择时
	// list 可能把未生效节点报成 Selected;重复 select 幂等且会写入显式选择态,
	// 恰好把这种假 Selected 修正为真生效——拦截反而堵死唯一的自愈路径。
	handleExitApply: function (ev) {
		var self = this;
		var id = this._exitSelect ? this._exitSelect.value : '';

		ui.showModal(_('Switch exit node?'), [
			id
				? E('p', {}, _('All internet traffic from this router and devices routed through it will go through "%s".').format(id))
				: E('p', {}, _('The exit node will be turned off; internet traffic will go out directly again.')),
			E('div', { 'class': 'alert-message warning' }, [
				E('strong', {}, _('Caution:')), ' ',
				_('Switching the exit node changes the default route. Connections may drop briefly, and remote management sessions that do not run over NetBird can be cut off.')
			]),
			E('div', { 'class': 'right' }, [
				E('button', { 'class': 'btn', 'click': ui.hideModal }, _('Cancel')),
				' ',
				E('button', {
					'class': 'btn cbi-button cbi-button-action important',
					'click': ui.createHandlerFn(self, 'doExitApply', id)
				}, _('Switch exit node'))
			])
		]);
	},

	// doExitApply — modal 确认后真正执行 select_exit_node,按后端回读态刷新块。
	doExitApply: function (id, ev) {
		var self = this;
		ui.hideModal();
		return callSelectExit(id).then(function (res) {
			if (res && res.ok) {
				ui.addNotification(null, E('p', {},
					id ? _('Exit node switched to "%s".').format(id)
					   : _('Exit node turned off.')), 'info');
			} else {
				var detail = (res && res.message) ? (' ' + res.message) : '';
				ui.addNotification(null, E('p', {}, _('Failed to switch the exit node.') + detail), 'error');
			}
		}).catch(function (e) {
			ui.addNotification(null, E('p', {}, String(e.message || e)), 'error');
		}).finally(function () {
			return self.refreshExitNodes();
		});
	},

	// renderStatus(box, res) — 把装配态写入 box，并把 forwarding checkbox 同步到实际状态。
	renderStatus: function (box, res) {
		var d = (res && res.ok && res.data) ? res.data : {};
		var zoneExists = !!d.zone_exists;
		var dev = d.zone_device || '';

		// 状态感知摘要——已建/未建,给明确提示。本设计只有 zone 一件配置(无 interface 二态)。
		// 文案纯 ASCII(无 em-dash/花引号/%s),防 i18n 译文 hash 漂移。
		var setupSummary = zoneExists
			? _('The NetBird firewall zone already exists.')
			: _('The NetBird firewall zone does not exist yet. Use the "Create firewall zone" button below.');

		var node = E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, _('Current configuration')),
			E('p', { 'class': 'cbi-section-descr', 'style': 'font-weight:600' }, setupSummary),
			E('div', { 'class': 'nb-conn-info' }, [
				E('div', { 'class': 'nb-pair' }, [
					E('span', { 'class': 'nb-pair-label' }, _('Firewall zone (bound device)')),
					E('span', { 'class': 'nb-pair-value' }, [
						yesPill(zoneExists),
						zoneExists && dev ? E('span', {}, ' — ' + dev) : E('span', {})
					])
				]),
				E('div', { 'class': 'nb-pair' }, [
					E('span', { 'class': 'nb-pair-label' }, _('Forwarding LAN → NetBird')),
					E('span', { 'class': 'nb-pair-value' }, [ onOffPill(!!d.lan_to_netbird) ])
				]),
				E('div', { 'class': 'nb-pair' }, [
					E('span', { 'class': 'nb-pair-label' }, _('Forwarding NetBird → LAN')),
					E('span', { 'class': 'nb-pair-value' }, [ onOffPill(!!d.netbird_to_lan) ])
				])
			])
		]);
		dom.content(box, node);

		// 同步 checkbox 到实际状态（让「应用 forwarding」反映当前真实配置，避免误关）。
		if (this._cbL2N) this._cbL2N.checked = !!d.lan_to_netbird;
		if (this._cbN2L) this._cbN2L.checked = !!d.netbird_to_lan;

		// 移除按钮：无任何装配（zone/任一 forwarding 都不存在）时禁用，避免对空配置二次确认。
		if (this._removeBtn) {
			var anything = zoneExists || !!d.lan_to_netbird || !!d.netbird_to_lan;
			this._removeBtn.disabled = !anything;
		}

		this._statusBox = box;
	},

	// refreshStatus() — 重新拉 get_automation_status 并刷新顶部块（操作后调用）。
	refreshStatus: function () {
		var self = this;
		return L.resolveDefault(callStatus(), { ok: false }).then(function (res) {
			if (self._statusBox)
				self.renderStatus(self._statusBox, res);
			return res;
		});
	},

	// warnReload — fw4 即时重载失败时提示（UCI 已写入，下次 firewall reload / 重启仍会生效）。
	warnReload: function (data) {
		if (data && data.reload_ok === false)
			ui.addNotification(null, E('p', {}, _('Settings were saved, but the firewall reload did not complete; they will take effect on the next firewall reload or reboot.')), 'warning');
	},

	// handleSetup — 一键建绑定 netbird 设备的 firewall zone（仅 setup_firewall_zone）。
	handleSetup: function (ev) {
		var self = this;
		var btn = ev.currentTarget;
		btn.classList.add('spinning');
		btn.disabled = true;

		return callSetupZone().then(function (zoneRes) {
			if (!zoneRes || !zoneRes.ok)
				return Promise.reject(new Error((zoneRes && zoneRes.message) ? _(zoneRes.message) : _('Failed to set up the firewall zone.')));
			ui.addNotification(null, E('p', {},
				_('The NetBird firewall zone is configured (device: %s).')
					.format((zoneRes.data && zoneRes.data.device) || '?')), 'info');
			self.warnReload(zoneRes.data);
		}).catch(function (e) {
			ui.addNotification(null, E('p', {}, String(e.message || e)), 'error');
		}).finally(function () {
			btn.classList.remove('spinning');
			btn.disabled = false;
			return self.refreshStatus();
		});
	},

	// handleForwarding — 应用两向 forwarding（按 checkbox 当前勾选态；false 即删除我们那条）。
	handleForwarding: function (ev) {
		var self = this;
		var btn = ev.currentTarget;
		var l2n = !!(this._cbL2N && this._cbL2N.checked);
		var n2l = !!(this._cbN2L && this._cbN2L.checked);

		btn.classList.add('spinning');
		btn.disabled = true;

		return callSetupFwd(l2n, n2l).then(function (res) {
			if (res && res.ok) {
				var extra = (res.data && res.data.auto_created_zone)
					? (' ' + _('The NetBird firewall zone was auto-created (prerequisite for forwarding).'))
					: '';
				ui.addNotification(null, E('p', {},
					_('Forwarding updated: LAN→NetBird %s, NetBird→LAN %s.')
						.format(l2n ? _('on') : _('off'), n2l ? _('on') : _('off')) + extra), 'info');
				self.warnReload(res.data);
			} else {
				ui.addNotification(null, E('p', {}, (res && res.message) ? _(res.message) : _('Failed to update forwarding.')), 'error');
			}
		}).catch(function (e) {
			ui.addNotification(null, E('p', {}, String(e.message || e)), 'error');
		}).finally(function () {
			btn.classList.remove('spinning');
			btn.disabled = false;
			return self.refreshStatus();
		});
	},

	// handleTeardown — 破坏性「移除」入口：弹二次确认 modal，列清将删的内容 + 安全说明。
	handleTeardown: function (ev) {
		var self = this;
		ui.showModal(_('Remove NetBird network automation?'), [
			E('p', {}, _('This will remove the following from OpenWrt:')),
			E('ul', {}, [
				E('li', {}, [ nb.code('firewall zone netbird'), ' ', _('the dedicated firewall zone') ]),
				E('li', {}, [ nb.code('lan_to_netbird / netbird_to_lan'), ' ', _('both forwarding rules') ])
			]),
			E('p', {}, _('Your LAN/WAN configuration is not touched. The NetBird daemon keeps running and its wtX device stays up.')),
			E('div', { 'class': 'right' }, [
				E('button', { 'class': 'btn', 'click': ui.hideModal }, _('Cancel')),
				' ',
				E('button', {
					'class': 'btn cbi-button cbi-button-negative important',
					'click': ui.createHandlerFn(self, 'doTeardown')
				}, _('Remove'))
			])
		]);
	},

	// doTeardown — modal 确认后真正执行 teardown_automation，刷新装配态。
	doTeardown: function (ev) {
		var self = this;
		ui.hideModal();
		return callTeardown().then(function (res) {
			if (res && res.ok) {
				ui.addNotification(null, E('p', {}, _('NetBird network automation removed. If you later change network settings and NetBird loses connectivity, reconnect once from the Authentication page to restore it.')), 'info');
				self.warnReload(res.data);
			} else {
				ui.addNotification(null, E('p', {}, (res && res.message) ? _(res.message) : _('Failed to remove automation.')), 'error');
			}
		}).catch(function (e) {
			ui.addNotification(null, E('p', {}, String(e.message || e)), 'error');
		}).finally(function () {
			return self.refreshStatus();
		});
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
