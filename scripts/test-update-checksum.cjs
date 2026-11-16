#!/usr/bin/env node
// SPDX-License-Identifier: Apache-2.0
// 下载二进制时官方校验和核对、以及下载器读不了 GitHub 时提前失败的回归测试。
// 从产品源码提取真实的 _update_binary_locked 和首连兜底 _ensure_configured_binary,
// 只替换命令执行、下载、ELF 探测和文件系统边界,
// 不联网、不写任何真实文件。依赖本机的 ucode 与 node。用法: node scripts/test-update-checksum.cjs
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
	return m ? m[0] : '';
}

function extractConst(name) {
	const m = BACKEND.match(new RegExp('^const ' + name + ' = .*;$', 'm'));
	return m ? m[0] : '';
}

const VER = '0.83.1';
const ASSET = 'netbird_' + VER + '_linux_amd64.tar.gz';
const HASH = 'ab'.repeat(32);
const OTHER = 'cd'.repeat(32);
const WORK = '/nb-test-work';

// 替换边界:_popen_simple 按命令形态应答并记录;_dl_cmd 只产出可识别的标记串。
const PRELUDE = `
let cmds = [], phases = [], tc = {};
const CODE = { INVALID_INPUT: 'invalid_input', ARCH_MISMATCH: 'arch_mismatch', INSUFFICIENT_SPACE: 'insufficient_space',
	DOWNLOAD_FAILED: 'download_failed', DOWNLOAD_CANCELED: 'download_canceled', CHECKSUM_MISMATCH: 'checksum_mismatch',
	INSTALL_FAILED: 'install_failed' };
const _NB_REL_DIR = '/nb-test-rel';
const _NB_REL_BIN = '/nb-test-rel/netbird-release';
function err(code, message) { return { ok: false, code, message }; }
function ok(data) { return { ok: true, data }; }
function shell_quote(s) { return "'" + s + "'"; }
function _to(cmd, secs) { return cmd; }
function _progress_reset() {}
function _progress_phase(phase, message) { push(phases, phase); }
function _progress_canceled() { return false; }
function _detect_arch() { return { arch: 'amd64', uname_m: 'x86_64' }; }
function _overlay_free_kb() { return -1; }
// 发往 GitHub 的请求都记成 NET 开头,用于断言「不能带头时一次请求都不发」。
function _latest_version() { push(cmds, 'NET latest'); return '${VER}'; }
function _github_asset_api_url(ver, name) { push(cmds, 'NET api ' + name); return ''; }
function _http_content_length(url, headers) { push(cmds, 'NET length ' + url); return 0; }
function _dl_sends_headers() { return !tc.no_headers; }
function _pkg_mgr() { return tc.pkg_mgr || 'opkg'; }

function _dl_cmd(url, out, secs, total, headers) { return 'DL ' + url + ' > ' + out; }
function access(p, mode) { return p == '${WORK}' || p == '${WORK}/netbird'; }
function unlink(p) { push(cmds, 'unlink ' + p); }
function _file_size_kb(p) { return 30000; }
function _file_size_bytes(p) { return 30000 * 1024; }
function _elf_machine(p) { return index(p, 'download.pkg') >= 0 ? 0 : 62; }
function _arch_emachine(arch) { return 62; }
function _native_emachine() { return 62; }
function _native_elf_ident() { return ''; }
function _elf_ident(p) { return ''; }
function _parse_version_output(out) { let m = match(out, /([0-9]+\\.[0-9]+\\.[0-9]+)/); return m ? m[1] : ''; }
function _sanitize_version(v) { return v; }
function _custom_version_path(v) { return _NB_REL_DIR + '/netbird-v' + v; }
function _file_version(p) { return '${VER}'; }
function _active_binary_path() { return '/usr/bin/netbird'; }
function _active_source() { return 'opkg'; }
function _wait_daemon_gone() { return true; }
function _popen_simple(cmd) {
	push(cmds, cmd);
	if (index(cmd, 'mktemp') == 0) return { code: 0, out: '${WORK}\\n' };
	if (index(cmd, 'DL ') == 0) {
		if (index(cmd, 'checksums') >= 0) return { code: tc.sums_code, out: tc.sums_code ? 'curl: (6) Could not resolve host' : '' };
		return { code: 0, out: '' };
	}
	if (index(cmd, "cat '${WORK}/checksums.txt'") == 0) return { code: 0, out: tc.sums };
	if (index(cmd, 'sha256sum ') == 0) return { code: 0, out: '${HASH}  ${WORK}/download.pkg\\n' };
	if (index(cmd, "' version") >= 0) return { code: 0, out: 'netbird version ${VER}\\n' };
	return { code: 0, out: '' };
}
`;

