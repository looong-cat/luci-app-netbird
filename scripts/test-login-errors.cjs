#!/usr/bin/env node
// SPDX-License-Identifier: Apache-2.0
// 登录失败归因与失败后状态刷新的回归测试。
// 从产品源码提取真实函数,只替换 CLI、日志读取、持久化和 RPC/DOM 边界,不连接设备。
// 依赖本机的 ucode 与 node。用法: node scripts/test-login-errors.cjs
'use strict';
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const assert = require('node:assert/strict');
const { execFileSync } = require('node:child_process');

const PKG = path.join(__dirname, '..', 'luci-app-netbird');
const BACKEND = fs.readFileSync(path.join(PKG, 'root/usr/share/rpcd/ucode/netbird.uc'), 'utf8');
const VIEW_DIR = path.join(PKG, 'htdocs/luci-static/resources/view/netbird');

const NEW_KEY_ERROR = '2026-10-21T03:43:15.755Z ERRO client/server/server.go:495: failed login: rpc error: code = InvalidArgument desc = invalid setup-key or no sso information provided, err: invalid UUID format';
const OLD_KEY_ERROR = 'setup key is invalid';
const LOCAL_CLOSE = '2026-10-21T03:46:04.245Z INFO ./caller_not_available:0: WARNING: [core] [Server #1] grpc: Server.processUnaryRPC failed to write status: connection error: desc = "transport is closing"';
const REMOTE_REFUSED = 'management connection refused';
const LOCAL_DIAL = 'rpc error: code = Unavailable desc = connection error: desc = "transport: Error while dialing: dial unix /var/run/netbird.sock"';
const KEY_REJECTED = 'Authentication failed: the setup key was rejected';
const UNREACHABLE = 'The management server is temporarily unreachable.';
const NEUTRAL = 'NetBird did not become connected before the timeout.';

function extract(name) {
	const m = BACKEND.match(new RegExp('^function ' + name + '\\([^\\n]*\\) \\{[\\s\\S]*?^\\}', 'm'));
	return m ? m[0] : '';
}

const FUNCTIONS = ['_line_mentions_auth_problem', '_recent_auth_log_text', '_count_auth_hits', '_classify_auth_failure',
	'_lines_added_since', '_strip_local_ipc_lines', '_auth_failure_from_attempt', '_recent_log_text',
	'_classify_transient_connect_failure', '_cli_immediate_error', '_do_up'];

const PRELUDE = `
let logs = [], fresh = [], saved = '', desired = null, polls = 0, downs = 0, cli = {}, connected = false, status_text = null;
const CODE = { INVALID_INPUT: 'invalid_input', NOT_INSTALLED: 'not_installed', CONNECT_FAILED: 'connect_failed' };
const _NB_SETTINGS_APPLIED = '/nonexistent';
function err(code, message, hint) { return { ok: false, code, message, hint }; }
function ok(data) { return { ok: true, data }; }
function access(path, mode) { return true; }
function _mark_settings_pending() {}
function _resolve_mgmt_url(url) { return { ok: true, url: null }; }
function _ensure_helper_services() {}
function _persist_mgmt_url(url) {}
function _ensure_configured_binary() {}
function resolve_netbird_bin() { return '/fake/netbird'; }
function _daemon_mgmt_url(bin) { return null; }
function _norm_mgmt_url(url) { return url; }
function classify_status_text(txt) { return status_text; }
function _exec_short_verb(bin, verb) { if (verb == 'down') downs++; return { stdout: '' }; }
function _persist_runtime_error(text) { saved = text; }
function _clear_runtime_error() { saved = ''; }
function _set_desired_connected(value) { desired = value; }
function _build_auth_cmd(bin, verb, url, key) { return ''; }
function _exec_auth_cmd(cmd, max_bytes, secs) {
	for (let line in fresh) push(logs, line);
	return { code: cli.code != null ? cli.code : 124, stdout: cli.stdout != null ? cli.stdout : 'netbird command timed out after 25 seconds' };
}
function _poll_connected(bin, rounds) { polls++; return { connected, json: null }; }
function _persist_setup_key_hint(key) {}
function _flush_reconnect_conntrack() {}
function _apply_pending_settings() {}
function _read_daemon_logs(limit) { return { lines: logs }; }
`;

