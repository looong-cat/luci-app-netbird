// SPDX-License-Identifier: Apache-2.0
//
// Canonical runtime path: /usr/share/rpcd/ucode/lib/netbird_cli.uc
// Repo canonical source:  root/usr/share/rpcd/ucode/lib/netbird_cli.uc
//
// netbird_cli.uc — netbird CLI / opkg / ubus 访问层
//
// 设计要点：
//   - 两段式 status 调用：先文本 classify_status_text() 区分 needs_login，
//     再仅在 running 态调用 fetch_status_json()；禁止无条件跑 --json catch parse_error。
//   - 多正则变体（NeedsLogin 文本鲁棒化）。
//   - 5s timeout（热路径防卡死）：所有 popen/system 调用以 timeout 5s 前缀包装。
//     注意：BusyBox 1.36.1 默认未携带 timeout applet（v0.59.13 确认），
//     _with_timeout() 在 timeout 可执行不存在时退化为透传命令。
//   - shell.uc::shell_quote 包裹动态参数（注入防线）。
//   - ubus 主判定（procd 视角最可靠）：probe_running_via_ubus() 走
//     `ubus call service list '{"name":"netbird"}'` 解析 instances[*].running。
//   - 严禁反向引用 state 模块（防循环依赖）。
//
// module-compat：作为 ucode 模块经 loadfile()() 加载，返回
// { classify_status_text, fetch_status_json, get_opkg_versions, probe_running_via_ubus }。
// shell.uc 也用 loadfile 加载，路径走 NBLIB env override（默认 /usr/share/rpcd/ucode/lib）。

import { popen, access } from 'fs';

const _LIB = getenv('NBLIB') || '/usr/share/rpcd/ucode/lib';
let _shell = loadfile(_LIB + '/shell.uc')();
let shell_quote = _shell.shell_quote;

// ============================================================================
// 内部：5s timeout 包装
// ============================================================================
// 检测 host 是否有 `timeout` 可执行；缓存到模块加载时。
const _HAS_TIMEOUT = access('/usr/bin/timeout', 'x') || access('/bin/timeout', 'x');

// _with_timeout(cmd) → 拼接 `timeout 5s <cmd>` 或 `<cmd>`（无 timeout 时降级）
// 此处保留 'timeout 5s' 字面常量以标明命令超时(5s)设计。
function _with_timeout(cmd) {
    if (_HAS_TIMEOUT)
        return 'timeout 5s ' + cmd;
    return cmd;  // 降级：BusyBox 部分构建无 timeout（v0.59.13）
}

// _popen_read(cmd, max_bytes?) → { stdout, exit_code, ok_pipe }
// 注意 ucode popen 单管道返码语义：close() 返回 exit code（已 >>8 处理）
function _popen_read(cmd, max_bytes) {
    let fd = popen(cmd, 'r');
    if (fd == null)
        return { stdout: '', exit_code: -1, ok_pipe: false };
    let raw = fd.read('all') || '';
    if (max_bytes != null && length(raw) > max_bytes)
        raw = substr(raw, 0, max_bytes);
    let rc = fd.close();
    return { stdout: raw, exit_code: (rc == null ? -1 : rc), ok_pipe: true };
}

// ============================================================================
// classify_status_text(stdout) → 'needs_login' | null
// ============================================================================
// 多正则变体（任一命中即返 'needs_login'）：
//   - /Daemon status:\s*NeedsLogin/i        — 当前 v0.59/0.66 原始形态
//   - /Daemon status:\s*Needs\s+Login/i     — 空格变体（CLI 文案微调容忍）
//   - /\bneeds_login\b/i                    — 下划线变体（未来 CLI 可能采用）
//   - /\bLogin\s+required\b/i               — 通用短语变体
// 注：ucode 正则不支持 `m` 多行 flag，使用 `i`（不区分大小写）+ 子串匹配等价覆盖。
//
// 输入：null / 空串 → null；非 null 字符串遍历正则数组。
// 不抛异常；非字符串调用方需自行转换。
const _NEEDS_LOGIN_PATS = [
    /Daemon status:\s*NeedsLogin/i,
    /Daemon status:\s*Needs\s+Login/i,
    /\bneeds_login\b/i,
    /\bLogin\s+required\b/i,
];

function classify_status_text(stdout) {
    if (stdout == null)
        return null;
    if (length(stdout) == 0)
        return null;
    for (let pat in _NEEDS_LOGIN_PATS)
        if (match(stdout, pat))
            return 'needs_login';
    return null;
}