// 首连兜底用到的边界:配置来源默认 release、release 二进制不存在、无退避标记。
// ucode 不提升函数声明,这段要放在 _update_binary_locked 之后、_ensure_configured_binary 之前。
const ENSURE_STUBS = `
let marker_writes = 0, switched = 0;
function _uci_binary(key, def) { return def; }
function stat(p) { return null; }
function open(p, mode) { if (p == _NB_AUTODL_FAILED && mode == 'w') marker_writes++; return { close: function() {} }; }
function _do_set_binary_source(req) { switched++; return ok({}); }
function _do_update_binary(req) { return _update_binary_locked({ args: req }); }
`;

const OFFICIAL = { url: '' };
const CUSTOM = { url: 'https://mirror.example/' + ASSET };
const GOOD_SUMS = HASH + '  ' + ASSET + '\n';
// expect: 'abort' = 校验和类失败,未执行候选二进制,且清理了 work;'ok' = 正常装完;
// 'curl' = 下载器不能带请求头,官方来源在发起任何 GitHub 请求之前就失败并提示装 curl。
const CASES = [
	{ name: '官方:校验和列表下载失败 → 中止', args: OFFICIAL, sums_code: 1, sums: '', expect: 'abort', msg: 'Could not download the official checksum list' },
	{ name: '官方:列表里没有本资产 → 中止', args: OFFICIAL, sums_code: 0,
		sums: HASH + '  netbird_' + VER + '_linux_arm64.tar.gz\n', expect: 'abort', msg: 'The official checksum list has no entry' },
	{ name: '官方:只有部分匹配的文件名不算条目 → 中止', args: OFFICIAL, sums_code: 0,
		sums: HASH + '  ' + ASSET + '.sbom.json\n' + HASH + '  x' + ASSET + '\n' + HASH.slice(1) + '  ' + ASSET + '\n',
		expect: 'abort', msg: 'The official checksum list has no entry' },
	{ name: '官方:代理错误页当作列表 → 中止', args: OFFICIAL, sums_code: 0, sums: '<html>502 Bad Gateway</html>',
		expect: 'abort', msg: 'The official checksum list has no entry' },
	{ name: '官方:条目存在但哈希不同 → 中止', args: OFFICIAL, sums_code: 0, sums: OTHER + '  ' + ASSET + '\n',
		expect: 'abort', msg: 'sha256 checksum mismatch' },
	{ name: '官方:条目匹配且哈希一致 → 继续安装', args: OFFICIAL, sums_code: 0,
		sums: OTHER + '  netbird_' + VER + '_linux_arm64.tar.gz\n' + HASH + '  ' + ASSET + '\n', expect: 'ok', note: '' },
	{ name: '自定义 URL:列表下载失败仍 best-effort 继续', args: CUSTOM, sums_code: 1, sums: '', expect: 'ok', note: 'could not fetch checksums' },
	{ name: '自定义 URL:列表无条目仍 best-effort 继续', args: CUSTOM, sums_code: 0, sums: '', expect: 'ok', note: 'no matching filename' },
	{ name: '官方:下载器不能带请求头(opkg 系统) → 不发请求直接提示装 curl', args: OFFICIAL, no_headers: true,
		sums_code: 0, sums: GOOD_SUMS, expect: 'curl', msg: 'Install curl with "opkg update && opkg install curl", then try again.' },
	{ name: '官方:下载器不能带请求头(apk 系统) → 提示 apk 命令', args: OFFICIAL, no_headers: true, pkg_mgr: 'apk',
		sums_code: 0, sums: GOOD_SUMS, expect: 'curl', msg: 'Install curl with "apk update && apk add curl", then try again.' },
	{ name: '官方:下载器能带请求头 → 照常下载安装', args: OFFICIAL, no_headers: false,
		sums_code: 0, sums: GOOD_SUMS, expect: 'ok', note: '', net: true },
	{ name: '自定义 URL:下载器不能带请求头 → 照常下载安装', args: CUSTOM, no_headers: true,
		sums_code: 0, sums: GOOD_SUMS, expect: 'ok', note: '' },
];

