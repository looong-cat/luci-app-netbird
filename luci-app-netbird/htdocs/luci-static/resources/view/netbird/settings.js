// SPDX-License-Identifier: Apache-2.0
'use strict';
'require view';
'require form';
'require ui';
'require uci';

// 设置 Tab —— form.Map 对标 OPNsense 设置页分组。
//
// 字段一律「正向 / UI 语义」（勾选=启用），UCI 存正向值；取反（disable_*/block_*）
// 只在 /etc/init.d/netbird-settings 渲染 netbird up flag 时发生，前端不感知取反。
//
// Save & Apply 走 form.Map 标准机制：写 /etc/config/netbird → commit → procd reload
// trigger（netbird-settings service_triggers 注册 procd_add_reload_trigger "netbird"）
// 自动应用。无自定义 apply 按钮——标准页脚「保存并应用/保存/复位」即唯一应用入口。
//
// SSH 5 子项 + Rosenpass 宽松模式用 .depends() 联动显隐。

// 接口名黑名单前缀（提示可能与其他服务冲突；不阻断）。
// 'wt' 是 netbird 自身的 WG 前缀（wt0/wt1/wt3… 都是合法 netbird 接口名，不算冲突），不列入告警；
// 只警告会与**其他**服务（ZeroTier / 其他 WireGuard / docker 等）撞名的前缀。
var IFACE_BLACKLIST = ['utun', 'tun0', 'zt', 'wg', 'ts', 'docker', 'veth', 'br-', 'lo'];

function ifaceWarn(value) {
	if (!value || value === 'wt0')
		return null;
	for (var i = 0; i < IFACE_BLACKLIST.length; i++) {
		var p = IFACE_BLACKLIST[i];
		if (value === p || value.indexOf(p) === 0)
			return p;
	}
	return null;
}

// PresharedKey —— WireGuard 预共享密钥的 write-only 字段（务实 write-only,密钥绝不回显）。
// 设计取舍(已与用户确认):form.Map('netbird') 会把整个 netbird 配置(含 preshared_key 原文)
// 载入浏览器 uci 缓存——这等同管理员经 SSH `uci show netbird` 读自己的密钥,非提权,可接受。
// 注(OWRT25/LuCI 26):此读取需 ACL 显式 `read.uci: ["netbird"]`——旧版 LuCI「uci 写权限隐含
// 读权限」在 LuCI 26 不再成立,缺显式读 → 设置页 uci/get 报 ubus code 6「没有权限」。
// 本字段做到「不回显/不入截图/不入日志」:
//   - cfgvalue 永远回 ''：表单永不预填/回显原文(即便缓存里有);
//   - write 仅在用户输入非空时 uci.set：留空=保持原值(LuCI 见 formvalue==cfgvalue 跳过写);
//   - remove no-op：留空不删除已存密钥;
//   - renderWidget 据缓存里是否已有 PSK 设占位提示(只读布尔判断,不显示原文)。
// --preshared-key 的渲染集中在 /etc/init.d/netbird-settings(取反矩阵同址);其值**不进**任何
// 日志/dry-run 串(只显示静态占位,真值仅执行时追加),故 PSK 不入 logread(见那里 psk_disp)。
var PresharedKey = form.Value.extend({
	__name__: 'CBI.NetbirdPresharedKey',
	cfgvalue: function () {
		return '';
	},
	renderWidget: function (section_id /*, option_index, cfgvalue */) {
		this.placeholder = uci.get('netbird', section_id, 'preshared_key')
			? _('A key is configured; leave blank to keep it')
			: _('No key set');
		return form.Value.prototype.renderWidget.apply(this, arguments);
	},
	write: function (section_id, value) {
		if (value != null && value !== '')
			uci.set('netbird', section_id, 'preshared_key', value);
	},
	remove: function () {
		/* 留空不删除已存密钥（write-only 语义） */
	}
});

