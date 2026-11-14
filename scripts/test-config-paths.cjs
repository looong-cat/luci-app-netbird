#!/usr/bin/env node
// SPDX-License-Identifier: Apache-2.0
// daemon 配置路径解析的回归测试:管理 URL 预填(_mgmt_url_from_config)和本地身份清除
// (_wipe_local_identity)。从产品源码提取真实函数,只把绝对路径挪进临时目录、把删除换成记录,
// 不连接设备。依赖本机的 ucode 与 node。用法: node scripts/test-config-paths.cjs
'use strict';
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const assert = require('node:assert/strict');
const { execFileSync } = require('node:child_process');

const PKG = path.join(__dirname, '..', 'luci-app-netbird');
const BACKEND = fs.readFileSync(path.join(PKG, 'root/usr/share/rpcd/ucode/netbird.uc'), 'utf8');

function extract(name) {
	const m = BACKEND.match(new RegExp('^function ' + name + '\\([^\\n]*\\) \\{[\\s\\S]*?^\\}', 'm'));
	assert(m, '未提取到 ' + name);
	return m[0];
}

const FUNCTIONS = ['_netbird_init_paths', '_read_json_file', '_mgmt_url_from_config', '_wipe_local_identity'];

// 产品代码里的系统路径都以这三个目录开头,整体挪到临时根目录下。
function relocate(code, root) {
	return code.replace(/'\/(etc|var|root)\//g, (_, top) => "'" + root + '/' + top + '/');
}

const cfg = (host) => JSON.stringify({ ManagementURL: { Scheme: 'https', Opaque: '', User: null, Host: host, Path: '' }, PrivateKey: 'synthetic' });
const OPKG_INIT = (r) => `#!/bin/sh /etc/rc.common\nstart_service() {\n\tprocd_open_instance\n\tprocd_set_param command /usr/bin/netbird service run\n\tprocd_set_param env NB_CONFIG="${r}/etc/netbird/config.json"\n}\n`;
const APK_INIT = (r) => `#!/bin/sh /etc/rc.common\nstart_service() {\n\tprocd_open_instance\n\tprocd_set_param command /usr/bin/netbird service run\n\tprocd_set_param env NB_STATE_DIR="${r}/root/.config/netbird" NB_DISABLE_SSH_CONFIG="true"\n}\n`;
const BARE_INIT = () => '#!/bin/sh /etc/rc.common\nstart_service() {\n\tprocd_open_instance\n\tprocd_set_param command /usr/bin/netbird service run\n}\n';
const DEFAULT_ACTIVE = JSON.stringify({ name: 'default', username: '' });

// files: 相对临时根的路径 → 内容(函数则以根目录为参数)。
// url: 期望的预填管理 URL;wipe: 期望删除的文件(相对路径,排序后比较),省略则不检查。
const CASES = [
	{
		name: 'opkg 老布局:init 声明 NB_CONFIG',
		files: {
			'etc/init.d/netbird': OPKG_INIT,
			'etc/netbird/config.json': cfg('opkg.example:443'),
			'var/lib/netbird/active_profile.json': DEFAULT_ACTIVE,
			'var/lib/netbird/state.json': '{}',
		},
		url: 'https://opkg.example:443',
		wipe: ['etc/netbird/config.json'],
	},
	{
		name: 'apk 布局:NB_STATE_DIR + default.json + active profile 文件',
		files: {
			'etc/init.d/netbird': APK_INIT,
			'root/.config/netbird/default.json': cfg('apk.example'),
			'root/.config/netbird/active_profile.json': DEFAULT_ACTIVE,
			'root/.config/netbird/active_profile.txt': 'default',
			'root/.config/netbird/state.json': '{}',
		},
		url: 'https://apk.example',
		wipe: ['root/.config/netbird/active_profile.json', 'root/.config/netbird/default.json', 'root/.config/netbird/state.json'],
	},
	{
		name: '无 env 裸启:/var/lib/netbird/default.json',
		files: {
			'etc/init.d/netbird': BARE_INIT,
			'var/lib/netbird/default.json': cfg('bare.example'),
			'var/lib/netbird/active_profile.json': DEFAULT_ACTIVE,
		},
		url: 'https://bare.example',
		wipe: [],
	},
	{
		name: '没有 init 脚本时按上游默认目录找',
		files: { 'var/lib/netbird/default.json': cfg('noinit.example') },
		url: 'https://noinit.example',
	},
	{
		name: '升级后新旧文件并存:default.json 优先于旧 config.json',
		files: {
			'etc/init.d/netbird': BARE_INIT,
			'var/lib/netbird/config.json': cfg('old.example'),
			'var/lib/netbird/default.json': cfg('new.example'),
		},
		url: 'https://new.example',
	},
	{
		name: '0.74 以前的旧默认路径',
		files: { 'etc/init.d/netbird': BARE_INIT, 'var/lib/netbird/config.json': cfg('legacy.example') },
		url: 'https://legacy.example',
	},
	{
		name: 'CLI 选了非 default profile 时仍取 default profile(插件只操作 default profile)',
		files: {
			'etc/init.d/netbird': APK_INIT,
			'root/.config/netbird/default.json': cfg('apk.example'),
			'root/.config/netbird/active_profile.json': JSON.stringify({ name: 'work', username: 'root' }),
			'root/.config/netbird/root/work.json': cfg('work.example'),
		},
		url: 'https://apk.example',
		wipe: ['root/.config/netbird/active_profile.json', 'root/.config/netbird/default.json'],
	},
	{
		name: '切回旧版后遗留的 0.83 profile 不影响 NB_CONFIG 指向的配置',
		files: {
			'etc/init.d/netbird': OPKG_INIT,
			'etc/netbird/config.json': cfg('opkg.example'),
			'var/lib/netbird/active_profile.json': JSON.stringify({ name: 'a1b2c3', username: '' }),
			'var/lib/netbird/profiles.v1/a1b2c3.json': cfg('v1.example'),
		},
		url: 'https://opkg.example',
	},
	{
		name: 'active profile 指向的文件不存在时回到 default profile',
		files: {
			'etc/init.d/netbird': OPKG_INIT,
			'etc/netbird/config.json': cfg('opkg.example'),
			'var/lib/netbird/active_profile.json': JSON.stringify({ name: 'gone', username: 'root' }),
		},
		url: 'https://opkg.example',
	},
	{
		name: 'active profile 名含路径时忽略',
		files: {
			'etc/init.d/netbird': APK_INIT,
			'root/.config/netbird/default.json': cfg('apk.example'),
			'root/.config/netbird/active_profile.json': JSON.stringify({ name: '../../../etc/secret', username: '' }),
			'etc/secret.json': cfg('outside.example'),
		},
		url: 'https://apk.example',
	},
	{
		name: '配置损坏时返回空',
		files: { 'etc/init.d/netbird': APK_INIT, 'root/.config/netbird/default.json': '{not json' },
		url: '',
	},
	{
		name: '什么都没有时返回空',
		files: {},
		url: '',
		wipe: [],
	},
];

function runCase(c) {
	const root = fs.mkdtempSync(path.join(os.tmpdir(), 'nb-config-paths-'));
	try {
		for (const [rel, content] of Object.entries(c.files)) {
			const file = path.join(root, rel);
			fs.mkdirSync(path.dirname(file), { recursive: true });
			fs.writeFileSync(file, typeof content === 'function' ? content(root) : content);
		}
		const code = `
const fs = require('fs');
const access = fs.access, open = fs.open, lsdir = fs.lsdir;
let unlinked = [];
function unlink(p) { push(unlinked, p); return true; }
` + relocate(FUNCTIONS.map(extract).join('\n'), root) + `
let url = _mgmt_url_from_config();
let removed = _wipe_local_identity();
printf('%J\\n', { url, removed, unlinked });
`;
		const file = path.join(root, 'replay.uc');
		fs.writeFileSync(file, code);
		const out = JSON.parse(execFileSync('ucode', [file], { encoding: 'utf8' }).trim());
		out.unlinked = out.unlinked.map((p) => path.relative(root, p)).sort();
		return out;
	} finally {
		fs.rmSync(root, { recursive: true, force: true });
	}
}

let failed = 0;
for (const c of CASES) {
	try {
		const r = runCase(c);
		assert.equal(r.url, c.url, '管理 URL');
		if (c.wipe) {
			assert.deepEqual(r.unlinked, [...c.wipe].sort(), '删除的文件');
			assert.equal(r.removed, c.wipe.length, '删除计数');
		}
		console.log('ok   ' + c.name);
	} catch (e) {
		failed++;
		console.log('FAIL ' + c.name + ': ' + e.message);
	}
}
if (failed) {
	console.error(failed + ' 项失败');
	process.exit(1);
}
console.log('全部通过');