// 首连自动下载:不能带头时应立刻失败、写退避标记、不切换来源(继续用软件源版本);能带头时照常切到 release。
const ENSURE_CASES = [
	{ name: '首连:下载器不能带请求头 → 不发请求,写退避标记,保持软件源版本', no_headers: true, sums_code: 0, sums: GOOD_SUMS,
		expect_marker: 1, expect_switch: 0, expect_net: false },
	{ name: '首连:下载器能带请求头 → 下载后切到 release', no_headers: false, sums_code: 0, sums: GOOD_SUMS,
		expect_marker: 0, expect_switch: 1, expect_net: true },
];

function run() {
	const body = ['_SEMVER_RE', '_ARCH_RE', '_NB_AUTODL_FAILED', '_NB_AUTODL_BACKOFF'].map(extractConst).join('\n') + '\n' +
		extract('_update_binary_locked') + '\n' + ENSURE_STUBS + extract('_ensure_configured_binary');
	assert(body.includes('function _update_binary_locked('), '未提取到 _update_binary_locked');
	assert(body.includes('function _ensure_configured_binary('), '未提取到 _ensure_configured_binary');
	assert(body.includes('const _SEMVER_RE') && body.includes('const _ARCH_RE'), '未提取到版本或架构白名单');
	assert(body.includes('const _NB_AUTODL_FAILED') && body.includes('const _NB_AUTODL_BACKOFF'), '未提取到首连退避常量');
	const code = PRELUDE + body + `
let cases = ${JSON.stringify(CASES)};
for (let c in cases) {
	cmds = []; phases = []; tc = c;
	let r = _update_binary_locked({ args: c.args });
	let ran = false, cleaned_at = -1, ran_at = -1, net = false, mktemp = false;
	for (let i = 0; i < length(cmds); i++) {
		if (index(cmds[i], "' version") >= 0) { ran = true; ran_at = i; }
		if (cmds[i] == "rm -rf '${WORK}' 2>/dev/null") cleaned_at = i;
		if (index(cmds[i], 'NET ') == 0 || index(cmds[i], 'DL ') == 0) net = true;
		if (index(cmds[i], 'mktemp') == 0) mktemp = true;
	}
	printf('%J\\n', { r, ran, net, mktemp, cleaned: cleaned_at >= 0, cleaned_last: cleaned_at == length(cmds) - 1, last_phase: phases[length(phases) - 1] });
}
let ensure_cases = ${JSON.stringify(ENSURE_CASES)};
for (let c in ensure_cases) {
	cmds = []; phases = []; tc = c; marker_writes = 0; switched = 0;
	_ensure_configured_binary();
	let net = false;
	for (let x in cmds)
		if (index(x, 'NET ') == 0 || index(x, 'DL ') == 0) net = true;
	printf('%J\\n', { net, marker_writes, switched });
}
`;
	const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'nb-checksum-test-'));
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