// ============================================================================
// fetch_status_json(bin_path) → { ok:true, data } | { ok:false, code, message }
// ============================================================================
// 仅 running 态调用；调用方负责前置态判定。
// 失败码语义（与 envelope.uc CODE 枚举对齐）：
//   - cli_error     → 退出码非 0；message 为 stdout 前 512B
//   - cli_error     → 退出码 124（timeout 语义）；message = "timeout after 5s"
//   - parse_error   → 退出码 0 但 json() 解析失败
//
// 注：本模块不 import envelope.uc 以避免与 netbird.uc 入口的契约耦合；
//     直接返回 ok/code 字面 dict，调用方（state 模块 / netbird.uc）按需 wrap。
function fetch_status_json(bin_path) {
    if (bin_path == null || length(bin_path) == 0)
        return { ok: false, code: 'cli_error', message: 'The binary path is empty.' };

    let cmd = _with_timeout(shell_quote(bin_path) + ' status --json 2>&1');
    // 读取上限须容纳完整 JSON:输出主项是每个路由 peer 的 networks 数组,随该 peer
    // 被管理端下发的 network resources 增长(netbird 0.76 实测 ~20B/资源,peer 数
    // 本身贡献很小),选 exit node 再追加 routes 字段。超限截断会让 json() 抛
    // "unexpected end of data",且本函数被 get_status / 连接确认轮询等共用,
    // 一旦截断 UI 会在连接完全正常时恒显 Disconnected。1MiB 约容 5 万条资源,
    // 仍保留上限防异常输出撑爆内存(_popen_read 为读全量后截断,提高上限无管道风险)。
    let r = _popen_read(cmd, 1048576);

    if (r.exit_code == 124)
        return { ok: false, code: 'cli_error', message: 'timeout after 5s' };
    if (r.exit_code != 0) {
        let msg = substr(r.stdout, 0, 512);
        return { ok: false, code: 'cli_error', message: msg };
    }
    try {
        let data = json(r.stdout);
        if (data == null)
            return { ok: false, code: 'parse_error', message: '"status --json" did not return JSON.' };
        return { ok: true, data: data };
    } catch (e) {
        return { ok: false, code: 'parse_error', message: '"status --json" did not return JSON: ' + (e.message || `${e}`) };
    }
}

// ============================================================================
// get_opkg_versions() → { netbird, luci_app_netbird }
// ============================================================================
// 5s timeout；找不到对应包返空串。不抛异常。命令不接受用户输入，无需 shell_quote。
// 包管理器分流(OWRT25 apk / ≤24.10 opkg):
//   opkg list-installed → "netbird - 0.59.13-r1"(名 空格 - 空格 版本)
//   apk  list --installed <name> → "netbird-0.66.2-r1 x86_64 {feed} (lic) [installed]"(连字符拼接,无空格)
function get_opkg_versions() {
    let out = { netbird: '', luci_app_netbird: '' };
    if (access('/usr/bin/apk', 'x')) {
        let rn = _popen_read(_with_timeout('apk list --installed netbird 2>/dev/null'), 65536);
        if (rn.ok_pipe) {
            let m = match(rn.stdout, /(^|\n)netbird-([0-9]\S*)\s/);
            if (m) out.netbird = m[2];
        }
        let rl = _popen_read(_with_timeout('apk list --installed luci-app-netbird 2>/dev/null'), 65536);
        if (rl.ok_pipe) {
            let m = match(rl.stdout, /(^|\n)luci-app-netbird-([0-9]\S*)\s/);
            if (m) out.luci_app_netbird = m[2];
        }
        return out;
    }
    let cmd = _with_timeout('opkg list-installed 2>/dev/null');
    let r = _popen_read(cmd, 65536);
    if (!r.ok_pipe || r.exit_code != 0)
        return out;
    // 行格式："netbird - 0.59.13-r1" / "luci-app-netbird - 0"
    let m1 = match(r.stdout, /(^|\n)netbird\s+-\s+(\S+)/);
    if (m1) out.netbird = m1[2];
    let m2 = match(r.stdout, /(^|\n)luci-app-netbird\s+-\s+(\S+)/);
    if (m2) out.luci_app_netbird = m2[2];
    return out;
}

// ============================================================================
// probe_running_via_ubus() → { running, instances, error? }
// ============================================================================
// 主判定路径（替代 pgrep argv 锚定）。
// `ubus call service list <JSON>` 必须传 JSON 对象参数；本字串拼接保留
// `service list netbird` 子串字面 + 完整 JSON arg。
// 不抛异常；ubus/procd 异常返 {running:false, instances:[], error}。
function probe_running_via_ubus() {
    // 注：命令行带完整 JSON 对象参数 '{"name":"netbird"}'。
    let cmd = _with_timeout(`ubus call service list '{"name":"netbird"}' 2>/dev/null`);
    let r = _popen_read(cmd, 65536);
    if (!r.ok_pipe)
        return { running: false, instances: [], error: 'ubus popen failed' };
    if (r.exit_code != 0)
        return { running: false, instances: [], error: sprintf('ubus exit %d', r.exit_code) };

    try {
        let js = json(r.stdout);
        let obj = (js != null && js.netbird != null) ? js.netbird : {};
        let insts_raw = (obj.instances != null) ? obj.instances : {};
        let insts_arr = [];
        let running_any = false;
        for (let k in insts_raw) {
            let inst = insts_raw[k];
            push(insts_arr, inst);
            if (inst != null && inst.running)
                running_any = true;
        }
        return { running: running_any, instances: insts_arr };
    } catch (e) {
        return { running: false, instances: [], error: `${e.message || e}` };
    }
}

return { classify_status_text, fetch_status_json, get_opkg_versions, probe_running_via_ubus };