return view.extend({
	render: function () {
		var m, s, o;

		m = new form.Map('netbird', _('NetBird') + ' — ' + _('Settings'),
			_('Connection and behavior settings applied via "netbird up". Forward semantics: a checked box enables the feature.'));

		s = m.section(form.NamedSection, 'settings', 'netbird');
		s.addremove = false;

		// ── 常规 ──────────────────────────────────────────────────────────────
		s.tab('general', _('General'));

		o = s.taboption('general', form.Flag, 'service_enabled', _('Enabled'),
			_('Master switch. When off, NetBird disconnects and the service is stopped and disabled.'));
		o.default = '1';
		o.rmempty = false;

		o = s.taboption('general', form.Value, 'wireguard_port', _('WireGuard port'),
			_('UDP listening port for the WireGuard interface (default 51820).'));
		o.datatype = 'port';
		o.placeholder = '51820';
		o.default = '51820';
		o.rmempty = false;

		o = s.taboption('general', form.Value, 'interface_name', _('WireGuard interface name'),
			_('Renaming can avoid conflicts with other WireGuard services on this router (default wt0).'));
		o.default = 'wt0';
		o.rmempty = false;
		o.validate = function (section_id, value) {
			if (value == null || value === '')
				return true;
			// 格式校验：首字符字母，后续字母数字/下划线/连字符，总长 1..15（Linux IFNAMSIZ 安全区）
			if (!/^[a-zA-Z][a-zA-Z0-9_-]{0,14}$/.test(value))
				return _('Invalid interface name. Use 1-15 chars: start with a letter, then letters/digits/_/-.');
			// 黑名单：仅警告，不阻断。去重用「已警告值」表（每个不同值最多警告一次，
			// 修掉旧逻辑只防连续相同值、逐键刷一排告警的问题）。
			var hit = ifaceWarn(value);
			if (hit) {
				this._nbWarned = this._nbWarned || {};
				if (!this._nbWarned[value]) {
					this._nbWarned[value] = true;
					ui.addNotification(null, E('p', {}, _('Interface name "%s" looks like a reserved/blacklisted prefix ("%s"); it may conflict with other services. Use "wt0" if unsure.').format(value, hit)), 'warning');
				}
			}
			return true;
		};

		// 上游行为:peer 名称/FQDN 仅在首次注册时取自 hostname,之后改动只更新元数据,
		// 不会改服务端 peer 名;改名唯一途径是管理控制台编辑 peer。文案须如实说明,避免误导。
		o = s.taboption('general', form.Value, 'hostname', _('Hostname'),
			_('Device name reported to NetBird. Applied only when the peer first registers; to rename an already registered device, edit it in the NetBird management console. Leave blank to use the system hostname.'));
		o.rmempty = true;

		// WireGuard 预共享密钥(write-only;自定义 PresharedKey 字段处理不回显/留空保持)。
		o = s.taboption('general', PresharedKey, 'preshared_key', _('WireGuard pre-shared key'),
			_('Optional extra encryption layer for WireGuard; if set, all peers must use the same key.'));
		o.password = true;
		// optional：PSK 可选——留空合法(=保持当前),不显示必填星号、不阻断 Save&Apply。
		// 留空保持/非空写入由 PresharedKey 的 cfgvalue/write/remove 处理,与 rmempty 无关。
		o.optional = true;
		o.validate = function (section_id, value) {
			if (value == null || value === '')
				return true;
			if (/\s/.test(value))
				return _('The pre-shared key must not contain spaces.');
			return true;
		};

		// 注：管理 URL 字段已移至「认证」页统一管理（认证页 do_up 写入 UCI management_url，
		// init.d 仍读它生效）；此处不再重复编辑，避免两处入口冲突。

		// ── 防火墙 ────────────────────────────────────────────────────────────
		s.tab('firewall', _('Firewall'));

		o = s.taboption('firewall', form.Flag, 'enable_firewall', _('Enable Firewall'),
			_("NetBird's own firewall rules (mesh ACL) — separate from the OpenWrt zone and forwarding on the Network tab."));
		o.default = '1';
		o.rmempty = false;

		o = s.taboption('firewall', form.Flag, 'block_inbound', _('Block Inbound'),
			_('Block all inbound connections to this machine and routed networks (overrides management policies). This also blocks the NetBird to LAN forwarding on the Network tab.'));
		o.default = '0';
		o.rmempty = false;

		// ── SSH ───────────────────────────────────────────────────────────────
		s.tab('ssh', _('SSH'));

		o = s.taboption('ssh', form.Flag, 'allow_ssh', _('Enable SSH'),
			_('Run the NetBird SSH server on this peer.'));
		o.default = '0';
		o.rmempty = false;

		o = s.taboption('ssh', form.Flag, 'ssh_root', _('SSH Root Login'),
			_('Allow root login via the NetBird SSH server. Requires netbird 0.72.x; ignored on older versions.'));
		o.default = '0';
		o.rmempty = false;
		o.depends('allow_ssh', '1');

		o = s.taboption('ssh', form.Flag, 'ssh_sftp', _('SSH SFTP'),
			_('Enable the SFTP subsystem. Requires netbird 0.72.x; ignored on older versions.'));
		o.default = '0';
		o.rmempty = false;
		o.depends('allow_ssh', '1');

		o = s.taboption('ssh', form.Flag, 'ssh_local_fwd', _('SSH Local Port Forwarding'),
			_('Allow local port forwarding through the SSH server. Requires netbird 0.72.x.'));
		o.default = '0';
		o.rmempty = false;
		o.depends('allow_ssh', '1');

		o = s.taboption('ssh', form.Flag, 'ssh_remote_fwd', _('SSH Remote Port Forwarding'),
			_('Allow remote port forwarding through the SSH server. Requires netbird 0.72.x.'));
		o.default = '0';
		o.rmempty = false;
		o.depends('allow_ssh', '1');

		o = s.taboption('ssh', form.Flag, 'enable_ssh_auth', _('Enable SSH Authentication'),
			_('Require authentication for the NetBird SSH server. Requires netbird 0.72.x; ignored on older versions.'));
		o.default = '1';
		o.rmempty = false;
		o.depends('allow_ssh', '1');

		// ── DNS ───────────────────────────────────────────────────────────────
		s.tab('dns', _('DNS'));

		o = s.taboption('dns', form.Flag, 'enable_dns', _('Enable DNS'),
			_('Let NetBird configure DNS. Off by default on OpenWrt to avoid competing with dnsmasq for port 53.'));
		o.default = '0';
		o.rmempty = false;

		// ── 路由 ──────────────────────────────────────────────────────────────
		s.tab('routing', _('Routing'));

		o = s.taboption('routing', form.Flag, 'access_lan', _('Access LAN'),
			_('Allow access to local networks (LAN) when this peer acts as a router or exit node.'));
		o.default = '1';
		o.rmempty = false;

		o = s.taboption('routing', form.Flag, 'accept_client_routes', _('Accept Client Routes'),
			_('Process client routes received from the management service.'));
		o.default = '1';
		o.rmempty = false;

		o = s.taboption('routing', form.Flag, 'accept_server_routes', _('Accept Server Routes'),
			_('Act as a router for server routes received from the management service.'));
		o.default = '1';
		o.rmempty = false;

		// ── IPv6 ──────────────────────────────────────────────────────────────
		s.tab('ipv6', _('IPv6'));

		o = s.taboption('ipv6', form.Flag, 'enable_ipv6', _('Enable IPv6'),
			_('Request and use an IPv6 overlay address. Requires netbird 0.72.x; ignored on older versions.'));
		o.default = '1';
		o.rmempty = false;

		// ── 后量子 ────────────────────────────────────────────────────────────
		s.tab('postquantum', _('Post-Quantum'));

		o = s.taboption('postquantum', form.Flag, 'rosenpass_enabled', _('Enable Rosenpass'),
			_('Post-quantum secure the connection via Rosenpass (experimental).'));
		o.default = '0';
		o.rmempty = false;

		o = s.taboption('postquantum', form.Flag, 'rosenpass_permissive', _('Rosenpass Permissive'),
			_('Accept WireGuard connections from peers that do not have Rosenpass enabled.'));
		o.default = '0';
		o.rmempty = false;
		o.depends('rosenpass_enabled', '1');

		// ── 日志 ──────────────────────────────────────────────────────────────
		s.tab('logging', _('Logging'));

		o = s.taboption('logging', form.ListValue, 'log_level', _('Log Level'),
			_('Verbosity of the NetBird service log. Applied to the running service without reconnecting, and again whenever the service restarts. Requires netbird 0.27.4 or newer; older versions always log at info.'));
		// netbird 官方日志级别(docs.netbird.io：trace/debug/info/warn/error,阈值语义
		// 「debug 也含 info」)。panic/fatal 是 logrus 内部级别、守护进程用不到,不暴露。
		// 与日志页严重性筛选保持同一套 5 级。
		o.value('error', 'error');
		o.value('warn', 'warn');
		o.value('info', 'info');
		o.value('debug', 'debug');
		o.value('trace', 'trace');
		o.default = 'info';
		o.rmempty = false;

		o = s.taboption('logging', form.Flag, 'allow_remote_jobs', _('Allow remote diagnostics'),
			_('Let the NetBird management server collect a debug bundle from this router on request (for example from the dashboard). Debug bundles contain logs and network details and are uploaded to NetBird or to your self-hosted upload service. Requires netbird 0.78 or newer; ignored on older versions.'));
		o.default = '0';
		o.rmempty = false;

		// 标准 Save & Apply（form.Map 默认页脚「保存并应用/保存/复位」）会写 UCI → commit
		// → 经 procd reload trigger 自动应用（netbird-settings service_triggers 注册
		// procd_add_reload_trigger "netbird"，见 build-and-test §7）。无自定义 apply 按钮。
		return m.render();
	}
});