// 下载器能力探测:rpcd 常驻进程里先探到「无 curl、uclient-fetch 不支持 --header」,
// 用户按提示装好 curl 后,同一进程再判断必须认到 curl,不能沿用缓存的结论。
function runHeaderProbe() {
	const fn = extract('_dl_tool') + '\nlet _dl_headers_ok = null;\n' + extract('_dl_sends_headers');
	assert(fn.includes('function _dl_tool(') && fn.includes('function _dl_sends_headers('), '未提取到下载器探测函数');
	const code = `
let have_curl = false;
function access(p, mode) { return p == '/usr/bin/curl' ? have_curl : p == '/bin/uclient-fetch'; }
function _popen_simple(cmd) { return { code: 0, out: 'Usage: uclient-fetch [options] <URL>\\n' }; }
` + fn + `
let before = _dl_sends_headers();
have_curl = true;
let after = _dl_sends_headers();
printf('%J\\n', { before, after });
`;
	const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'nb-header-probe-'));
	const file = path.join(dir, 'probe.uc');
	fs.writeFileSync(file, code);
	try {
		return JSON.parse(execFileSync('ucode', [file], { encoding: 'utf8' }).trim());
	} finally {
		fs.rmSync(dir, { recursive: true, force: true });
	}
}

const results = run();
let failed = 0;
CASES.forEach((c, i) => {
	const res = results[i];
	let problem = '';
	try {
		if (c.expect === 'curl') {
			assert.equal(res.r.ok, false, '应失败,实际成功');
			assert.equal(res.r.code, 'download_failed');
			assert(String(res.r.message).startsWith('The download tool built into this router cannot read the responses from GitHub'),
				'提示不符: ' + res.r.message);
			assert(String(res.r.message).endsWith(c.msg), '安装命令不符: ' + res.r.message);
			assert.equal(res.net, false, '失败前仍发起了 GitHub 请求或下载');
			assert.equal(res.mktemp, false, '失败前创建了工作目录');
			assert.equal(res.ran, false, '执行了候选二进制');
			assert.equal(res.last_phase, 'failed');
		} else if (c.expect === 'abort') {
			assert.equal(res.r.ok, false, '应失败,实际成功');
			assert.equal(res.r.code, 'checksum_mismatch');
			assert(String(res.r.message).startsWith(c.msg), '提示不符: ' + res.r.message);
			assert.equal(res.ran, false, '中止前执行了候选二进制');
			assert(res.cleaned && res.cleaned_last, '中止后没有清理临时目录');
			assert.equal(res.last_phase, 'failed');
		} else {
			assert.equal(res.r.ok, true, '应成功,实际: ' + res.r.message);
			assert.equal(res.ran, true, '未执行 version 校验');
			assert.equal(res.r.data.to, VER);
			assert(String(res.r.data.checksum_note).startsWith(c.note), 'note 不符: ' + res.r.data.checksum_note);
			if (c.net)
				assert.equal(res.net, true, '能带请求头时应照常请求 GitHub');
		}
	} catch (e) {
		problem = e.message;
	}
	console.log((problem ? 'FAIL ' : 'ok   ') + c.name + (problem ? ': ' + problem : ''));
	if (problem) failed++;
});
ENSURE_CASES.forEach((c, i) => {
	const res = results[CASES.length + i];
	let problem = '';
	try {
		assert.equal(res.net, c.expect_net, c.expect_net ? '应发起下载' : '不应发起任何 GitHub 请求或下载');
		assert.equal(res.marker_writes, c.expect_marker, '退避标记写入次数不符');
		assert.equal(res.switched, c.expect_switch, '来源切换次数不符');
	} catch (e) {
		problem = e.message;
	}
	console.log((problem ? 'FAIL ' : 'ok   ') + c.name + (problem ? ': ' + problem : ''));
	if (problem) failed++;
});
{
	const name = '下载器探测:装好 curl 后同一进程立即认到,不沿用旧缓存';
	let problem = '';
	try {
		const res = runHeaderProbe();
		assert.equal(res.before, false, '旧版 uclient-fetch 应判为不能带请求头');
		assert.equal(res.after, true, '装好 curl 后仍判为不能带请求头');
	} catch (e) {
		problem = e.message;
	}
	console.log((problem ? 'FAIL ' : 'ok   ') + name + (problem ? ': ' + problem : ''));
	if (problem) failed++;
}
if (failed) {
	console.error(failed + ' 项失败');
	process.exit(1);
}
console.log('全部通过');