// key: 带 key 的首次登录;空 key 走已有身份的重连路径。
const BACKEND_CASES = [
	{ name: '旧格式 key 错误', key: 'k', after: [OLD_KEY_ERROR], want: KEY_REJECTED, polls: 0 },
	{ name: '新格式 key 错误', key: 'k', after: [NEW_KEY_ERROR], want: KEY_REJECTED, polls: 0 },
	{ name: '旧的本地关闭日志不影响新 key 错误', key: 'k', before: [LOCAL_CLOSE], after: [NEW_KEY_ERROR], want: KEY_REJECTED },
	{ name: '旧 key 错误不污染本次失败', key: 'k', before: [NEW_KEY_ERROR], after: [], want: NEUTRAL },
	{ name: '本次新增的本地关闭不算管理端不可达', key: 'k', after: [LOCAL_CLOSE], want: NEUTRAL },
	{ name: '旧的连接拒绝不算本次失败', key: 'k', before: [REMOTE_REFUSED], after: [], want: NEUTRAL },
	{ name: '本次连接拒绝归为管理端不可达', key: 'k', after: [REMOTE_REFUSED], want: UNREACHABLE },
	{ name: 'CLI 连本地服务的报错不算管理端不可达', key: 'k', after: [], stdout: LOCAL_DIAL, code: 1, want: NEUTRAL },
	{ name: '有效 key 的早期失败日志不影响成功', key: 'k', after: [NEW_KEY_ERROR], stdout: '', code: 0, connected: true, success: true },
	{ name: '已有身份重连:本次连接拒绝', key: '', after: [REMOTE_REFUSED], want: UNREACHABLE, keepsDesired: true },
	{ name: '已有身份重连:旧连接拒绝给中性结果', key: '', before: [REMOTE_REFUSED], after: [], want: NEUTRAL, keepsDesired: true },
	{ name: '已有身份重连:成功', key: '', after: [], stdout: '', code: 0, connected: true, success: true },
];

function runBackendCases() {
	const body = FUNCTIONS.map(extract).filter(Boolean).join('\n');
	assert(body.includes('function _do_up('), '未提取到 _do_up');
	const code = PRELUDE + body + `
let cases = ${JSON.stringify(BACKEND_CASES)};
for (let c in cases) {
	logs = [ ...(c.before || []) ]; fresh = c.after || []; polls = 0; downs = 0; saved = ''; desired = null;
	cli = { code: c.code, stdout: c.stdout }; connected = !!c.connected; status_text = null;
	let r = _do_up({ args: { setup_key: c.key } });
	printf('%J\\n', { name: c.name, ok: r.ok, message: r.message, saved, polls, downs, desired });
}
`;
	const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'nb-login-test-'));
	const file = path.join(dir, 'replay.uc');
	fs.writeFileSync(file, code);
	let out;
	try {
		out = execFileSync('ucode', [file], { encoding: 'utf8' });
	} finally {
		fs.rmSync(dir, { recursive: true, force: true });
	}
	return out.trim().split('\n').map(JSON.parse);
}

function checkBackendCases(results) {
	let failed = 0;
	BACKEND_CASES.forEach((c, i) => {
		const r = results[i];
		let problem = '';
		if (c.success) {
			if (!r.ok) problem = '应成功,实际: ' + r.message;
		} else if (r.ok || !String(r.message).startsWith(c.want)) {
			problem = '期望「' + c.want + '」,实际「' + r.message + '」';
		} else if (r.saved !== r.message) {
			problem = '持久化的错误和返回不一致';
		} else if (c.polls != null && r.polls !== c.polls) {
			problem = '轮询次数 ' + r.polls;
		} else if (c.keepsDesired && r.desired === false) {
			problem = '已有身份重连不应清除保持连接';
		}
		console.log((problem ? 'FAIL ' : 'ok   ') + c.name + (problem ? ': ' + problem : ''));
		if (problem) failed++;
	});
	return failed;
}

const translate = (s) => s;
const E = (tag, attrs, children) => ({ tag, attrs, children });

