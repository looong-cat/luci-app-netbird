#!/usr/bin/env node
// SPDX-License-Identifier: Apache-2.0
// 下载二进制时官方校验和核对的回归测试。
// 从产品源码提取真实的 _update_binary_locked,只替换命令执行、下载、ELF 探测和文件系统边界,
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
function _latest_version() { return '${VER}'; }
function _github_asset_api_url(ver, name) { return ''; }
function _http_content_length(url, headers) { return 0; }
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

const OFFICIAL = { url: '' };
const CUSTOM = { url: 'https://mirror.example/' + ASSET };
// expect: 'abort' = 校验和类失败,未执行候选二进制,且清理了 work;'ok' = 正常装完。
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
];

function run() {
	const body = ['_SEMVER_RE', '_ARCH_RE'].map(extractConst).join('\n') + '\n' + extract('_update_binary_locked');
	assert(body.includes('function _update_binary_locked('), '未提取到 _update_binary_locked');
	assert(body.includes('const _SEMVER_RE') && body.includes('const _ARCH_RE'), '未提取到版本或架构白名单');
	const code = PRELUDE + body + `
let cases = ${JSON.stringify(CASES)};
for (let c in cases) {
	cmds = []; phases = []; tc = c;
	let r = _update_binary_locked({ args: c.args });
	let ran = false, cleaned_at = -1, ran_at = -1;
	for (let i = 0; i < length(cmds); i++) {
		if (index(cmds[i], "' version") >= 0) { ran = true; ran_at = i; }
		if (cmds[i] == "rm -rf '${WORK}' 2>/dev/null") cleaned_at = i;
	}
	printf('%J\\n', { r, ran, cleaned: cleaned_at >= 0, cleaned_last: cleaned_at == length(cmds) - 1, last_phase: phases[length(phases) - 1] });
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

const results = run();
let failed = 0;
CASES.forEach((c, i) => {
	const res = results[i];
	let problem = '';
	try {
		if (c.expect === 'abort') {
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
		}
	} catch (e) {
		problem = e.message;
	}
	console.log((problem ? 'FAIL ' : 'ok   ') + c.name + (problem ? ': ' + problem : ''));
	if (problem) failed++;
});
if (failed) {
	console.error(failed + ' 项失败');
	process.exit(1);
}
console.log('全部通过');