function loadPage(sample, env) {
	const source = fs.readFileSync(path.join(VIEW_DIR, 'overview.js'), 'utf8');
	const helpers = fs.readFileSync(path.join(VIEW_DIR, 'dom-helpers.js'), 'utf8');
	const L = { Class: { extend: (x) => x }, env: {}, resolveDefault: (p, d) => p.catch(() => d) };
	const nb = new Function('L', '_', 'E', helpers)(L, translate, E);
	const rpc = { declare: (spec) => async () => {
		switch (spec.method) {
		case 'get_status':
			env.statusReads++;
			if (env.statusReads > 1 && sample.refreshFails) throw new Error('XHR request aborted by browser');
			return { ok: true, data: { status: env.state } };
		case 'get_auth_info':
			if (env.statusReads > 1 && sample.refreshFails) throw new Error('XHR request aborted by browser');
			return { ok: true, data: { last_error: env.lastError, management_url: 'https://stale.invalid' } };
		case 'get_binary_info': return { ok: true, data: {} };
		case 'get_connection_info': return { ok: true, data: { management: { connected: false } } };
		case 'do_up':
			env.state = 'needs_login';
			env.lastError = (sample.response && sample.response.message) || '';
			if (sample.exception) throw new Error(sample.exception);
			return sample.response;
		default: throw new Error('意外 RPC: ' + spec.method);
		}
	} };
	const document = { getElementById: (id) => env.fields[id] };
	const page = new Function('rpc', 'view', 'ui', 'nb', 'L', '_', 'E', 'window', 'location', 'document', source)(
		rpc, { extend: (x) => x }, { addNotification: (...x) => env.notices.push(x), createHandlerFn: () => () => {} },
		nb, L, translate, E, { setTimeout: (fn) => env.timers.push(fn) }, { reload: () => { env.reloads++; } }, document);
	return page;
}

async function runFrontendCase(sample) {
	const env = { statusReads: 0, notices: [], timers: [], reloads: 0, state: 'service_disabled', lastError: '', replaced: 0,
		fields: {} };
	const root = { parentNode: { replaceChild: () => { env.replaced++; } } };
	env.fields = { 'nb-mgmt-url': { value: 'https://typed.example' }, 'nb-setup-key': { value: 'synthetic-test-key' }, 'nb-overview': root };
	const page = loadPage(sample, env);
	page._nbAuthState = (await page.load()).state;
	const rendered = [];
	const realRender = page.render;
	page.render = function (data) { rendered.push(data); return realRender.call(this, data); };
	const btn = { disabled: true, classList: { add() {}, remove() {} } };
	await page.handleConnect({ currentTarget: btn });
	return { env, rendered, btn, state: page._nbAuthState };
}

async function runFrontendCases() {
	let failed = 0;
	const check = (name, fn) => {
		try {
			fn();
			console.log('ok   ' + name);
		} catch (e) {
			failed++;
			console.log('FAIL ' + name + ': ' + e.message);
		}
	};
	const message = 'Authentication failed: the setup key was rejected by the NetBird management server.';
	const failure = await runFrontendCase({ response: { ok: false, message } });
	check('业务失败后重新读取状态并保留通知和输入', () => {
		assert.equal(failure.env.statusReads, 2);
		assert.equal(failure.env.replaced, 1);
		assert.equal(failure.rendered[0].state, 'needs_login');
		assert.equal(failure.rendered[0].lastAuthError, message);
		assert(JSON.stringify(failure.env.notices).includes(message));
		assert.equal(failure.env.reloads + failure.env.timers.length, 0);
		assert.equal(failure.env.fields['nb-setup-key'].value, '');
		assert.equal(failure.btn.disabled, false);
	});
	const aborted = await runFrontendCase({ exception: 'XHR request aborted by browser' });
	check('请求中断后重新读取状态并保留通知', () => {
		assert.equal(aborted.env.statusReads, 2);
		assert.equal(aborted.rendered[0].state, 'needs_login');
		assert(JSON.stringify(aborted.env.notices).includes('XHR request aborted by browser'));
	});
	const refreshFails = await runFrontendCase({ exception: 'XHR request aborted by browser', refreshFails: true });
	check('刷新失败时显示未知,不沿用旧状态', () => {
		assert.equal(refreshFails.rendered[0].state, 'unknown');
		assert(JSON.stringify(refreshFails.env.notices).includes('XHR request aborted by browser'));
	});
	const success = await runFrontendCase({ response: { ok: true, data: { connected: true } } });
	check('成功时仍计划整页刷新,不额外重绘', () => {
		assert.equal(success.env.timers.length, 1);
		assert.equal(success.env.statusReads, 1);
		assert.equal(success.env.replaced, 0);
	});
	return failed;
}

(async () => {
	let failed = checkBackendCases(runBackendCases());
	failed += await runFrontendCases();
	if (failed) {
		console.error(failed + ' 项失败');
		process.exit(1);
	}
	console.log('全部通过');
})().catch((e) => { console.error(e); process.exit(1); });
