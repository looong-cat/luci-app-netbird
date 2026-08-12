// SPDX-License-Identifier: Apache-2.0
//
// Canonical runtime path: /usr/share/rpcd/ucode/netbird.uc
// Repo canonical source:  root/usr/share/rpcd/ucode/netbird.uc
//
// netbird.uc — rpcd 入口对象（注册 luci.netbird，29 methods = 13 read + 16 write）
// ACL 合约源：root/usr/share/rpcd/acl.d/luci-app-netbird.json
// 方法名必须与 ACL 一字不差（双向 diff 是 CI 闸门）。
//
// 读方法实装范围（6 read）：
//   - get_status / get_settings / get_package_versions：任何态 ok:true
//   - list_peers / list_networks / list_exit_nodes：非 running 返 err+code；running 返 data
//   - get_logs：友好化（非 running 也 ok:true + 空 lines + state + note）
//
// 设置应用无独立 apply RPC（曾有 apply_settings，已删）：走标准 Save&Apply
// （form.Map → UCI commit → procd reload trigger，见 init.d/netbird-settings）。
// 已实装：do_up / do_down / do_login / do_logout（认证 4 方法）；
// 已实装：do_enable_and_start + setup_firewall_zone/forwarding（zone 直接绑定 netbird 设备，不建 network 接口）。
//
// 硬约束：所有 read 方法禁直读 config.json 文件；一律 CLI / ubus / logread / opkg 透传。
//
// module-compat：rpcd-mod-ucode 加载本文件，期望返回 { 'luci.netbird': { ... methods } }。
// ucode 2025.07.18 不支持 export 关键字；6 个 lib 文件经 loadfile()() 加载，
// 路径走 NBLIB env override（默认 /usr/share/rpcd/ucode/lib）。
// shebang 与 'use strict' 在 module 模式下都不允许，已删除。

import { popen, access, open, unlink, lsdir } from 'fs';
import * as uci from 'uci';

const _LIB = getenv('NBLIB') || '/usr/share/rpcd/ucode/lib';
let _shell    = loadfile(_LIB + '/shell.uc')();
let _paths    = loadfile(_LIB + '/paths.uc')();
let _envelope = loadfile(_LIB + '/envelope.uc')();
let _sanitize = loadfile(_LIB + '/sanitize.uc')();
let _state    = loadfile(_LIB + '/state.uc')();
let _cli      = loadfile(_LIB + '/netbird_cli.uc')();

let shell_quote          = _shell.shell_quote;
let resolve_netbird_bin  = _paths.resolve_netbird_bin;
let ok                   = _envelope.ok;
let err                  = _envelope.err;
let CODE                 = _envelope.CODE;
let sanitize_settings    = _sanitize.sanitize_settings;
let probe_state          = _state.probe_state;
let probe_iface_backend  = _state.probe_iface_backend;
let fetch_status_json    = _cli.fetch_status_json;
let get_opkg_versions    = _cli.get_opkg_versions;
let probe_running_via_ubus = _cli.probe_running_via_ubus;

// ============================================================================
// _safe(fn) — 异常网
// ============================================================================
// rpcd 层不抛异常：方法体内任何未预期异常经此包装转为 internal_error 信封。
// 业务失败（已知 code）应在方法体内显式 return err(CODE.*, ...)，不抛异常。
function _safe(fn) {
    return function(req) {
        try { return fn(req); }
        catch (e) {
            let msg = (e != null && e.message != null) ? e.message : `${e}`;
            return err(CODE.INTERNAL_ERROR, msg);
        }
    };
}

// ============================================================================
// _require_running — Task 2/3 公共态闸
// ============================================================================
// 先跑 probe_state()：非 running 直接构造 err 信封；
// running 态额外跑 fetch_status_json（仅 running 才跑 --json），
// 失败冒泡为 err 信封。返回 { _gate, _state, _json? }，调用方按 _gate 判分支。
function _require_running() {
    let st = probe_state();
    if (st.status != 'running') {
        let code_map = {
            'not_installed':    CODE.NOT_INSTALLED,
            'service_disabled': CODE.SERVICE_DISABLED,
            'service_stopped':  CODE.SERVICE_STOPPED,
            'needs_login':      CODE.NEEDS_LOGIN,
        };
        let c = code_map[st.status] || CODE.INTERNAL_ERROR;
        return { _gate: err(c, `not running: ${st.status}`), _state: st };
    }

    let js = fetch_status_json(st.bin_path);
    if (!js.ok) {
        // fetch_status_json 返纯 dict（非信封），转成 err 信封冒泡
        return { _gate: err(js.code || CODE.CLI_ERROR, js.message || 'status --json failed'), _state: st };
    }
    return { _gate: null, _state: st, _json: js.data };
}

// ============================================================================
// _run_init(action) — init.d 子进程包装（5s timeout + 白名单 assert）
// ============================================================================
// 严格白名单 action ∈ {enable, start, stop}（stop 仅本地身份清除用：删除
// config.json 前必须停 daemon，否则运行中的 daemon 持有旧身份继续重连；
// 若要 disable 须扩 _INIT_ACTIONS 并同步更新威胁模型）。
//
// 契约：
//   返回 { code:<exit>, stdout, stderr }
//   stderr 截断前 512 字节；exit 124 特判 → stderr = 'timeout after 5s'。
//
// 不变量（安全/性能）：
//   - action 非枚举 → die()：防 caller 注入 `'; rm -rf /` 等恶意 action
//   - /etc/init.d/netbird 字面命令；action 亦是字面常量，无需 shell_quote
//   - 5s timeout 前缀包装：BusyBox 部分构建无 timeout applet，与 state.uc
//     _HAS_TIMEOUT 模式一致 —— 降级透传；源码字面保留 'timeout 5s' 以满足
//     源码字面保留以记录设计意图。
const _INIT_ACTIONS = { enable: true, start: true, stop: true };
const _RUN_INIT_HAS_TIMEOUT = access('/usr/bin/timeout', 'x') || access('/bin/timeout', 'x');

// _to(cmd) — 给命令加 5s 墙钟前缀(timeout applet 在才加;缺失透传)。集中原 5 处重复的
// `_RUN_INIT_HAS_TIMEOUT ? ('timeout 5s '+x) : x` 三元(ucode 不 hoist 函数,helper 定义在所有调用方之上)。
function _to(cmd) {
    return _RUN_INIT_HAS_TIMEOUT ? ('timeout 5s ' + cmd) : cmd;
}

function _run_init(action) {
    // 白名单 assert（防 caller 注入恶意 action）
    if (!_INIT_ACTIONS[action])
        die(sprintf('_run_init: illegal action "%s" (not in whitelist enable/start/stop)', action));

    // 命令拼接：timeout 5s /etc/init.d/netbird <action>
    // 注：action 经白名单 assert 后是字面常量，命令字面安全；2>&1 合并便于截 stderr。
    let base = '/etc/init.d/netbird ' + action + ' 2>&1';
    let cmd = _to(base);

    let fd = popen(cmd, 'r'); // shell-audit-ok: cmd 由 _INIT_ACTIONS 白名单 + 字面量拼接，action 经 die() 断言
    if (fd == null)
        return { code: -1, stdout: '', stderr: 'popen failed' };

    let buf = fd.read('all') || '';
    let rc = fd.close();
    let exit_code = (rc == null) ? -1 : rc;

    // stderr 截断 512B（防超长输出）；合并流下 stdout 与 stderr 共用 buf
    let msg = substr(buf, 0, 512);

    // timeout 124 特判 → 固定可读 stderr 文案，方便前端区分
    if (exit_code == 124)
        msg = 'timeout after 5s';

    return { code: exit_code, stdout: buf, stderr: msg };
}

// ============================================================================
// 认证辅助（do_up / do_down / do_login / do_logout）
// ============================================================================

// _valid_mgmt_url(s) → bool
// management_url 校验：必须 http(s):// 开头，host 非空，仅允许 URL 安全字符。
// 注意这是 sanitize 第一道防线；shell 注入第二道由 shell_quote 兜底（双保险）。
// 允许字符集：scheme + 字母数字 . - _ : / @ 与可选路径，禁止空白/引号/分号/反引号等。
function _valid_mgmt_url(s) {
    if (type(s) != 'string' || length(s) == 0)
        return false;
    return !!match(s, /^https?:\/\/[A-Za-z0-9._~:\/?#@!$&'()*+,;=%-]+$/);
}

// _resolve_mgmt_url(arg_url) → { ok:true, url:<string|null> } | { ok:false, message }
// 决定本次操作用哪个 management_url：
//   - 传了非空 arg_url：校验，非法返 ok:false；合法返该值（瞬时，调用方自行决定是否持久化）。
//   - arg_url 为空：回退 UCI netbird.settings.management_url（可能也是空 → null=不传 flag，用 daemon 现值）。
function _resolve_mgmt_url(arg_url) {
    if (arg_url != null && type(arg_url) == 'string' && length(arg_url) > 0) {
        if (!_valid_mgmt_url(arg_url))
            return { ok: false, message: 'Invalid management URL (expected http(s)://host[:port]).' };
        return { ok: true, url: arg_url };
    }
    // 回退 UCI 现值（非机密）
    let c = uci.cursor();
    let saved = c.get('netbird', 'settings', 'management_url');
    if (saved != null && length(saved) > 0)
        return { ok: true, url: saved };
    return { ok: true, url: null };
}

// _persist_mgmt_url(url) — 把 management_url 写入 UCI 并 commit（非机密）。
// 仅在 caller 显式传入合法 url 时调用；空值不写（避免清空已有值）。
function _persist_mgmt_url(url) {
    if (url == null || length(url) == 0)
        return;
    let c = uci.cursor();
    // settings section 由 uci-defaults 保证存在；防御性 set type。
    if (c.get('netbird', 'settings') == null)
        c.set('netbird', 'settings', 'netbird');
    c.set('netbird', 'settings', 'management_url', url);
    c.commit('netbird');
}

// _norm_mgmt_url(u) → 管理 URL 归一化（仅比较用）：小写、去尾斜杠、无端口时补 scheme
// 默认端口（https→443 / http→80），使「带/不带默认端口」两种写法等值。非常规形态
// （带路径等）在小写、去尾斜杠后原样返回，比较退化为字符串相等，不会误判分叉。
function _norm_mgmt_url(u) {
    let s = lc(trim(u));
    while (length(s) > 1 && substr(s, length(s) - 1) == '/')
        s = substr(s, 0, length(s) - 1);
    let m = match(s, /^(https?):\/\/([^\/:]+)$/);
    if (m != null)
        return m[1] + '://' + m[2] + ':' + ((m[1] == 'https') ? '443' : '80');
    return s;
}

// _daemon_mgmt_url(bin) → daemon 当前持有的 management URL | null（status 非 JSON 态、
// daemon 未运行、字段缺失）。status --json 的 management.url 是 daemon 当前配置的实时
// 投影：status 请求处理时都会以持有配置刷新该字段，断连时不清空，故连不上管理端的
// 故障态下依然可读。
function _daemon_mgmt_url(bin) {
    let js = fetch_status_json(bin);
    if (!js.ok || js.data == null || js.data.management == null)
        return null;
    let u = js.data.management.url;
    return (type(u) == 'string' && length(u) > 0) ? u : null;
}

// ============================================================================
// 改动 2：管理 URL 展示来源 + Setup Key 打码 hint
// ============================================================================

// _mask_setup_key(key) → 打码串 | ''（OPNsense 风格：保留前 6 字符 + 其余补 '*' 到原长）。
//
// 安全说明（关键，写进代码以记录设计意图）：
//   安全基线：完整 setup_key 绝不入 UCI/backup/sysupgrade。本函数产出的 hint 是
//   一次性、已被 netbird up 消费掉的 key 的部分前缀（仅 6 字符可见，其余打码）。
//   setup_key 是 UUID（122bit 熵）；泄露前 6 个 hex 字符约暴露 24bit，且对应的 key 已
//   被消费（一次性，连接成功后管理端不再接受同 key 重注册）→ 不可利用。故 hint 非机密，
//   可存 UCI 供「上次使用」展示。绝不存原始 key、绝不回传原始 key。
function _mask_setup_key(key) {
    if (type(key) != 'string' || length(key) == 0)
        return '';
    let n = length(key);
    let keep = n < 6 ? n : 6;   // 短于 6 字符则全保留（理论上不会发生，UUID 恒 36 字符）
    let masked = substr(key, 0, keep);
    for (let i = keep; i < n; i++)
        masked += '*';
    return masked;
}

// _persist_setup_key_hint(key) — 把 setup_key 的打码 hint 写入 UCI 并 commit。
// 仅在认证成功后调用；只存打码串，原始 key 不入 UCI（安全基线）。空 key 不写。
function _persist_setup_key_hint(key) {
    let hint = _mask_setup_key(key);
    if (length(hint) == 0)
        return;
    let c = uci.cursor();
    if (c.get('netbird', 'settings') == null)
        c.set('netbird', 'settings', 'netbird');
    c.set('netbird', 'settings', 'setup_key_hint', hint);
    c.commit('netbird');
}

// _persist_runtime_error(message) / _clear_runtime_error()
// runtime.last_error 只存脱敏后的最后一次认证/连接失败原因，供认证页刷新后仍可见。
function _persist_runtime_error(message) {
    let msg = (type(message) == 'string') ? trim(message) : '';
    if (length(msg) > 300)
        msg = substr(msg, 0, 300);
    let c = uci.cursor();
    if (c.get('netbird', 'runtime') == null)
        c.set('netbird', 'runtime', 'state');
    c.set('netbird', 'runtime', 'last_error', msg);
    c.commit('netbird');
}

function _clear_runtime_error() {
    _persist_runtime_error('');
}

// _set_desired_connected(bool)
// 用户意图:1=保持连接(允许 watchdog 自动恢复网络类断线),0=用户显式断开/认证 fatal。
function _set_desired_connected(want) {
    let c = uci.cursor();
    if (c.get('netbird', 'runtime') == null)
        c.set('netbird', 'runtime', 'state');
    c.set('netbird', 'runtime', 'desired_connected', want ? '1' : '0');
    c.commit('netbird');
}

// _mark_service_enabled() — 把 UCI service_enabled 置 '1' 并 commit（已是 '1' 则免写）。
// 用于 do_enable_and_start 成功后：用户从「认证」页点「启用并启动」也算把「设置」页主开关
// 打开，须同步 UCI，否则设置页「启用」复选框仍读到旧 '0' 显示未勾选（与实际服务态脱节）。
// 注：只写 UCI、不发 procd config.change 事件 → 不触发二次 apply（仅修正显示，无 down→up 抖动）。
function _mark_service_enabled() {
    let c = uci.cursor();
    if (c.get('netbird', 'settings') == null)
        c.set('netbird', 'settings', 'netbird');
    if (c.get('netbird', 'settings', 'service_enabled') == '1')
        return;
    c.set('netbird', 'settings', 'service_enabled', '1');
    c.commit('netbird');
}

// _mgmt_url_from_config() → string|''：从 /etc/netbird/config.json 只读重建管理 URL。
//
// 安全基线：config.json 只读，绝不写——本函数仅用于「展示」预填管理 URL（当 UCI 无值时）。
// config.json 的 ManagementURL 是对象 {Scheme, Host, ...}；URL = Scheme + "://" + Host。
// 路径不硬编码为唯一值：候选序探测（与上游默认一致），读失败/解析失败静默返 ''。
function _mgmt_url_from_config() {
    let candidates = [
        '/etc/netbird/config.json',      // -c flag 默认
        '/var/lib/netbird/config.json',  // 官方上游 Linux 默认
    ];
    let path = null;
    for (let p in candidates) {
        if (access(p, 'f')) { path = p; break; }
    }
    if (path == null)
        return '';
    // 只读：cat 文件（path 字面常量，无用户输入）；解析 ManagementURL 对象重建 URL。
    let fd = popen('cat ' + shell_quote(path) + ' 2>/dev/null', 'r'); // shell-audit-ok: path 字面常量经 shell_quote
    if (fd == null)
        return '';
    let raw = fd.read('all') || '';
    fd.close();
    if (length(raw) == 0)
        return '';
    try {
        let js = json(raw);
        let mu = (js != null) ? js.ManagementURL : null;
        if (mu != null && type(mu) == 'object' &&
            type(mu.Scheme) == 'string' && length(mu.Scheme) > 0 &&
            type(mu.Host) == 'string' && length(mu.Host) > 0)
            return mu.Scheme + '://' + mu.Host;
    } catch (e) {
        return '';  // 解析失败静默返空（前端回退 placeholder）
    }
    return '';
}

// _wipe_local_identity() → int：删除的本地身份文件数；-1 = 存在但删除失败。
// 身份配置路径因包与 netbird 版本而异：
//   - OpenWrt opkg 包 init 传 NB_CONFIG=/etc/netbird/config.json；
//   - 上游 Linux 默认 /var/lib/netbird/config.json；
//   - netbird 0.74+ profile 布局把身份放 NB_STATE_DIR/<profile>.json
//     （含 active_profile.json，apk 包 init 传 NB_STATE_DIR=/root/.config/netbird）。
// 优先解析 init 脚本实际声明的路径，再叠加已知默认路径兜底；全部幂等（不存在即跳过）。
// 仅供 do_logout local_only 分支（用户二次确认后的显式销毁）调用；调用前必须已停 daemon。
function _wipe_local_identity() {
    let candidates = [ '/etc/netbird/config.json', '/var/lib/netbird/config.json' ];
    let state_dirs = [ '/root/.config/netbird' ];
    let f = open('/etc/init.d/netbird', 'r');
    if (f) {
        let txt = f.read('all');
        f.close();
        let m = match(txt, /NB_CONFIG="([^"]+)"/);
        if (m) push(candidates, m[1]);
        m = match(txt, /NB_STATE_DIR="([^"]+)"/);
        if (m) push(state_dirs, m[1]);
    }
    for (let d in uniq(state_dirs)) {
        let entries = lsdir(d);
        if (entries)
            for (let e in entries)
                if (match(e, /\.json$/))
                    push(candidates, d + '/' + e);
    }
    let removed = 0;
    for (let p in uniq(candidates)) {
        if (!access(p, 'f'))
            continue;
        if (!unlink(p))
            return -1;
        removed++;
    }
    return removed;
}

// _resolve_display_mgmt_url() → string：展示用管理 URL（优先级 UCI → config.json → ''）。
function _resolve_display_mgmt_url() {
    let c = uci.cursor();
    let saved = c.get('netbird', 'settings', 'management_url');
    if (type(saved) == 'string' && length(saved) > 0)
        return saved;
    return _mgmt_url_from_config();
}

// _build_auth_cmd(bin, verb, mgmt_url, setup_key) → 拼好的命令字符串
// verb ∈ {'up','login'}。一律加 --no-browser（避免等 SSO 浏览器挂死）。
// 所有动态参数（mgmt_url / setup_key）经 shell_quote（防注入）。
// bin 来自 resolve_netbird_bin（运行时探测），同样 shell_quote。
// 长命令不加 5s timeout（业务层自己轮询控时）；2>&1 合并便于回传错误。
function _build_auth_cmd(bin, verb, mgmt_url, setup_key) {
    let cmd = shell_quote(bin) + ' ' + verb + ' --no-browser';
    if (mgmt_url != null && length(mgmt_url) > 0)
        cmd += ' --management-url ' + shell_quote(mgmt_url);
    if (setup_key != null && length(setup_key) > 0)
        cmd += ' --setup-key ' + shell_quote(setup_key);
    cmd += ' 2>&1';
    return cmd;
}

// _exec_long(cmd, max_bytes?) → { code, stdout }
// 长命令执行：popen 读全部输出，close 取退出码。仅供受控 wrapper 使用。
function _exec_long(cmd, max_bytes) {
    let fd = popen(cmd, 'r');
    if (fd == null)
        return { code: -1, stdout: 'popen failed' };
    let raw = fd.read('all') || '';
    if (max_bytes != null && length(raw) > max_bytes)
        raw = substr(raw, 0, max_bytes);
    let rc = fd.close();
    return { code: (rc == null ? -1 : rc), stdout: raw };
}

// _exec_auth_cmd(cmd, max_bytes?, secs?) → { code, stdout }
// 认证命令有界执行：NetBird 上游在无效 setup key 时可能 backoff 重试不返回，
// 这里用 shell 轮询杀掉 CLI 进程；随后业务层再读 daemon 日志归类并 netbird down。
// secs 缺省 25s（用户发起的认证需要足够窗口让 CLI/日志沉淀出可归因的错误）；
// 周期性重试的调用方（watchdog）可传更短墙钟——rpcd 对同一 ucode 脚本的并发调用
// 是串行的，本命令在跑时该对象的其余方法（状态页读取）全部排队，墙钟越长页面
// 阻塞越久；watchdog 天然有下一轮兜底，缩短单次尝试不损失恢复能力。
function _exec_auth_cmd(cmd, max_bytes, secs) {
    if (type(secs) != 'int' || secs <= 0)
        secs = 25;
    let wrapped = cmd + ' & __nbp=$!; __nbi=0; ' +
        'while [ $__nbi -lt ' + secs + ' ] && kill -0 $__nbp 2>/dev/null; do sleep 1; __nbi=$((__nbi+1)); done; ' +
        'if kill -0 $__nbp 2>/dev/null; then ' +
            'kill -TERM $__nbp 2>/dev/null; sleep 1; kill -KILL $__nbp 2>/dev/null; ' +
            'wait $__nbp 2>/dev/null; printf "\\nnetbird command timed out after ' + secs + 's\\n"; exit 124; ' +
        'fi; wait $__nbp; exit $?';
    return _exec_long(wrapped, max_bytes);
}

// _poll_connected(bin, rounds?) → { connected:bool, json:<dict|null> }
// 同步轮询 status --json 直至 management.connected==true：缺省 6 轮（正常上限 ~10s,
// 5 次 sleep 2s）；极端下每轮 status 各带 5s timeout，最坏可达 ~40s（前端 do_up 的
// RPC timeout 须覆盖此区间）。轮间 system('sleep 2') 退避（sleep 可用）。
// rounds 可调：周期性重试的调用方（watchdog）用更少轮数缩短单次尝试的阻塞窗口
// （同脚本 RPC 串行，轮询期间状态页读取全部排队）；即便本轮漏判「刚好连上」，
// watchdog 下一轮状态巡检（30s 内）也会收敛，不损失恢复能力。
// 安全基线：exec 返回后必须同步轮询确认，不信任 up/login 退出码本身。
function _poll_connected(bin, rounds) {
    if (type(rounds) != 'int' || rounds <= 0)
        rounds = 6;
    let last_json = null;
    for (let i = 0; i < rounds; i++) {
        let js = fetch_status_json(bin);
        if (js.ok) {
            last_json = js.data;
            let mgmt = (js.data != null && js.data.management != null) ? js.data.management : {};
            if (mgmt.connected)
                return { connected: true, json: js.data };
        }
        // 最后一轮不必再 sleep
        if (i < rounds - 1)
            system('sleep 2');
    }
    return { connected: false, json: last_json };
}

// _exec_short_verb(bin, verb) → { code, stdout }
// 短认证命令（down / deregister）：5s timeout 包装（与 _run_init 同模式，BusyBox 无 timeout 降级）；
// verb 是字面常量（调用方传 'down'/'deregister'），bin 经 shell_quote。
// timeout applet 探测复用 _RUN_INIT_HAS_TIMEOUT（同值，避免重复定义）。
function _exec_short_verb(bin, verb) {
    let base = shell_quote(bin) + ' ' + verb + ' 2>&1';
    let cmd = _to(base);
    let fd = popen(cmd, 'r'); // shell-audit-ok: bin 经 shell_quote，verb 为字面常量
    if (fd == null)
        return { code: -1, stdout: 'popen failed' };
    let raw = fd.read('all') || '';
    let rc = fd.close();
    return { code: (rc == null ? -1 : rc), stdout: substr(raw, 0, 512) };
}

// ============================================================================
// exit node 选择（list_exit_nodes / select_exit_node 共用）
// ============================================================================
// exit node 在客户端 = 管理端下发的 0.0.0.0/0（及配对 ::/0）网络路由；
// `networks list/select/deselect` 是官方桌面/移动端同款机制（`routes` 为其别名，
// 子命令自 0.35 起存在，覆盖 OpenWrt 24.10 官方源的 0.59.x 及以上）。
// 选择状态由 daemon 持久化（重启保留），不进 UCI —— 避免第二事实源与管理端漂移。

// _exec_networks(bin, verb, ids, append) → { code, stdout, truncated }
// verb ∈ {'list','select','deselect'} 由调用方传字面常量；ids 逐个 shell_quote,
// 且以 ` -- ` 分隔（cobra 的 flag 终止符,实测可让 `-` 开头的 id 安全透传为位置参数）。
// append=true 时 select 加 -a：附加式选择。不带 -a 的 select 会清空用户已选的
// 全部其他网络路由（上游 CLI 语义是"替换整个选择集"），绝不能用于单节点切换。
// 5s timeout 与 _exec_short_verb 同模式；输出上限 64KB,超限置 truncated（截断的
// 列表解析会误判 selected/丢条目,调用方必须报错而不是拿残缺结果继续）。
const _NETWORKS_OUT_MAX = 65536;
function _exec_networks(bin, verb, ids, append) {
    let base = shell_quote(bin) + ' networks ' + verb;
    if (append)
        base += ' -a';
    if (length(ids || []) > 0) {
        base += ' --';
        for (let id in ids)
            base += ' ' + shell_quote(id);
    }
    base += ' 2>&1';
    let fd = popen(_to(base), 'r'); // shell-audit-ok: bin/ids 经 shell_quote，verb/-a/-- 为字面常量
    if (fd == null)
        return { code: -1, stdout: 'popen failed', truncated: false };
    let raw = fd.read('all') || '';
    let rc = fd.close();
    return {
        code: (rc == null ? -1 : rc),
        stdout: substr(raw, 0, _NETWORKS_OUT_MAX),
        truncated: length(raw) > _NETWORKS_OUT_MAX,
    };
}

// _parse_networks_list(text) → array<{id, range, selected}>
// 解析 `networks list` 纯文本输出（该命令无 --json）。条目形如：
//   - ID: <id>
//     Network: <range>          （域名路由是 Domains: 行，无 Network 行 → range 留 ''）
//     Status: Selected|Not Selected
// "No networks available." → []。未知行（Resolved IPs 等）跳过。
function _parse_networks_list(text) {
    let out = [];
    let cur = null;
    for (let line in split(text || '', '\n')) {
        let m = match(line, /^[ \t]*-[ \t]+ID:[ \t]*(.+)$/);
        if (m) {
            cur = { id: trim(m[1]), range: '', selected: false };
            push(out, cur);
            continue;
        }
        if (cur == null)
            continue;
        m = match(line, /^[ \t]+Network:[ \t]*(.+)$/);
        if (m) {
            cur.range = trim(m[1]);
            continue;
        }
        m = match(line, /^[ \t]+Status:[ \t]*(.+)$/);
        if (m)
            cur.selected = (trim(m[1]) == 'Selected');
    }
    return out;
}

// _is_exit_range(range) — 0.0.0.0/0 或 ::/0 即 exit node；v4/v6 合并条目
// （"0.0.0.0/0, ::/0"）用子串匹配同样命中。域名路由 range 为 '' 不命中。
function _is_exit_range(range) {
    return index(range, '0.0.0.0/0') >= 0 || index(range, '::/0') >= 0;
}

// _collect_exit_nodes(bin) → { ok:true, exit_nodes } | { ok:false, message }
// list + 解析 + 过滤一步到位；exit_nodes 条目 { id, range, selected }。
// 排除 id 恰为 'all' 的条目:上游 CLI 把唯一参数 'all' 当"全选/全清"关键字
// （select 单参必为唯一参数;deselect 若只剩它一个会触发 DeselectAllRoutes,
// 连子网路由选择一并清空）,这类名字的路由无法经 CLI 单独操作,列出即误导。
// 截断的输出不解析:残缺条目会误判 selected 或整条丢失,宁可显式报错。
function _collect_exit_nodes(bin) {
    let r = _exec_networks(bin, 'list', null, false);
    if (r.code != 0)
        return { ok: false, message: trim(r.stdout) || 'netbird networks list failed' };
    if (r.truncated)
        return { ok: false, message: 'networks list output exceeds the size limit; too many networks to parse safely' };
    let nodes = [];
    for (let n in _parse_networks_list(r.stdout)) {
        if (_is_exit_range(n.range) && n.id != 'all')
            push(nodes, n);
    }
    return { ok: true, exit_nodes: nodes };
}

// ============================================================================
// 改动 1：netbird 守护进程日志读取（get_logs 数据源）
// ============================================================================
// netbird daemon 把客户端日志写到 client.log 文件（默认 /var/log/netbird/），不进
// syslog；格式 `<RFC3339> <LEVEL> [peer: <key>]?(可选) <源文件:行>: <消息>`，含真实
// peer 握手/relay/连接活动。文件大（~12MB），故 tail -n <limit> 只读尾部。
//
// 路径不硬编码为唯一值：候选列表逐一探测（env override → 默认 → 其他发行版常见位置），
// 命中第一个存在的即用。全不存在则回退 logread -e netbird（兼容日志走 syslog 的部署）。
//
// 安全：候选路径与命令均字面常量（无用户输入）；limit 由 caller clamp 为 1..1000 整数后
// 传入，参与命令拼接安全（防注入）。BusyBox 无 timeout（沿用 lib 降级，logread/tail
// 读文件后立即退出，无需 timeout）。

// _daemon_log_path() → string|null：探测 netbird 守护日志文件路径。
// 候选序：NB_LOG_PATH env → /var/log/netbird/client.log（默认）→ 其他常见位置。
function _daemon_log_path() {
    let env_path = getenv('NB_LOG_PATH');
    if (type(env_path) == 'string' && length(env_path) > 0 && access(env_path, 'f'))
        return env_path;
    let candidates = [
        '/var/log/netbird/client.log',   // 默认（0.72.4）
        '/var/log/netbird.log',          // 部分发行版扁平布局
        '/tmp/log/netbird/client.log',   // tmpfs 日志布局
    ];
    for (let p in candidates) {
        if (access(p, 'f'))
            return p;
    }
    return null;
}

// _split_nonempty(buf) → [行...]：按 \n 切并丢弃空行（含末尾 trailing \n）。
function _split_nonempty(buf) {
    let lines = [];
    if (buf == null || length(buf) == 0)
        return lines;
    for (let ln in split(buf, '\n')) {
        if (length(ln) > 0)
            push(lines, ln);
    }
    return lines;
}

// _read_daemon_logs(limit) → { lines:[...], source:'daemon'|'syslog', truncated:bool }
// limit 必须是 caller 已 clamp 的 1..1000 整数。
function _read_daemon_logs(limit) {
    let path = _daemon_log_path();
    if (path != null) {
        // tail -n <limit> 读尾部（文件大，绝不全读）；path 字面常量、limit 已 clamp 整数。
        // 2>/dev/null 吞 tail 自身错误（如临时权限问题），失败时 buf 为空走友好空态。
        let cmd = 'tail -n ' + limit + ' ' + shell_quote(path) + ' 2>/dev/null';
        let fd = popen(cmd, 'r'); // shell-audit-ok: path 经 shell_quote，limit 为 clamp 整数
        let buf = '';
        if (fd != null) {
            buf = fd.read('all') || '';
            fd.close();
        }
        // tail 已限到 limit 行；truncated 表示文件还有更早的日志被截掉（行数恰为 limit 时近似判定）。
        let lines = _split_nonempty(buf);
        return { lines: lines, source: 'daemon', truncated: length(lines) >= limit };
    }

    // 回退：logread -e netbird（日志走 syslog 的部署）。读环形缓冲后立即退出，无需 timeout。
    let cmd = 'logread -e netbird 2>/dev/null';
    let fd = popen(cmd, 'r'); // shell-audit-ok: cmd 为纯字面量，无变量插值
    let buf = '';
    if (fd != null) {
        buf = fd.read('all') || '';
        fd.close();
    }
    return { lines: _split_nonempty(buf), source: 'syslog', truncated: false };
}

// _line_mentions_auth_problem(line) → bool：只挑 NetBird 认证/注册相关日志。
function _line_mentions_auth_problem(line) {
    if (line == null || length(line) == 0)
        return false;
    return !!match(line, /setup key|peer auth method|PermissionDenied|Unauthenticated|code\s*=\s*NotFound|couldn't add peer|login has expired|peer not found|removed from network/i);
}

// _recent_auth_log_text() → { text, hits }
// 仅用于 do_up/do_login 失败归因。要求日志命中数达到阈值才按日志判定，降低旧日志误报。
function _recent_auth_log_text() {
    let src = _read_daemon_logs(100);
    let text = '';
    let hits = 0;
    for (let line in (src.lines || [])) {
        if (_line_mentions_auth_problem(line)) {
            hits++;
            text += line + '\n';
        }
    }
    // 不按字节尾截断:源已限 100 行,过滤后认证行很少;尾截断会破坏
    // _auth_failure_from_attempt 的"本次新增行"差分,保留完整文本。
    return { text: text, hits: hits };
}

function _count_auth_hits(text) {
    let hits = 0;
    for (let line in split(text || '', '\n')) {
        if (_line_mentions_auth_problem(line))
            hits++;
    }
    return hits;
}

// _classify_auth_failure(text) → { message, hint } | null
// 按 NetBird CLI/daemon 原生错误语义归类；不伪造“未知错误”。
function _classify_auth_failure(text) {
    if (text == null || length(text) == 0)
        return null;

    if (match(text, /setup key is invalid|invalid setup key|setup key.*(expired|revoked|disabled|usage limit|not found|already used)|couldn't add peer:\s*setup key/i)) {
        return {
            message: 'Authentication failed: the setup key was rejected by the NetBird management server.',
            hint: 'NetBird was stopped to avoid retrying forever. Generate a new setup key and connect again.',
        };
    }

    if (match(text, /no peer auth method provided|please use a setup key|setup key.*missing/i)) {
        return {
            message: 'Authentication failed: NetBird did not receive a valid setup key.',
            hint: 'NetBird was stopped to avoid retrying forever. Enter a new setup key and connect — re-registering does not require deregistering first, even if the server was rebuilt or this device was removed there.',
        };
    }

    if (match(text, /peer login has expired|login has expired|peer not found|not registered|removed from network|peer.*(removed|deleted)/i)) {
        return {
            message: 'Authentication failed: this peer is no longer accepted by the management server.',
            hint: 'NetBird was stopped to avoid retrying forever. Generate a new setup key and connect again — no need to deregister first; this also recovers a device orphaned by a rebuilt management server.',
        };
    }

    if (match(text, /code\s*=\s*(PermissionDenied|Unauthenticated|NotFound)|rpc error:\s*code\s*=\s*(PermissionDenied|Unauthenticated|NotFound)/i)) {
        return {
            message: 'Authentication failed: the management server rejected this peer.',
            hint: 'NetBird was stopped to avoid retrying forever. Check whether the setup key is valid or whether this device was removed from NetBird.',
        };
    }

    return null;
}

// _auth_failure_from_attempt(stdout, before_text) → { message, hint } | null
// CLI 输出直接命中立即采信；日志只看本次尝试后新增的认证片段，避免旧错误污染。
function _auth_failure_from_attempt(stdout, before_text) {
    let direct = _classify_auth_failure(stdout || '');
    if (direct != null)
        return direct;

    // 只看本次尝试"新增"的认证日志行:对 before/after 按行做多重集合差。
    // 旧实现用字节前缀差分,在认证日志撑爆 4096B 尾截断窗口时会失效、回退全量分类,
    // 导致陈旧 fatal 行污染本次归因。集合差对截断/乱序稳健:before 出现过的行逐条抵消,
    // 仅把"超出 before 计数"的行算作本次新增(重复行的真新增仍能识别)。
    let after_text = _recent_auth_log_text().text;
    let before_count = {};
    for (let l in split(before_text || '', '\n')) {
        if (length(l) == 0)
            continue;
        before_count[l] = (before_count[l] != null ? before_count[l] : 0) + 1;
    }
    let new_text = '';
    for (let l in split(after_text || '', '\n')) {
        if (length(l) == 0)
            continue;
        if (before_count[l] != null && before_count[l] > 0)
            before_count[l] = before_count[l] - 1;
        else
            new_text += l + '\n';
    }
    if (_count_auth_hits(new_text) >= 1)
        return _classify_auth_failure(new_text);
    return null;
}

function _recent_log_text(limit) {
    let src = _read_daemon_logs(limit || 80);
    let text = '';
    for (let line in (src.lines || []))
        text += line + '\n';
    if (length(text) > 4096)
        text = substr(text, length(text) - 4096);
    return text;
}

function _classify_transient_connect_failure(text) {
    if (text == null || length(text) == 0)
        return null;
    if (match(text, /Unavailable|DeadlineExceeded|connection refused|i\/o timeout|network is unreachable|no such host|temporary failure|TLS handshake timeout|context deadline exceeded|keepalive ping failed|transport is closing|connection reset|timeout after/i)) {
        return {
            message: 'The management server is temporarily unreachable.',
            hint: 'Automatic reconnect will keep trying while the desired state is connected.',
        };
    }
    return null;
}

// ============================================================================
// OpenWRT 防火墙自动化辅助（setup_firewall_zone / setup_forwarding /
//     get_automation_status / teardown_automation）—— zone 直接绑定 netbird 设备
// ============================================================================
//
// zone 设备直绑设计（根治远程锁死/wt0 flush）：**不再为 netbird 自管设备创建 OpenWRT
// network 接口**。firewall zone `netbird` 直接 `list device '<iface>'`（iface=设置接口名,
// 默认 wt0）绑定 → 只 reload firewall、绝不 reload network → 零 flush、零中断、零远程锁死。
// 旧设计创建 `network.netbird`(proto=none)+ reload network 会让 netifd flush 掉 netbird
// daemon 写的 overlay IP/对端子网路由,且 netbird 不自愈（只有 restart 能恢复）。
//
// 安全红线（贯穿各方法）：
//   - 只增不改不删既有：本模块仅写 named section `firewall.netbird` (zone) 与
//     `firewall.lan_to_netbird` / `firewall.netbird_to_lan` (forwarding)。
//     绝不触碰 lan / wan / 任何其他 zone / 其他 forwarding / 匿名 section。
//     （teardown 另含对旧版残留 `network.netbird` 接口的防御性清理,见该函数。）
//   - forwarding 默认全关（opt-in）：setup_firewall_zone **不写任何 forwarding**；
//     仅 setup_forwarding 在 caller 显式传 true 时创建对应那一条。
//   - 幂等：各方法均用固定 named section 作幂等键，重复调用结果一致、不产生重复 section。
//
// 设计：自动化拆分；interface_name 不硬编码。

// 固定 named section 名（幂等键）。zone/forwarding 用 named section 而非匿名，
// 这样存在性判定 = c.get(config, name) 是否为对应 type，增删无需扫描匹配。
// _NB_IFACE_SECTION 在 zone 设备直绑设计下不再创建,仅 teardown 的旧版残留清理引用它。
const _NB_IFACE_SECTION = 'netbird';        // /etc/config/network  config interface 'netbird'（旧版残留）
const _NB_ZONE_SECTION  = 'netbird';        // /etc/config/firewall config zone 'netbird'
const _NB_FWD_L2N       = 'lan_to_netbird'; // src=lan  dest=netbird
const _NB_FWD_N2L       = 'netbird_to_lan'; // src=netbird dest=lan

// _nb_interface_name() — 从 UCI 读 netbird.settings.interface_name，默认 wt0。
// 经接口名格式校验（与 settings.js 同规则：首字母 + [a-zA-Z0-9_-]，长 1..15）；
// 非法（被篡改的 UCI）降级回 wt0，避免把垃圾写进 network.device。
function _nb_interface_name() {
    let c = uci.cursor();
    let v = c.get('netbird', 'settings', 'interface_name');
    if (type(v) != 'string' || length(v) == 0)
        return 'wt0';
    if (!match(v, /^[a-zA-Z][a-zA-Z0-9_-]{0,14}$/))
        return 'wt0';
    return v;
}

// _run_reload(which) — reload firewall（白名单，纯字面命令，5s timeout 降级）。
// 白名单**只含 firewall、故意不含 network**——本模块绝不 reload network
// （会 flush wt0 的 overlay IP/route 且 netbird 不自愈 → 远程锁死）。这把「不 reload network」
// 从约定升级为**代码强制**：任何误传 'network' 都会 die()，杜绝回归。
const _NB_RELOAD = { firewall: '/etc/init.d/firewall reload' };
function _run_reload(which) {
    let base = _NB_RELOAD[which];
    if (base == null)
        die(sprintf('_run_reload: illegal target "%s"', which));  // caller bug 立即崩（含误传 network）
    let cmd = _to(base + ' 2>&1');
    let fd = popen(cmd, 'r'); // shell-audit-ok: cmd 由 _NB_RELOAD 白名单字面量拼接，which 经 die() 断言
    if (fd == null)
        return false;
    fd.read('all');
    let rc = fd.close();
    return (rc == 0 || rc == null);  // reload 失败不阻断业务（写已 commit），仅影响即时生效
}

// _fwd_exists(c, name, want_src, want_dest) — 判定 named forwarding 是否为我们这条
// 特定 (src,dest) 组合。仅当 type=forwarding 且 src/dest 双匹配才算「我们的」，
// 防止误删/误判被复用为同名的他人 section。
function _fwd_exists(c, name, want_src, want_dest) {
    if (c.get('firewall', name) != 'forwarding')
        return false;
    return c.get('firewall', name, 'src') == want_src &&
           c.get('firewall', name, 'dest') == want_dest;
}

// _ensure_forwarding(c, name, src, dest) — 幂等确保某条 forwarding 存在（不 commit）。
// 返回 'created' | 'unchanged'。section 不存在则创建并 set type；已是我们这条则不动。
function _ensure_forwarding(c, name, src, dest) {
    if (_fwd_exists(c, name, src, dest))
        return 'unchanged';
    c.set('firewall', name, 'forwarding');
    c.set('firewall', name, 'src', src);
    c.set('firewall', name, 'dest', dest);
    return 'created';
}

// _remove_forwarding(c, name, src, dest) — 幂等删除我们这条 forwarding（不 commit）。
// 仅当确认是我们这条特定 (src,dest) 才删，绝不碰别的 forwarding（如默认 lan→wan）。
// 返回 'removed' | 'absent'。
function _remove_forwarding(c, name, src, dest) {
    if (!_fwd_exists(c, name, src, dest))
        return 'absent';
    c.delete('firewall', name);
    return 'removed';
}

// setup_firewall_zone — 幂等创建/更新 firewall zone 'netbird'（zone 直接绑定 netbird 设备）。
// input/output/forward=ACCEPT、masq=1、mtu_fix=1、`list device '<iface>'`（iface=设置
// 接口名,默认 wt0,经格式校验;不写死）。**不再 option network**（不创建 network.netbird
// 接口）→ 只 reload firewall、绝不 reload network → 零 flush（根治远程锁死）。
// fw4 用 iifname/oifname '<iface>' 按名匹配（设备未建也能先挂规则）。
// **不写任何 forwarding**（forwarding 默认全关,由 setup_forwarding opt-in）。绝不触碰
// lan/wan 等既有 zone。幂等：固定 named section,重复调用结果一致。
function _do_setup_firewall_zone() {
    let iface = _nb_interface_name();
    let c = uci.cursor();
    let existed = (c.get('firewall', _NB_ZONE_SECTION) == 'zone');

    c.set('firewall', _NB_ZONE_SECTION, 'zone');
    c.set('firewall', _NB_ZONE_SECTION, 'name', 'netbird');
    c.set('firewall', _NB_ZONE_SECTION, 'input', 'ACCEPT');
    c.set('firewall', _NB_ZONE_SECTION, 'output', 'ACCEPT');
    c.set('firewall', _NB_ZONE_SECTION, 'forward', 'ACCEPT');
    c.set('firewall', _NB_ZONE_SECTION, 'masq', '1');
    c.set('firewall', _NB_ZONE_SECTION, 'mtu_fix', '1');
    // zone 直接 `list device '<iface>'` 绑定 netbird 自管设备。
    c.set('firewall', _NB_ZONE_SECTION, 'device', [ iface ]);
    // 清理旧版（option network 绑定）升级残留：删 network 选项,避免悬空引用已不存在的
    // network.netbird 接口 section（删不存在 = no-op）。
    c.delete('firewall', _NB_ZONE_SECTION, 'network');
    c.commit('firewall');
    let reloaded = _run_reload('firewall');

    return ok({
        created: !existed,
        updated: existed,
        zone: 'netbird',
        device: iface,
        reload_ok: reloaded,   // false = UCI 已写但 fw4 即时重载失败(下次 reload/重启仍生效)
    });
}

// _netbird_route_cidrs() — 经 netbird 设备路由的"具体"子网 CIDR 列表(overlay + 对端子网,
// IPv4 + IPv6,**前缀 ≥ /8**,排除 IPv6 链路本地 fe80)。两处 conntrack flush 的共用发现逻辑
// (DRY:避免"只发现 overlay、漏对端子网/IPv6"的漂移——正是该缺陷的根因)。
// 动态读路由表,不硬编码网段(改设备名/换网段/IPv6 自动适配)。
// 安全下限 /8(安全红线):exit-node 模式 netbird 可能把默认/近默认路由(/0~/7,如 0.0.0.0/0//2、
// ::/0)指向本设备,flush 这些会变相(近)全表 flush(误冲 LAN/WAN/SSH/管理流);netbird overlay
// (100.x /10~/16)与对端子网(/8~/32)都 ≥8,故 /8 floor 只挡近默认、不误伤具体子网。/0 默认在
// `ip route` 显示为 "default" 关键字本就不匹配 CIDR 正则;multicast/local 等关键字开头行同样天然跳过。
// 返回数组,每项 { cidr, v6 }。ucode 不 hoist:本 helper + _ct_delete 定义在两个 flush 调用方之前。
function _netbird_route_cidrs() {
    let dev = _nb_interface_name();
    if (dev == null || length(dev) == 0)
        return [];
    let qdev = shell_quote(dev);
    let out = [];
    let fd = popen('ip route show table all dev ' + qdev + ' 2>/dev/null', 'r');
    if (fd != null) {
        let s = fd.read('all') || ''; fd.close();
        for (let line in split(s, '\n')) {
            let m = match(trim(line), /^([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)\/([0-9]+)/);
            if (m && (m[2] * 1) >= 8)
                push(out, { cidr: m[1] + '/' + m[2], v6: false });
        }
    }
    fd = popen('ip -6 route show table all dev ' + qdev + ' 2>/dev/null', 'r');   // IPv6 需 -6
    if (fd != null) {
        let s = fd.read('all') || ''; fd.close();
        for (let line in split(s, '\n')) {
            let t = trim(line);
            if (match(t, /^fe80/i))
                continue;
            let m = match(t, /^([0-9a-fA-F:]+)\/([0-9]+)/);
            if (m && (m[2] * 1) >= 8)
                push(out, { cidr: m[1] + '/' + m[2], v6: true });
        }
    }
    return out;
}

// _ct_delete(cidr, v6, flag) — best-effort 删 conntrack(flag '-d' 按目的 / '-s' 按源;v6 加 -f ipv6)。
function _ct_delete(cidr, v6, flag) {
    let fam = v6 ? '-f ipv6 ' : '';
    system('conntrack -D ' + fam + flag + ' ' + shell_quote(cidr) + ' >/dev/null 2>&1');
}

// _flush_netbird_conntrack(mode) — 取消某向 forwarding 后,定向冲掉该向已建 conntrack 流。
// 背景:fw4 删某向规则后**新**流被 drop,但 `ct established,related
// accept` 让**已建**流继续(用户连续 ping 时取消勾选,旧流不断,误以为「开关无效」)。删某向时定向
// `conntrack -D` 冲该向流。mode 'l2n' 冲 LAN→mesh(按目的 -d:原始目的是 mesh 子网);'n2l' 冲
// mesh→LAN(按源 -s:原始源是 mesh 子网)。
// **修正:冲 _netbird_route_cidrs() 全部子网(overlay + 对端子网 + IPv6),
// 不再只冲 overlay**——原只冲 overlay(100.x),漏了对端子网(如 10.20.1.0/24),致"取消 LAN→NetBird
// 转发对端子网的已建流不被冲、需重连才生效"(如 ping 10.20.1.3 取消后仍通)。best-effort:缺
// conntrack 工具则跳过。
function _flush_netbird_conntrack(mode) {
    if (!access('/usr/sbin/conntrack', 'x') && !access('/usr/bin/conntrack', 'x'))
        return;
    let flag = (mode == 'l2n') ? '-d' : '-s';
    for (let r in _netbird_route_cidrs())
        _ct_delete(r.cidr, r.v6, flag);
}

// _flush_reconnect_conntrack() — do_up 重连成功后,等 netbird 把对端子网路由装回来,再 flush 掉经
// netbird 设备路由的在途 conntrack(**两向都冲**:在途流可能是 LAN→mesh 或 mesh→LAN),强制按恢复
// 后的路由重建。背景:netbird down→up 后那几秒对端子网路由(独立策略表 7120)尚未恢复,
// 在途持续转发流被 conntrack 钉死在错误路由(落 br-lan)且持续流量保活永不过期 → 不自愈直到 flush。
// zone 设备直绑(不建 network 接口)去掉 netifd 接口,连带去掉了接口 flap 时 netifd 的自动 conntrack flush,使此问题暴露。
// 守安全红线见 _netbird_route_cidrs(只 flush ≥/8 具体子网,绝不全表)。仅 netbird zone 已建时执行。
function _flush_reconnect_conntrack() {
    if (!access('/usr/sbin/conntrack', 'x') && !access('/usr/bin/conntrack', 'x'))
        return;
    let c = uci.cursor();
    if (c.get('firewall', _NB_ZONE_SECTION) != 'zone')
        return;  // 未做 netbird 转发集成:无转发流,免轮询延时
    // 等对端子网路由恢复:轮询直到具体子网 ≥2 条(overlay + ≥1 对端子网),或 ~8s 超时。
    // 过早 flush 会被在途流重新钉到错路由(路由滞后)。
    let cidrs = [];
    for (let i = 0; i < 8; i++) {
        cidrs = _netbird_route_cidrs();
        if (length(cidrs) >= 2)
            break;
        system('sleep 1');
    }
    for (let r in cidrs) {
        _ct_delete(r.cidr, r.v6, '-d');
        _ct_delete(r.cidr, r.v6, '-s');
    }
}

// setup_forwarding(args) — 幂等增删 lan↔netbird 两条 forwarding。
// args { lan_to_netbird:bool, netbird_to_lan:bool }：true→确保存在，false→删除我们这条。
// 仅操作 _NB_FWD_L2N / _NB_FWD_N2L 两条特定 (src,dest)；绝不碰别的 forwarding。
// 开转发时按需建前置 zone:启用任一向转发前,若 netbird zone 缺失则先幂等建好——
// 转发规则 src/dest 引用 fw4 zone(netbird),缺 zone 会写成**悬空引用而静默不生效**(评审核出的真断层)。
// _do_setup_firewall_zone 只 reload firewall(zone 设备绑定,无 network 接口),
// 故全程**不 reload network、零 flush**——开转发对 wt0 数据面零中断(根治远程锁死)。
function _do_setup_forwarding(req) {
    let a = (req != null && req.args != null) ? req.args : (req || {});
    let want_l2n = !!a.lan_to_netbird;
    let want_n2l = !!a.netbird_to_lan;

    // 启用转发前确保前置 zone(幂等复用 _do_setup_firewall_zone,自带 commit + reload firewall)。
    // 不再创建 network 接口,只需 zone(forwarding 引用它);zone 设备绑定 wt0,无 network reload。
    let auto_created_zone = false;
    if (want_l2n || want_n2l) {
        let cc = uci.cursor();
        if (cc.get('firewall', _NB_ZONE_SECTION) != 'zone') {
            _do_setup_firewall_zone();
            auto_created_zone = true;
        }
    }

    let c = uci.cursor();
    let r_l2n = want_l2n
        ? _ensure_forwarding(c, _NB_FWD_L2N, 'lan', 'netbird')
        : _remove_forwarding(c, _NB_FWD_L2N, 'lan', 'netbird');
    let r_n2l = want_n2l
        ? _ensure_forwarding(c, _NB_FWD_N2L, 'netbird', 'lan')
        : _remove_forwarding(c, _NB_FWD_N2L, 'netbird', 'lan');

    c.commit('firewall');
    let reloaded = _run_reload('firewall');

    // 删某向后定向冲该向已建 conntrack,让「取消勾选」对已建连接也即时生效(取消转发即时生效)。
    if (!want_l2n) _flush_netbird_conntrack('l2n');
    if (!want_n2l) _flush_netbird_conntrack('n2l');

    return ok({
        lan_to_netbird: want_l2n,
        netbird_to_lan: want_n2l,
        lan_to_netbird_action: r_l2n,
        netbird_to_lan_action: r_n2l,
        auto_created_zone: auto_created_zone,
        reload_ok: reloaded,
    });
}

// get_automation_status — 读当前装配态供 UI 显示（纯读，任何态 ok:true）。
// 报 zone_exists + zone_device（zone 绑定的设备名）+ 两向 forwarding bool。
// 不再有 interface 概念（zone 直接设备绑定,无 network.netbird 接口）。
function _do_get_automation_status() {
    let c = uci.cursor();
    let zone_exists = (c.get('firewall', _NB_ZONE_SECTION) == 'zone');
    let zone_device = '';
    if (zone_exists) {
        // device 是 list option：uci 返数组（取首元）或字符串（旧式单值）。
        let dev = c.get('firewall', _NB_ZONE_SECTION, 'device');
        if (type(dev) == 'array')
            zone_device = (length(dev) > 0) ? (dev[0] || '') : '';
        else if (type(dev) == 'string')
            zone_device = dev;
    }
    return ok({
        zone_exists: zone_exists,
        zone_device: zone_device,
        lan_to_netbird: _fwd_exists(c, _NB_FWD_L2N, 'lan', 'netbird'),
        netbird_to_lan: _fwd_exists(c, _NB_FWD_N2L, 'netbird', 'lan'),
    });
}

// teardown_automation — setup_* 的逆操作：幂等拆除 OpenWRT 对 netbird 的封装。
// 删 `firewall.lan_to_netbird` / `firewall.netbird_to_lan`（两条 forwarding）+ zone `netbird`。
// **只删这几个 named section，绝不碰 lan/wan/其他 zone/其他 forwarding/匿名 section**
// （与 setup_* 同一红线）。删的是「OpenWRT 对 wtX 的封装/分区」，**不杀 netbird daemon
// 自管的 wtX 内核网卡**（zone 删除只 reload firewall,撤规则,不动设备/IP/route）。
//
// 旧版残留清理（兼容旧 network 接口设计）：旧设计曾建 `network.netbird`(proto=none)接口,升级到
// zone 设备直绑后的 box 可能残留。本函数防御性删它(仅 type=interface);新装(纯 zone 设备直绑)无此 section = no-op。
// ⚠️ **故意不 reload network**：proto=none 接口删除 + reload network 会让
// netifd 释放它先前 adopt 的 wtX → admin-down 设备 + flush overlay IP/route → 断 netbird
// 数据面（netbird 不自愈）。只删 UCI + commit,wtX 运行态此刻零中断,留待下次自然 reload/reboot
// 由 netifd 协调。zone 设备直绑设计的 zone 不依赖该接口(设备直绑),删它不影响 zone/forwarding。
//
// 顺序（先删依赖方）：forwarding（引用 zone）→ zone → 旧版残留 interface。
// 幂等：每步均 type-guard，删不存在 = no-op。
function _do_teardown_automation() {
    let c = uci.cursor();

    // 1. 删两条 forwarding（仅我们这条特定 src/dest，_remove_forwarding 已 type-guard）
    let r_l2n = _remove_forwarding(c, _NB_FWD_L2N, 'lan', 'netbird');
    let r_n2l = _remove_forwarding(c, _NB_FWD_N2L, 'netbird', 'lan');

    // 2. 删 zone netbird（仅当确是 zone type，防误删被复用为同名的他人 section）
    let zone_existed = (c.get('firewall', _NB_ZONE_SECTION) == 'zone');
    if (zone_existed)
        c.delete('firewall', _NB_ZONE_SECTION);
    c.commit('firewall');

    // 3. 旧版残留：删 network.netbird 接口（仅当确是 interface type;**不 reload network**,见上）。
    let iface_existed = (c.get('network', _NB_IFACE_SECTION) == 'interface');
    if (iface_existed) {
        c.delete('network', _NB_IFACE_SECTION);
        c.commit('network');
    }

    // 只 reload firewall（撤 netbird zone 规则,安全相关;reload network 会断 netbird,故意不做）。
    let reloaded = _run_reload('firewall');

    return ok({
        interface_removed: iface_existed,   // 仅旧版残留 box 为 true
        zone_removed: zone_existed,
        lan_to_netbird_action: r_l2n,   // 'removed' | 'absent'
        netbird_to_lan_action: r_n2l,
        reload_ok: reloaded,
    });
}

// ============================================================================
// netbird 二进制管理（get_binary_info / update_binary）
// ============================================================================
//
// 用户意向：官方最新版为主、opkg 保底。get_binary_info 展示三方版本（运行中 /
// opkg 包元数据 / GitHub 最新稳定），update_binary 一键下载校验并原地替换二进制。
//
// 磁盘约束（务必遵守）：目标机 overlay 通常紧张（常见十几~几十 MB），官方二进制约 39MB。绝不在
// overlay 留二进制副本/备份（双份撑爆→二进制写坏→daemon 崩）。正确做法：
// tgz 下到 /tmp（tmpfs ~875MB）→ /tmp 解压 → 原地 `cp /tmp/netbird <bin>`
// （cp 先 truncate 目标释放旧空间再写，净增 0）→ 清 /tmp。备份只备到 /tmp。
//
// 安全：先 sha256 校验再安装，不符立即中止（绝不安装未校验二进制）。所有动态值
// （bin 路径 / 版本号 / arch / URL）经 shell_quote 或正则白名单后再拼接（防注入）。
// 版本号/arch 在拼 URL 前过严格正则，杜绝注入。

// netbird release 上游 linux 架构：386/amd64/arm64/armv6 + mips/mipsle/mips64/mips64le
// （各 hard/softfloat；无 armv7/riscv64/ppc64le。2026-06 核实 v0.72.4 资产）。
// 本 _arch_map 仅映射「release 自动选包」支持的 4 架构(amd64/arm64/386/armv6)：armv7 用
// armv6 二进制;mips 的浮点 ABI(hard/soft)无法由 uname -m 可靠判定,自动选包不覆盖——
// mips/riscv 等设备走「系统软件源」(feed 按本机架构分发,_native_emachine 校验)或自定义 URL
// (贴精确资产)。
// _arch_map(uname_m) → netbird arch | '' （未知架构返空，由调用方友好提示）
function _arch_map(m) {
    let map = {
        'x86_64':  'amd64',
        'amd64':   'amd64',
        'aarch64': 'arm64',
        'arm64':   'arm64',
        'i386':    '386',
        'i486':    '386',
        'i586':    '386',
        'i686':    '386',
        'x86':     '386',
        // 32-bit ARM：netbird 仅发布 armv6（向下兼容多数 armv7 设备）
        'armv7l':  'armv6',
        'armv6l':  'armv6',
        'armv5l':  'armv6',
        'arm':     'armv6',
    };
    return (m != null && map[m] != null) ? map[m] : '';
}

// _detect_arch() → { uname_m, arch }。uname -m 一次（无用户输入，纯字面命令）。
function _detect_arch() {
    let fd = popen('uname -m 2>/dev/null', 'r'); // shell-audit-ok: 纯字面常量
    let m = '';
    if (fd != null) {
        let raw = fd.read('all') || '';
        fd.close();
        m = trim(raw);
    }
    return { uname_m: m, arch: _arch_map(m) };
}

// _parse_version_output(s) → 'X.Y.Z' | '' ：从 `netbird version` 输出抽语义版本号。
// 0.72.4 的 stdout 即裸 "0.72.4"；亦容忍带前缀/后缀的形态（取首个 x.y.z）。
function _parse_version_output(s) {
    if (type(s) != 'string' || length(s) == 0)
        return '';
    let mm = match(s, /([0-9]+\.[0-9]+\.[0-9]+)/);
    return mm ? mm[1] : '';
}

// _running_version(bin) → 运行中 daemon 版本号 'X.Y.Z' | ''。
// 取序：status --json 顶层 daemonVersion → `netbird version` 解析 → ''。
// status --json 仅在能取到时用；BusyBox 无 timeout，version 短命令降级透传。
function _running_version(bin) {
    if (bin == null || length(bin) == 0)
        return '';
    let js = fetch_status_json(bin);
    if (js.ok && js.data != null && type(js.data.daemonVersion) == 'string' &&
        length(js.data.daemonVersion) > 0)
        return js.data.daemonVersion;
    // fallback：netbird version（bin 经 shell_quote；version 为字面常量）
    let base = shell_quote(bin) + ' version 2>&1';
    let cmd = _to(base);
    let fd = popen(cmd, 'r'); // shell-audit-ok: bin 经 shell_quote，version 字面
    if (fd == null)
        return '';
    let raw = fd.read('all') || '';
    fd.close();
    return _parse_version_output(raw);
}

const _NB_DL_STATUS = '/tmp/luci-netbird-binary-download.status';
const _NB_DL_CANCEL = '/tmp/luci-netbird-binary-download.cancel';
const _NB_DL_WORKER_LOG = '/tmp/luci-netbird-binary-download.worker.log';

// _progress_download_cmd(fetcher,out,secs,total) — 包装实际下载器,每秒写状态文件并响应取消。
// total 为 0/正数时写进度;null 表示仅复用原墙钟 watchdog,不污染当前下载进度状态。
function _progress_download_cmd(fetcher, out, secs, total) {
    let bounded = (secs != null && secs > 0);
    let emit = (total != null);
    let qout = shell_quote(out);
    let qstatus = shell_quote(_NB_DL_STATUS);
    let qcancel = shell_quote(_NB_DL_CANCEL);
    let qtotal = shell_quote((total != null && total > 0) ? `${total}` : '0');

    let write_progress =
        'now=$(date +%s); size=0; [ -f ' + qout + ' ] && size=$(wc -c < ' + qout + ' 2>/dev/null | tr -d " "); ' +
        'elapsed=$((now-started)); [ "$elapsed" -lt 1 ] && elapsed=1; speed=$((size/elapsed)); ' +
        '{ echo phase=downloading; echo started="$started"; echo updated="$now"; echo pid="$__dlp"; ' +
        'echo downloaded="$size"; echo total=' + qtotal + '; echo elapsed="$elapsed"; echo speed="$speed"; } > ' + qstatus;

    let final_progress =
        'now=$(date +%s); size=0; [ -f ' + qout + ' ] && size=$(wc -c < ' + qout + ' 2>/dev/null | tr -d " "); ' +
        'elapsed=$((now-started)); [ "$elapsed" -lt 1 ] && elapsed=1; speed=$((size/elapsed)); ';

    let cmd = fetcher + ' & __dlp=$!; started=$(date +%s); ';
    if (emit)
        cmd += write_progress + '; ';
    cmd += 'while kill -0 $__dlp 2>/dev/null; do ';
    if (emit)
        cmd += write_progress + '; ';
    cmd += 'if [ -f ' + qcancel + ' ]; then kill -9 $__dlp 2>/dev/null; wait $__dlp 2>/dev/null; ';
    if (emit)
        cmd += final_progress + '{ echo phase=canceled; echo started="$started"; echo updated="$now"; echo pid=; echo downloaded="$size"; echo total=' + qtotal + '; echo elapsed="$elapsed"; echo speed="$speed"; echo message="Download stopped by user."; } > ' + qstatus + '; ';
    cmd += 'exit 130; fi; ';
    if (bounded) {
        cmd += 'now=$(date +%s); elapsed=$((now-started)); if [ "$elapsed" -ge ' + secs + ' ]; then kill -9 $__dlp 2>/dev/null; wait $__dlp 2>/dev/null; ';
        if (emit)
            cmd += final_progress + '{ echo phase=failed; echo started="$started"; echo updated="$now"; echo pid=; echo downloaded="$size"; echo total=' + qtotal + '; echo elapsed="$elapsed"; echo speed="$speed"; echo message="Download timed out."; } > ' + qstatus + '; ';
        cmd += 'exit 124; fi; ';
    }
    cmd += 'sleep 1; done; wait $__dlp 2>/dev/null; rc=$?; ';
    if (emit)
        cmd += final_progress + 'if [ -f ' + qcancel + ' ]; then rc=130; phase=canceled; msg="Download stopped by user."; elif [ "$rc" -eq 0 ]; then phase=downloaded; msg="Download complete."; else phase=failed; msg="Download failed."; fi; ' +
               '{ echo phase="$phase"; echo started="$started"; echo updated="$now"; echo pid=; echo downloaded="$size"; echo total=' + qtotal + '; echo elapsed="$elapsed"; echo speed="$speed"; echo message="$msg"; } > ' + qstatus + '; ';
    cmd += 'exit $rc';
    return cmd;
}

function _download_headers(headers, kind) {
    let out = '';
    if (headers == null)
        return out;
    if (type(headers) != 'array')
        headers = [ headers ];
    for (let h in headers) {
        if (type(h) != 'string' || length(h) == 0)
            continue;
        if (kind == 'curl')
            out += ' -H ' + shell_quote(h);
        else
            out += ' --header=' + shell_quote(h);
    }
    return out;
}

// _dl_cmd(url, out, secs, progress_total, headers) → 拼下载命令(优先 curl,回落 uclient-fetch,再 BusyBox wget)。
// out 空串=输出到 stdout(读 body 用);非空=写入该文件。url/out 经 shell_quote(注入防线)。
// OWRT25 最小化镜像常无 curl,但有 uclient-fetch(HTTPS via libustream)——多下载器回落,
// 避免下载/检测功能在无 curl 系统上静默失效;不强加 curl 硬依赖(打包依赖留给用户决定)。
// 错误语义差异(uclient-fetch/wget 在 HTTP 错误时可能仍返 0)由下游校验(tar/ELF/version/JSON)兜底。
//
// secs>0 时保留墙钟上限(用于 API / 自动兜底);secs<=0 时手动下载不限总时长,由前端停止按钮取消。
// progress_total 非 null 时,包装下载器每秒写进度状态文件,供 LuCI 轮询展示速度/进度。
function _dl_cmd(url, out, secs, progress_total, headers) {
    let q = shell_quote(url);
    let to_file = (out != null && length(out) > 0);
    let bounded = (secs != null && secs > 0);
    if (access('/usr/bin/curl', 'x') || access('/bin/curl', 'x')) {
        let curl_to = bounded ? (' --max-time ' + secs) : ' --connect-timeout 20';
        let curl_headers = _download_headers(headers, 'curl');
        if (!to_file)
            return 'curl -fsSL' + curl_to + curl_headers + ' ' + q + ' 2>/dev/null';
        let fetcher = 'curl -fL' + curl_to + curl_headers + ' -o ' + shell_quote(out) + ' ' + q + ' 2>&1';
        if (progress_total != null)
            return _progress_download_cmd(fetcher, out, secs, progress_total);
        return fetcher;
    }
    let tool = (access('/bin/uclient-fetch', 'x') || access('/usr/bin/uclient-fetch', 'x')) ? 'uclient-fetch' : 'wget';
    let fetch_headers = _download_headers(headers, 'fetch');
    if (!to_file)
        return tool + ' -q -T ' + (bounded ? secs : 20) + fetch_headers + ' -O - ' + q + ' 2>/dev/null';
    let fetcher = tool + ' -q -T ' + (bounded ? secs : 20) + fetch_headers + ' -O ' + shell_quote(out) + ' ' + q + ' 2>&1';
    if (progress_total != null)
        return _progress_download_cmd(fetcher, out, secs, progress_total);
    if (!bounded)
        return fetcher;
    return fetcher + ' & __dlp=$!; __i=0; ' +
           'while [ $__i -lt ' + secs + ' ] && kill -0 $__dlp 2>/dev/null; do sleep 1; __i=$((__i+1)); done; ' +
           'kill -0 $__dlp 2>/dev/null && kill -9 $__dlp 2>/dev/null; ' +
           'wait $__dlp 2>/dev/null; exit $?';
}

// _latest_version() → GitHub 最新稳定版 'X.Y.Z' | ''（网络失败/解析失败返 ''，不报错）。
// 经 _dl_cmd 取 GitHub releases/latest 的 tag_name 去前导 v；下载器自带超时,无需 timeout applet。
function _latest_version() {
    let cmd = _dl_cmd('https://api.github.com/repos/netbirdio/netbird/releases/latest', '', 15);
    let fd = popen(cmd, 'r'); // shell-audit-ok: URL 字面常量,_dl_cmd 内对其 shell_quote
    if (fd == null)
        return '';
    let raw = fd.read('all') || '';
    fd.close();
    if (length(raw) == 0)
        return '';
    let tag = '';
    try {
        let js = json(raw);
        if (js != null && type(js.tag_name) == 'string')
            tag = js.tag_name;
    } catch (e) {
        return '';  // 解析失败静默返空（不报错，前端按「未知」展示）
    }
    // 去前导 v；只保留语义版本号形态，杜绝异常 tag 污染后续 URL 拼接
    return _parse_version_output(tag);
}

// _semver_re — 版本号严格白名单（拼 URL/文件名前校验，杜绝注入）。
const _SEMVER_RE = /^[0-9]+\.[0-9]+\.[0-9]+$/;
// _pkgver_re — luci-app-netbird 包版本白名单，形如 0.1.0-r2。
const _PKGVER_RE = /^[0-9]+\.[0-9]+\.[0-9]+-r[0-9]+$/;
// _arch_re — netbird 发布架构白名单。
const _ARCH_RE = /^(amd64|arm64|386|armv6)$/;

// _popen_simple(cmd) → { code, out }：跑命令读全部输出（合并流），返回退出码 + 输出。
// 供 update_binary 内部各步骤用；cmd 必须由调用方保证安全（字面或已 shell_quote）。
function _popen_simple(cmd) {
    let fd = popen(cmd, 'r');
    if (fd == null)
        return { code: -1, out: 'popen failed' };
    let raw = fd.read('all') || '';
    let rc = fd.close();
    return { code: (rc == null ? -1 : rc), out: raw };
}

function _github_asset_api_url(ver, filename) {
    if (!match(ver || '', _SEMVER_RE) || length(filename || '') == 0)
        return '';
    let api = 'https://api.github.com/repos/netbirdio/netbird/releases/tags/v' + ver;
    let r = _popen_simple(_dl_cmd(api, '', 15));
    if (r.code != 0 || length(r.out) == 0)
        return '';
    try {
        let js = json(r.out);
        for (let asset in (js.assets || [])) {
            if (asset.name == filename && asset.id != null)
                return 'https://api.github.com/repos/netbirdio/netbird/releases/assets/' + asset.id;
        }
    } catch (e) {
        return '';
    }
    return '';
}

// _daemon_running() → bool：daemon 是否仍在跑（procd 视角）。
// 走 probe_running_via_ubus（ubus call service list {"name":"netbird"} → instances[*].running），
// 与全局态判定同源。**不用 pgrep -f**：pgrep -f 会匹配到正在评估该命令的 shell 自身
// （其 cmdline 含 "netbird service run" 字面），导致永远误判 still-running。
function _daemon_running() {
    let r = probe_running_via_ubus();
    return !!(r != null && r.running);
}

// _wait_daemon_gone() → bool：stop 后轮询等 daemon 进程真正退出（释放二进制 inode），
// 上限 ~15s（15 × sleep 1）。返回 true=已退出可安全写入；false=超时仍在跑。
// BusyBox sleep 不接受小数秒，退避用整数 sleep 1。
function _wait_daemon_gone() {
    for (let i = 0; i < 15; i++) {
        if (!_daemon_running())
            return true;
        system('sleep 1');
    }
    return !_daemon_running();
}

// ── 二进制来源管理(release/opkg 共存 + symlink 切换)─────────────────────────────
// 设计:opkg 自带 /etc/init.d/netbird 硬编码 procd command /usr/bin/netbird,
// 切换 daemon 实际跑哪个二进制只能动该路径 → 采 symlink:
//   source=release → /usr/bin/netbird 为 symlink → _NB_REL_BIN(opkg 真二进制不被 release 覆盖)
//   source=opkg    → /usr/bin/netbird 为 opkg 真二进制(切回时从保留副本 _NB_OPKG_BAK 复原;**绝不** reinstall)
// OWRT25(apk)兼容:来源语义名仍叫 "opkg"(=「系统软件源」),底层 feed 查询/获取命令由
// _pkg_mgr() 在 opkg(≤24.10)与 apk(≥25)间分流;安全红线:绝不 apk add/del/fix 切二进制(会连带删 init.d)。
// release 存 _NB_REL_BIN(overlay 持久,uci-defaults 已追加进 sysupgrade.conf 保全)。
const _NB_OPKG_BIN = '/usr/bin/netbird';        // opkg/daemon 规范路径(procd command 硬编码)
const _NB_REL_DIR  = '/usr/share/netbird/bin';  // release 持久存储目录
const _NB_REL_BIN  = '/usr/share/netbird/bin/netbird-release';
const _NB_OPKG_BAK = '/usr/share/netbird/bin/netbird-opkg';   // adopt 保留的 opkg 真二进制副本(切回 opkg 用,免 feed)

// _file_version(path) → 该二进制文件自身版本 'X.Y.Z'|''(直接 `<path> version`,不走 daemon)。
function _file_version(path) {
    if (path == null || !access(path, 'x'))
        return '';
    let base = shell_quote(path) + ' version 2>/dev/null';
    let cmd = _to(base);
    let r = _popen_simple(cmd);
    return _parse_version_output(r.out);
}

// _arch_emachine(arch) → 该 netbird arch 对应 ELF e_machine 值(校验下载包架构用)。
function _arch_emachine(arch) {
    let m = { 'amd64': 0x3e, 'arm64': 0xb7, '386': 0x03, 'armv6': 0x28 };
    return (arch != null && m[arch] != null) ? m[arch] : -1;
}

// _elf_machine(path) → 读 ELF 头返回 e_machine 整数;非 ELF/读失败返 -1。
// ucode fs.open 二进制安全读前 20 字节(/usr/bin/netbird e_machine=62 amd64 正确;
// BusyBox od 不支持 -tu1 -N,故用 ucode 读)。
function _elf_machine(path) {
    let fd = open(path, 'r');
    if (fd == null)
        return -1;
    let buf = fd.read(20);
    fd.close();
    if (buf == null || length(buf) < 20)
        return -1;
    // ELF magic 0x7F 'E' 'L' 'F'
    if (ord(substr(buf, 0, 1)) != 0x7f || substr(buf, 1, 3) != 'ELF')
        return -1;
    // EI_DATA(offset 5):2=大端,余小端。e_machine 为 offset 18 的 2 字节。
    let be = (ord(substr(buf, 5, 1)) == 2);
    let b18 = ord(substr(buf, 18, 1));
    let b19 = ord(substr(buf, 19, 1));
    return be ? ((b18 << 8) | b19) : ((b19 << 8) | b18);
}

// _file_size_kb(path) → 文件大小 KB(向上取整);不存在/解析失败返 -1。
function _file_size_kb(path) {
    if (path == null || !access(path, 'f'))
        return -1;
    let r = _popen_simple('wc -c < ' + shell_quote(path) + ' 2>/dev/null');
    let n = trim(r.out);
    if (!match(n, /^[0-9]+$/))
        return -1;
    let bytes = int(n);
    return int((bytes + 1023) / 1024);
}

function _file_size_bytes(path) {
    if (path == null || !access(path, 'f'))
        return 0;
    let r = _popen_simple('wc -c < ' + shell_quote(path) + ' 2>/dev/null');
    let n = trim(r.out);
    return match(n, /^[0-9]+$/) ? int(n) : 0;
}

function _now_epoch() {
    let r = _popen_simple('date +%s 2>/dev/null');
    let n = trim(r.out);
    return match(n, /^[0-9]+$/) ? int(n) : 0;
}

function _http_content_length(url, headers) {
    if (!(access('/usr/bin/curl', 'x') || access('/bin/curl', 'x')))
        return 0;
    let r = _popen_simple('curl -fsIL --connect-timeout 10 --max-time 20' +
                          _download_headers(headers, 'curl') + ' ' + shell_quote(url) + ' 2>/dev/null');
    if (r.code != 0 || length(r.out) == 0)
        return 0;
    let out = 0;
    for (let ln in split(r.out, '\n')) {
        let mm = match(trim(ln), /^[Cc]ontent-[Ll]ength:\s*([0-9]+)/);
        if (mm)
            out = int(mm[1]);
    }
    return out;
}

function _progress_reset() {
    _popen_simple('rm -f ' + shell_quote(_NB_DL_STATUS) + ' ' + shell_quote(_NB_DL_CANCEL) + ' 2>/dev/null');
}

function _progress_status() {
    let r = _popen_simple('cat ' + shell_quote(_NB_DL_STATUS) + ' 2>/dev/null');
    let data = {
        active: false,
        phase: 'idle',
        message: '',
        downloaded: 0,
        total: 0,
        speed: 0,
        elapsed: 0,
        started: 0,
        updated: 0,
        pid: ''
    };
    for (let ln in split(r.out || '', '\n')) {
        let p = index(ln, '=');
        if (p <= 0)
            continue;
        let k = substr(ln, 0, p);
        let v = substr(ln, p + 1);
        if (k == 'phase' || k == 'message' || k == 'pid')
            data[k] = v;
        else if (k == 'downloaded' || k == 'total' || k == 'speed' || k == 'elapsed' || k == 'started' || k == 'updated')
            data[k] = match(v, /^[0-9]+$/) ? int(v) : 0;
    }
    data.active = (data.phase == 'preparing' || data.phase == 'downloading' ||
                   data.phase == 'verifying' || data.phase == 'extracting' ||
                   data.phase == 'installing' || data.phase == 'stopping');
    return data;
}

function _progress_phase(phase, message, path, total) {
    let now = _now_epoch();
    let prev = _progress_status();
    let started = prev.started > 0 ? prev.started : now;
    let downloaded = (path != null && length(path) > 0) ? _file_size_bytes(path) : prev.downloaded;
    let elapsed = (now > started) ? (now - started) : 0;
    let speed = (elapsed > 0 && downloaded > 0) ? int(downloaded / elapsed) : prev.speed;
    let t = (total != null && total > 0) ? total : prev.total;

    let lines = [
        'phase=' + phase,
        'message=' + message,
        'downloaded=' + downloaded,
        'total=' + t,
        'speed=' + speed,
        'elapsed=' + elapsed,
        'started=' + started,
        'updated=' + now,
        'pid='
    ];
    let cmd = ': > ' + shell_quote(_NB_DL_STATUS);
    for (let ln in lines)
        cmd += '; printf "%s\\n" ' + shell_quote(ln) + ' >> ' + shell_quote(_NB_DL_STATUS);
    _popen_simple(cmd + ' 2>/dev/null');
}

function _progress_canceled() {
    return access(_NB_DL_CANCEL, 'f');
}

function _do_get_binary_update_progress(req) {
    return ok(_progress_status());
}

function _do_cancel_binary_update(req) {
    let st = _progress_status();
    if (!st.active)
        return ok(st);
    _popen_simple('touch ' + shell_quote(_NB_DL_CANCEL) + ' 2>/dev/null');
    if (match(st.pid || '', /^[0-9]+$/))
        _popen_simple('kill -9 ' + st.pid + ' 2>/dev/null');
    _progress_phase('stopping', 'Stopping download...', '', st.total);
    return ok(_progress_status());
}

function _do_start_binary_update(req) {
    let st = _progress_status();
    if (st.active || access('/tmp/nb-binop.lock', 'f'))
        return err(CODE.INSTALL_FAILED, 'Another binary operation is in progress; please wait and try again.');

    let a = (req != null && req.args != null) ? req.args : (req || {});
    let args = {
        url: (type(a.url) == 'string') ? a.url : '',
        checksum: (type(a.checksum) == 'string') ? a.checksum : '',
        dl_timeout: 0
    };
    _progress_reset();
    _progress_phase('preparing', 'Preparing download...', '', 0);

    let expr =
        'let mod = loadfile("/usr/share/rpcd/ucode/netbird.uc")(); ' +
        'let svc = mod["luci.netbird"]; ' +
        'let r = svc.update_binary.call({ args: ' + sprintf('%J', args) + ' }); ' +
        'print(sprintf("%J\\n", r));';
    let cmd = 'NBLIB=' + shell_quote(_LIB) + ' ucode -e ' + shell_quote(expr) +
              ' > ' + shell_quote(_NB_DL_WORKER_LOG) + ' 2>&1 & echo $!';
    let r = _popen_simple(cmd);
    let pid = trim(r.out);
    if (!match(pid, /^[0-9]+$/)) {
        _progress_phase('failed', 'Could not start the download worker.', '', 0);
        return err(CODE.INSTALL_FAILED, 'Could not start the download worker.');
    }
    return ok({ started: true, pid: int(pid) });
}

// _active_binary_path() → /usr/bin/netbird 实际指向的二进制路径(symlink 则 readlink,否则自身)。
function _active_binary_path() {
    let r = _popen_simple('[ -L ' + shell_quote(_NB_OPKG_BIN) + ' ] && readlink ' +
                          shell_quote(_NB_OPKG_BIN) + ' 2>/dev/null || echo ' + shell_quote(_NB_OPKG_BIN));
    let t = trim(r.out);
    return (length(t) > 0) ? t : _NB_OPKG_BIN;
}

// _active_source() → 'release'|'opkg'|'custom':据 /usr/bin/netbird symlink 指向判定(三态)。
//   symlink → netbird-release   ⟹ release
//   symlink → netbird-v<ver>    ⟹ custom
//   real file(非 symlink)/其它  ⟹ opkg
// 用 shell test(避 ucode lstat API 版本差异)。
function _active_source() {
    let r = _popen_simple('[ -L ' + shell_quote(_NB_OPKG_BIN) + ' ] && readlink ' +
                          shell_quote(_NB_OPKG_BIN) + ' 2>/dev/null || true');
    let tgt = trim(r.out);
    if (length(tgt) == 0)
        return 'opkg';
    if (tgt == _NB_REL_BIN)
        return 'release';
    let cpfx = _NB_REL_DIR + '/netbird-v';
    if (length(tgt) > length(cpfx) && substr(tgt, 0, length(cpfx)) == cpfx)
        return 'custom';
    return 'opkg';
}

// _uci_binary(field, dflt) → 读 netbird_bin.binary.<field>(独立配置文件);缺省回 dflt。
function _uci_binary(field, dflt) {
    let c = uci.cursor();
    let v = c.get('netbird_bin', 'binary', field);
    return (v != null && v !== '') ? v : dflt;
}

// _pkg_mgr() → 'apk' | 'opkg':探测系统包管理器,决定 feed 查询/获取走哪套命令。
// OWRT25 起 apk(Alpine apk-tools)取代 opkg,且 apk 系统不再带 opkg → /usr/bin/apk 存在即判 apk;
// 否则 opkg(≤24.10)。来源用户态值/常量仍叫 "opkg"(语义=「系统软件源」),命令由本函数分流。
function _pkg_mgr() {
    return access('/usr/bin/apk', 'x') ? 'apk' : 'opkg';
}

const _NB_LUCI_FEED_ROOT = 'https://luci-app-netbird.okk.sh';

function _openwrt_release_string() {
    let fd = open('/etc/openwrt_release', 'r');
    if (fd == null)
        return '';
    let raw = fd.read('all') || '';
    fd.close();
    let m = match(raw, /DISTRIB_RELEASE=['"]?([^'"\n]+)/);
    return m ? m[1] : '';
}

function _openwrt_series() {
    let rel = _openwrt_release_string();
    // 22.03 / 23.05(均 opkg)与 24.10 共用 ipk 软件源:包 PKGARCH:=all 且运行依赖
    // (rpcd-mod-ucode/ucode/conntrack/netbird)在两者官方源齐备,直接映射同系列。
    // 22.03 是能运行本应用的最老系列——它是第一个带 ucode / rpcd-mod-ucode 的版本。
    // 注意旧系列官方源的 netbird 较旧(23.05 为 0.24.x、22.03 为 0.17.x,无 networks 子命令):
    // 基础连接/状态可用,exit node 需在「版本」页切换到官方 release 二进制(≥0.35)。
    // 版本串只取 `NN.MM` 前缀映射系列,后缀一概不管:分支 snapshot(如 GL.iNet 4.x
    // 固件自报的 `23.05-SNAPSHOT`)、rc 与正式版同分支同依赖,按同系列处理。
    // 安装脚本 feed.sh 的子串匹配本就接受这些形态,此处与其对齐。
    let m = match(rel, /^([0-9]+\.[0-9]+)/);
    if (m) {
        let series = m[1];
        if (series == '22.03' || series == '23.05' || series == '24.10')
            return '24.10';
        if (series == '25.12')
            return '25.12';
        return '';
    }
    // 主干 SNAPSHOT(无数字前缀):apk 系与 25.12 源同构,可用;opkg 系主干 snapshot
    // 属远古形态,依赖面未知,保持不支持(与 feed.sh 行为一致)。
    if (match(rel, /SNAPSHOT/))
        return _pkg_mgr() == 'apk' ? '25.12' : '';
    if (length(rel) == 0)
        return _pkg_mgr() == 'apk' ? '25.12' : '24.10';
    return '';
}

function _luci_feed_spec() {
    let series = _openwrt_series();
    if (series == '24.10')
        return { ok: true, series: series, feed_url: _NB_LUCI_FEED_ROOT + '/openwrt-24.10/all/netbird/', pkg_ext: 'ipk' };
    if (series == '25.12')
        return { ok: true, series: series, feed_url: _NB_LUCI_FEED_ROOT + '/openwrt-25.12/all/netbird/', pkg_ext: 'apk' };
    return { ok: false, series: '', feed_url: '', pkg_ext: '', message: 'Unsupported OpenWrt release: ' + (_openwrt_release_string() || 'unknown') };
}

function _pkgver_parts(v) {
    let m = match(v || '', /^([0-9]+)\.([0-9]+)\.([0-9]+)-r([0-9]+)$/);
    if (!m)
        return [];
    return [ int(m[1]), int(m[2]), int(m[3]), int(m[4]) ];
}

function _pkgver_cmp(a, b) {
    let aa = _pkgver_parts(a);
    let bb = _pkgver_parts(b);
    if (length(aa) != 4 || length(bb) != 4)
        return (a == b) ? 0 : (length(a || '') == 0 ? -1 : 0);
    for (let i = 0; i < 4; i++) {
        if (aa[i] < bb[i])
            return -1;
        if (aa[i] > bb[i])
            return 1;
    }
    return 0;
}

function _luci_pkg_filename(pkg, ver, ext) {
    if (!match(ver || '', _PKGVER_RE))
        return '';
    if (ext == 'ipk')
        return pkg + '_' + ver + '_all.ipk';
    if (ext == 'apk')
        return pkg + '-' + ver + '.apk';
    return '';
}

// _luci_i18n_installed() → 系统是否已装 luci-i18n-netbird-zh-cn(中文语言包)。
// 更新器据此决定是否连带升级语言包:已装才升(i18n 子包版本跟随主包,升级刷新 .lmo),
// 未装绝不引入——语言包装不装是用户在安装入口的选择(install.sh 不带 / install-zh.sh 带),
// 更新不得改变它;无条件安装会把中文重新注册进 LuCI 语言列表(zh 包 uci-defaults),#3。
// 查询只读本地包数据库,不联网;查询失败按未装处理(宁可跳过 i18n 升级,不误引入)。
function _luci_i18n_installed() {
    if (_pkg_mgr() == 'apk') {
        let r = _popen_simple('apk list --installed luci-i18n-netbird-zh-cn 2>/dev/null');
        return match(r.out || '', /(^|\n)luci-i18n-netbird-zh-cn-[0-9]/) != null;
    }
    let r = _popen_simple('opkg list-installed luci-i18n-netbird-zh-cn 2>/dev/null');
    return match(r.out || '', /(^|\n)luci-i18n-netbird-zh-cn\s+-\s+/) != null;
}

function _luci_app_update_info() {
    let spec = _luci_feed_spec();
    let local = get_opkg_versions().luci_app_netbird || '';
    let base = {
        local_version: local,
        latest_version: '',
        update_available: false,
        series: spec.series || '',
        feed_url: spec.feed_url || '',
        pkg_ext: spec.pkg_ext || '',
        main_package: '',
        i18n_package: '',
        pkg_mgr: _pkg_mgr()
    };
    if (!spec.ok)
        return { ok: false, code: CODE.INVALID_INPUT, message: spec.message, data: base };

    let r = _popen_simple(_dl_cmd(spec.feed_url + 'index.json', '', 20));
    if (r.code != 0 || length(r.out) == 0)
        return { ok: false, code: CODE.DOWNLOAD_FAILED, message: 'Could not fetch luci-app-netbird package index.', data: base };

    let idx;
    try {
        idx = json(r.out);
    } catch (e) {
        return { ok: false, code: CODE.PARSE_ERROR, message: 'Could not parse luci-app-netbird package index.', data: base };
    }
    let pkgs = (idx != null && idx.packages != null) ? idx.packages : {};
    let latest = pkgs['luci-app-netbird'] || '';
    let i18n = pkgs['luci-i18n-netbird-zh-cn'] || latest;
    if (!match(latest, _PKGVER_RE))
        return { ok: false, code: CODE.PARSE_ERROR, message: 'The package index does not contain a valid luci-app-netbird version.', data: base };

    base.latest_version = latest;
    base.update_available = (_pkgver_cmp(local, latest) < 0);
    base.main_package = _luci_pkg_filename('luci-app-netbird', latest, spec.pkg_ext);
    base.i18n_package = (_luci_i18n_installed() && match(i18n || '', _PKGVER_RE)) ? _luci_pkg_filename('luci-i18n-netbird-zh-cn', i18n, spec.pkg_ext) : '';
    return { ok: true, data: base };
}

function _do_check_luci_app_update(req) {
    let info = _luci_app_update_info();
    if (info.ok)
        return ok(info.data);
    return err(info.code, info.message);
}

function _do_update_luci_app(req) {
    let info = _luci_app_update_info();
    if (!info.ok)
        return err(info.code, info.message);
    let d = info.data;
    if (!d.update_available)
        return err(CODE.INVALID_INPUT, 'luci-app-netbird is already up to date.');
    if (length(d.main_package) == 0)
        return err(CODE.PARSE_ERROR, 'Could not determine luci-app-netbird package filename.');

    let mk = _popen_simple('mktemp -d /tmp/nb-luci-update.XXXXXX 2>/dev/null');
    let work = trim(mk.out);
    if (mk.code != 0 || length(work) == 0)
        work = '/tmp/nb-luci-update';
    _popen_simple('rm -rf ' + shell_quote(work) + ' 2>/dev/null && mkdir -p ' + shell_quote(work));

    let cleanup = function() { _popen_simple('rm -rf ' + shell_quote(work) + ' 2>/dev/null'); };
    let main_path = work + '/' + d.main_package;
    let main_dl = _popen_simple(_dl_cmd(d.feed_url + d.main_package, main_path, 120));
    if (main_dl.code != 0 || _file_size_kb(main_path) < 1) {
        cleanup();
        return err(CODE.DOWNLOAD_FAILED, 'Failed to download luci-app-netbird package: ' + substr(trim(main_dl.out), 0, 200));
    }

    let paths = [ main_path ];
    if (length(d.i18n_package) > 0) {
        let i18n_path = work + '/' + d.i18n_package;
        let i18n_dl = _popen_simple(_dl_cmd(d.feed_url + d.i18n_package, i18n_path, 120));
        if (i18n_dl.code != 0 || _file_size_kb(i18n_path) < 1) {
            cleanup();
            return err(CODE.DOWNLOAD_FAILED, 'Failed to download luci-app-netbird translation package: ' + substr(trim(i18n_dl.out), 0, 200));
        }
        push(paths, i18n_path);
    }

    let args = '';
    for (let p in paths)
        args += ' ' + shell_quote(p);
    let cmd;
    if (d.pkg_mgr == 'apk')
        cmd = 'apk add --allow-untrusted --upgrade' + args + ' 2>&1';
    else
        cmd = 'opkg install' + args + ' 2>&1';

    let inst = _popen_simple(cmd);
    cleanup();
    if (inst.code != 0)
        return err(CODE.INSTALL_FAILED, 'Failed to install luci-app-netbird package: ' + substr(trim(inst.out), 0, 300));

    let after = get_opkg_versions().luci_app_netbird || '';
    return ok({
        from: d.local_version,
        to: after || d.latest_version,
        latest_version: d.latest_version,
        feed_url: d.feed_url,
        pkg_mgr: d.pkg_mgr
    });
}

// _native_emachine() → 本机原生 ELF e_machine(读常驻原生可执行);全失败返 -1。
// 用途:校验 feed 取得的二进制架构。feed 包按本机架构分发,以「本机原生 ELF」为基准比对,
// 使 feed 路径天然支持任意架构(mips/mipsel/riscv64 …),不被 netbird release 仅 4 架构
// (amd64/arm64/386/armv6)的白名单卡死(多架构关键)。amd64 机上等同 0x3e,行为不变。
function _native_emachine() {
    for (let ref in ['/bin/busybox', '/bin/sh', '/sbin/init', '/usr/bin/ucode']) {
        let em = _elf_machine(ref);
        if (em > 0)
            return em;
    }
    return -1;
}

// _opkg_upgradable_netbird() → 系统软件源里 netbird 可升级到的版本 'X.Y.Z'|''(用缓存列表,不联网)。
// 命令按 _pkg_mgr() 分流(opkg list-upgradable / apk version)。
function _opkg_upgradable_netbird() {
    if (_pkg_mgr() == 'apk') {
        // apk version:两列 "Installed  <  Available";netbird 行 "netbird-<cur>  < <new>"。
        let r = _popen_simple('apk version 2>/dev/null'); // shell-audit-ok: 纯字面常量
        if (length(r.out) == 0)
            return '';
        let mm = match(r.out, /(^|\n)netbird-\S+\s+<\s+(\S+)/);
        return mm ? _parse_version_output(mm[2]) : '';
    }
    let r = _popen_simple('opkg list-upgradable 2>/dev/null'); // shell-audit-ok: 纯字面常量
    if (r.code != 0 || length(r.out) == 0)
        return '';
    // 行格式:"netbird - <cur> - <new>"
    let mm = match(r.out, /(^|\n)netbird\s+-\s+\S+\s+-\s+(\S+)/);
    return mm ? _parse_version_output(mm[2]) : '';
}

// ── 自定义多版本 + opkg feed 自动获取 helper(均在 _do_* 之前,因 ucode 不 hoist)──────────────

// _custom_version_path(ver) → 自定义下载版本存储路径 netbird-v<ver>(ver 须先 _sanitize_version)。
function _custom_version_path(ver) {
    return _NB_REL_DIR + '/netbird-v' + ver;
}

// _sanitize_version(v) → 仅允许 [0-9.] 的版本串(防文件名注入);非法/非串返 ''。
function _sanitize_version(v) {
    if (type(v) != 'string')
        return '';
    let t = trim(v);
    return match(t, /^[0-9]+(\.[0-9]+)*$/) ? t : '';
}

// _list_custom_versions() → 已下载的自定义版本 [{version, path}](扫 netbird-v*;无则空数组)。
function _list_custom_versions() {
    let r = _popen_simple('ls -1 ' + shell_quote(_NB_REL_DIR) + '/netbird-v* 2>/dev/null || true');
    let out = [];
    for (let ln in split(trim(r.out), '\n')) {
        ln = trim(ln);
        if (length(ln) == 0)
            continue;
        let parts = split(ln, '/');
        let base = parts[length(parts) - 1];
        let vm = match(base, /^netbird-v(.+)$/);
        // 只列**可执行且能自报版本**的完整文件:下载/解压半途失败留下的残片不是「已下载版本」,
        // 否则会以幽灵版本出现在列表、切换时却报 not downloaded(已知 bug)。
        if (vm && access(ln, 'x') && length(_file_version(ln)) > 0)
            push(out, { version: vm[1], path: ln });
    }
    return out;
}

// _overlay_free_kb() → _NB_REL_DIR 所在文件系统(overlay 持久存储)的可用空间 KB;取不到返 -1。
//   解析 `df -k` 末行:列序 [Filesystem] 1K-blocks Used Available Use% Mounted —— Available = 倒数第三(NF-2)。
//   按 NF-2 取兼容 BusyBox 长设备名换行(数据行 5 列)与不换行(6 列)两种排版。best-effort:解析失败返 -1
//   → 调用方跳过预检(下载仍由 step 9 的 ENOSPC 兜底),绝不因 df 差异误拦。
function _overlay_free_kb() {
    let r = _popen_simple('df -k ' + shell_quote(_NB_REL_DIR) + ' 2>/dev/null');
    if (length(trim(r.out)) == 0)
        return -1;
    let lines = split(trim(r.out), '\n');
    let toks = [];
    for (let t in split(lines[length(lines) - 1], /[ \t]+/))
        if (length(t) > 0)
            push(toks, t);
    let n = length(toks);
    if (n < 3)
        return -1;
    let avail = toks[n - 3];
    return match(avail, /^[0-9]+$/) ? int(avail) : -1;
}

// _opkg_feed_has_netbird() → 系统软件源是否提供 netbird 包(本地缓存列表,不联网)。命令按 _pkg_mgr() 分流。
function _opkg_feed_has_netbird() {
    if (_pkg_mgr() == 'apk') {
        // apk list netbird → "netbird-0.66.2-r1 x86_64 {feed} (lic)";匹配 netbird- 接数字(排除 netbird-ui 等)。
        let r = _popen_simple('apk list netbird 2>/dev/null || true'); // shell-audit-ok: 纯字面常量
        return !!match(r.out, /(^|\n)netbird-[0-9]/);
    }
    let r = _popen_simple('opkg list netbird 2>/dev/null || true'); // shell-audit-ok: 纯字面常量
    return !!match(r.out, /(^|\n)netbird\s+-\s+/);
}

// _fetch_opkg_binary() → **非破坏性**(绝不动包生命周期/init.d)从系统软件源获取 netbird 真二进制存到 _NB_OPKG_BAK。
//   opkg(≤24.10):opkg download 仅下载 .ipk(不安装/不 remove/不碰 init.d)→ 解 ./data.tar.gz
//     → 只解 ./usr/bin/netbird(绝不取 init.d 成员)。
//   apk(≥25):apk fetch 下载 .apk(非破坏性,走可信索引)→ apk extract --allow-untrusted 解整棵树
//     到子目录(.apk 非 BusyBox tar 可读;单包文件无系统可信签名,故 allow-untrusted),取 usr/bin/netbird。
//   随后统一:ELF arch(本机原生基准)+ version 校验 → 截断式 cat 到副本。
//   **绝不** opkg install/--force-reinstall、**绝不** apk add/del/fix——其 remove 阶段会删
//   /etc/init.d/netbird(包生命周期操作会连带删 init.d,故绝不走)。返回 { ok:bool, err:string, version:string }。
function _fetch_opkg_binary() {
    let det = _detect_arch();
    let arch = det.arch;
    let mgr = _pkg_mgr();
    let work = '/tmp/nb-opkg';
    let extracted;
    let cleanup = function() { _popen_simple('rm -rf ' + shell_quote(work) + ' 2>/dev/null'); };
    cleanup();
    _popen_simple('mkdir -p ' + shell_quote(work));

    let dl;
    if (mgr == 'apk') {
        // apk fetch → .apk(名 netbird-<ver>-r<rel>.apk)→ apk extract 整棵树到 work/x → 取 usr/bin/netbird
        extracted = work + '/x/usr/bin/netbird';
        // 注:apk extract --destination 要求目标目录**预先存在**(不自建),故先 mkdir work/x。
        dl = _popen_simple('cd ' + shell_quote(work) +
            ' && apk fetch netbird 2>&1' +
            ' && apkf=$(ls netbird-*.apk 2>/dev/null | head -1)' +
            ' && [ -n "$apkf" ]' +
            ' && mkdir -p ' + shell_quote(work + '/x') +
            ' && apk extract --allow-untrusted --destination ' + shell_quote(work + '/x') + ' "$apkf" 2>&1');
    } else {
        // opkg download → .ipk(名 netbird_*.ipk)→ 解 ./data.tar.gz → 只解二进制成员
        extracted = work + '/usr/bin/netbird';
        dl = _popen_simple('cd ' + shell_quote(work) +
            ' && opkg download netbird 2>&1' +
            ' && ipk=$(ls netbird_*.ipk 2>/dev/null | head -1)' +
            ' && [ -n "$ipk" ] && tar -xzf "$ipk" ./data.tar.gz 2>&1' +
            ' && tar -xzf data.tar.gz ./usr/bin/netbird 2>&1');
    }
    if (dl.code != 0 || !access(extracted, 'f')) {
        cleanup();
        return { ok: false, err: sprintf('%s fetch/extract error: %s', mgr, substr(trim(dl.out), 0, 200)), version: '' };
    }
    _popen_simple('chmod +x ' + shell_quote(extracted) + ' 2>/dev/null');
    // ELF arch 校验:以本机原生 ELF 为基准(feed 按本机架构分发,天然多架构);
    // 读不到本机 ELF 时回落 netbird 4 架构表;非合法 ELF 一律拒。
    let want_em = _native_emachine();
    if (want_em < 0)
        want_em = _arch_emachine(arch);
    let got_em = _elf_machine(extracted);
    if (got_em < 0 || (want_em > 0 && got_em != want_em)) {
        cleanup();
        return { ok: false, err: sprintf('feed binary arch mismatch (host e_machine=%d, package e_machine=%d)', want_em, got_em), version: '' };
    }
    let cv = _file_version(extracted);
    if (length(cv) == 0) {
        cleanup();
        return { ok: false, err: 'feed binary cannot run "version" (possibly corrupt)', version: '' };
    }
    // 截断式写副本(overlay 峰值 1×,避免双份撑爆 overlay)。整组 `{ …; } 2>&1` 收 stderr
    // (同 step 9:`2>&1` 不能只绑末尾 chmod,否则 cat 写失败如 ENOSPC 的报错丢失 → 错误明细空白)。
    let wr = _popen_simple('{ mkdir -p ' + shell_quote(_NB_REL_DIR) + ' && cat ' + shell_quote(extracted) +
                           ' > ' + shell_quote(_NB_OPKG_BAK) + ' && chmod 0755 ' + shell_quote(_NB_OPKG_BAK) + ' ; } 2>&1');
    cleanup();
    if (wr.code != 0 || !access(_NB_OPKG_BAK, 'x'))
        return { ok: false, err: 'could not save the feed copy: ' +
                 (length(trim(wr.out)) > 0 ? substr(trim(wr.out), 0, 200)
                                           : sprintf('write exited %d with no output (storage may be full)', wr.code)), version: '' };
    return { ok: true, err: '', version: cv };
}

// _do_get_binary_info(req) — 二进制来源概览(纯读,任何态 ok:true)。
// 默认只回本地信息(不联网);args.check_remote=true 才拉 GitHub latest + opkg upgradable(「检测更新」按钮,避限流)。
function _do_get_binary_info(req) {
    let a = (req != null && req.args != null) ? req.args : (req || {});
    let check_remote = !!a.check_remote;

    let det = _detect_arch();
    let opkg = get_opkg_versions();
    let active = _active_source();
    let active_bin = _active_binary_path();

    let rel_installed = access(_NB_REL_BIN, 'x');
    let rel_version = rel_installed ? _file_version(_NB_REL_BIN) : '';
    let running = _running_version(_NB_OPKG_BIN);

    // 自定义已下载版本列表(标记 active 版本)
    let custom_out = [];
    let active_custom_version = '';
    for (let cv in _list_custom_versions()) {
        let is_act = (active == 'custom' && active_bin == cv.path);
        if (is_act)
            active_custom_version = cv.version;
        push(custom_out, { version: cv.version, path: cv.path, active: is_act });
    }

    let opkg_copy = access(_NB_OPKG_BAK, 'x');

    let latest = '';
    let opkg_upgradable = '';
    if (check_remote) {
        latest = _latest_version();
        opkg_upgradable = _opkg_upgradable_netbird();
    }
    let update_available = (length(latest) > 0 && latest != rel_version);

    return ok({
        arch:              det.arch,
        uname_m:           det.uname_m,
        active_source:     active,
        configured_source: _uci_binary('binary_source', 'release'),
        running_version:   running,
        release: {
            installed: rel_installed,
            version:   rel_version,
            path:      _NB_REL_BIN,
        },
        opkg: {
            version: opkg.netbird || '',
            path:    _NB_OPKG_BIN,
            // 能否切到 opkg:有副本 / 当前已是 opkg / feed 提供(可 opkg download 自动获取,V4)。
            binary_available: (opkg_copy || active == 'opkg' || _opkg_feed_has_netbird()),
            copy_preserved:   opkg_copy,
        },
        custom: {
            versions:       custom_out,
            active_version: active_custom_version,
        },
        latest_version:   latest,
        opkg_upgradable:  opkg_upgradable,
        pkg_mgr:          _pkg_mgr(),
        update_available: update_available,
        release_url:      _uci_binary('release_url', ''),
        luci_app_version: opkg.luci_app_netbird || '',
    });
}


// ─── 二进制操作互斥(advisory lock)──────────────────────────────────────────────
// rpcd 本身串行处理 ubus 调用,但「客户端 ubus 超时后重试 / 多会话并发」等边界仍可能让两个
// 二进制操作交错。原子 mkdir 锁让第二个操作快速失败,而非交错破坏(下载/换 symlink/重启 daemon)。
// 锁目录在 /tmp(tmpfs):进程被硬杀残留也会随重启自然清除;_binop_guard 用 try/catch 保证异常
// 路径也释放锁。ucode 不 hoist:这三个 helper 定义在所有二进制 _do_* 之前。
const _NB_BINOP_LOCK = '/tmp/nb-binop.lock';
function _binop_lock() {
    let r = _popen_simple('mkdir ' + shell_quote(_NB_BINOP_LOCK) + ' 2>/dev/null && echo OK');
    return trim(r.out) == 'OK';
}
function _binop_unlock() {
    _popen_simple('rmdir ' + shell_quote(_NB_BINOP_LOCK) + ' 2>/dev/null');
}
// _sweep_binary_junk() — 清理历次二进制操作残留,防止累积撑爆存储(尤其 overlay)。
//   由 _binop_guard 在每次操作前调用(已持锁,无并发,安全)。删:
//     · /tmp/nb-update* /tmp/nb-opkg —— 下载/feed-fetch 工作目录(正常 cleanup 已删,这里兜底历史残留)
//     · _NB_REL_DIR 下**非可执行或不能自报版本**的 netbird-v* —— 下载/解压半途失败的残片(非有效版本)
//   绝不删:netbird-release / netbird-opkg / 当前 active custom / 能自报版本的 netbird-v*(用户数据)。
function _sweep_binary_junk() {
    _popen_simple('rm -rf /tmp/nb-update* /tmp/nb-opkg 2>/dev/null'); // shell-audit-ok: 纯字面常量
    let active_bin = _active_binary_path();
    let r = _popen_simple('ls -1 ' + shell_quote(_NB_REL_DIR) + '/netbird-v* 2>/dev/null || true');
    for (let ln in split(trim(r.out), '\n')) {
        ln = trim(ln);
        if (length(ln) == 0 || ln == active_bin)
            continue;
        if (!access(ln, 'x') || length(_file_version(ln)) == 0)
            _popen_simple('rm -f ' + shell_quote(ln) + ' 2>/dev/null');
    }
}
// _binop_guard(fn, req) — 取锁 → 清理历史残留 → 执行 fn → 释放锁(成功/异常路径都释放)。取不到锁返回忙错误。
function _binop_guard(fn, req) {
    if (!_binop_lock())
        return err(CODE.INSTALL_FAILED, 'Another binary operation is in progress; please wait and try again.');
    try {
        _sweep_binary_junk();
        let r = fn(req);
        _sweep_binary_junk();
        _binop_unlock();
        return r;
    } catch (e) {
        _sweep_binary_junk();
        _binop_unlock();
        return err(CODE.INTERNAL_ERROR, (e != null && e.message != null) ? e.message : `${e}`);
    }
}

// _update_binary_locked(req) — 下载官方/镜像 release 二进制,校验后装到 _NB_REL_BIN。
// 经 _do_update_binary 包一层 _binop_guard 互斥调用(见上)。
// args.url 非空=自定义镜像 URL(网络加速);空=GitHub releases/latest。
// **绝不**直接写 /usr/bin/netbird——只写 _NB_REL_BIN(release 存储位);是否生效由 set_binary_source
// 经 symlink 决定。决策树(失败忠实传播,尽量不让 box 处于无 netbird 可用态):
//   1. arch 解析过白名单 → arch_mismatch
//   2. 解析下载 URL+文件名:custom 用 args.url(校验 http/https);否则 GitHub latest 拼 URL
//   3. 下载 tarball 到 /tmp → download_failed
//   4. sha256 校验(有版本号则去 GitHub 抓对应 checksums;custom 镜像同版本亦可校验;无则跳过记 note)→ checksum_mismatch
//   5. 解压取 netbird 成员 → install_failed
//   6. **ELF 头校验 arch 匹配**(防坏包/错架构替换崩服务)→ arch_mismatch(绝不安装)
//   7. 解压件能执行 `version` → install_failed
//   8. 备份当前 _NB_REL_BIN → /tmp;若 active==release 须先 stop daemon(_NB_REL_BIN 正被执行,避 ETXTBSY)
//   9. 截断式写入 _NB_REL_BIN(cat>,overlay 峰值 ~1×,避免双份撑爆 overlay)→ chmod +x;验证;失败还原备份
//  10. active==release 则 start daemon 跑新版;清 work
function _update_binary_locked(req) {
    let a = (req != null && req.args != null) ? req.args : (req || {});
    let custom_url = (type(a.url) == 'string') ? trim(a.url) : '';
    let is_custom = (length(custom_url) > 0);
    // tarball 下载超时(秒):手动下载默认 0=不限总时长,仅由「停止下载」取消;首连自动兜底
    // (_ensure_configured_binary)传短值(避免阻塞连接过久;超时则回落 feed)。
    let dl_secs = (a.dl_timeout != null && a.dl_timeout > 0) ? a.dl_timeout : 0;
    _progress_reset();
    _progress_phase('preparing', 'Preparing download...', '', 0);
    let fail_pre = function(code, message) {
        _progress_phase('failed', message, '', 0);
        return err(code, message);
    };

    let det = _detect_arch();
    let arch = det.arch;
    // release 自动选包需 arch 命中 netbird 官方发布的 4 架构(amd64/arm64/386/armv6);
    // 自定义 URL 不限架构(用户贴精确资产 → 支持 mips/mipsle/riscv 等),仅 step 6 以本机原生 ELF 校验。
    if (!is_custom && (length(arch) == 0 || !match(arch, _ARCH_RE)))
        return fail_pre(CODE.ARCH_MISMATCH, sprintf('No official auto-download for architecture %s (only amd64/arm64/386/armv6). Use the system package feed, or a custom URL pointing to a binary for your architecture.', det.uname_m || '?'));

    // step 1b — 下载前 overlay 空间预检(早失败,免白下载 + 给可操作错误,避免 overlay 被 ~40MB 二进制塞爆)。
    //   仅对「会新增文件」的下载拦:custom 视为新版本;release 仅当 netbird-release 尚不存在(首次)。
    //   re-update(target 已存在)走截断式写不额外占空间,不拦。netbird 二进制约 40MB,留余量取 48MB。
    //   best-effort:df 取不到(返 -1)则跳过,仍由 step 9 的 ENOSPC 兜底——绝不因 df 差异误拦正常下载。
    let writes_new = is_custom || !access(_NB_REL_BIN, 'f');
    if (writes_new) {
        let free_kb = _overlay_free_kb();
        // message 只放诊断明细(前端按 code=insufficient_space 给本地化「删旧版本」可操作文案)。
        if (free_kb >= 0 && free_kb < 49152)
            return fail_pre(CODE.INSUFFICIENT_SPACE, sprintf('%d MB free, ~48 MB needed', int(free_kb / 1024)));
    }

    // step 2 — 解析下载 URL + 文件名 + 版本(用于 checksums/日志)
    let dl_url = '';
    let dl_headers = [];
    let tarball = '';
    let ver = '';
    if (is_custom) {
        if (!match(custom_url, /^https?:\/\//))
            return fail_pre(CODE.INVALID_INPUT, 'The custom URL must start with http:// or https://.');
        dl_url = custom_url;
        let base_noq = custom_url;
        let qpos = index(base_noq, '?');
        if (qpos >= 0)
            base_noq = substr(base_noq, 0, qpos);
        let parts = split(base_noq, '/');
        tarball = parts[length(parts) - 1];
        let vm = match(tarball, /([0-9]+\.[0-9]+\.[0-9]+)/);
        if (vm)
            ver = vm[1];
    } else {
        ver = _latest_version();
        if (!match(ver, _SEMVER_RE))
            return fail_pre(CODE.INVALID_INPUT, 'Could not fetch or parse the latest version from GitHub (network failure or unexpected format).');
        tarball = 'netbird_' + ver + '_linux_' + arch + '.tar.gz';
        dl_url  = 'https://github.com/netbirdio/netbird/releases/download/v' + ver + '/' + tarball;
        let api_asset = _github_asset_api_url(ver, tarball);
        if (length(api_asset) > 0) {
            dl_url = api_asset;
            dl_headers = [ 'Accept: application/octet-stream' ];
        }
    }
    if (length(tarball) == 0)
        tarball = 'netbird_download.tar.gz';

    // per-call 独立工作目录(mktemp -d;缺失则回落固定路径)——所有临时物(tarball/checksums/
    // 解压件/目标备份)都落在 work 下,cleanup 一次删整目录。work 在 /tmp(tmpfs):备份不落
    // overlay(峰值省空间);并发/重入时各自独立目录,不互相清理。
    let _mk = _popen_simple('mktemp -d /tmp/nb-update.XXXXXX 2>/dev/null');
    let work = trim(_mk.out);
    // 注:ucode 的 access() **没有 'd' 模式**(只支持 r/w/x/f),`access(x,'d')` 恒返 null。原写法
    //   `!access(work,'d')` 永远为真 → 每次都回落到固定 `/tmp/nb-update`、把刚 mktemp 出来的空目录
    //   丢弃不清(每次下载泄漏一个空的 /tmp/nb-update.XXXXXX,且 per-call 隔离从未真正生效)。
    //   用 'f'(存在即可,目录也算)正确判定 mktemp 是否成功。
    if (length(work) == 0 || !access(work, 'f')) {
        work = '/tmp/nb-update';
        _popen_simple('rm -rf ' + shell_quote(work) + ' 2>/dev/null && mkdir -p ' + shell_quote(work));
    }
    let tgz_path    = work + '/' + tarball;
    let sums_path   = work + '/checksums.txt';
    let extract_dir = work;
    let new_bin     = work + '/netbird';
    let bak_path    = work + '/target.bak';

    let cleanup = function() {
        _popen_simple('rm -rf ' + shell_quote(work) + ' 2>/dev/null');
    };
    let progress_total = _http_content_length(dl_url, dl_headers);
    let fail_work = function(code, message, phase) {
        _progress_phase(phase || 'failed', message, tgz_path, progress_total);
        cleanup();
        return err(code, message);
    };
    let cancel_work = function() {
        let message = 'Download stopped by user.';
        _progress_phase('canceled', message, tgz_path, progress_total);
        cleanup();
        return err(CODE.DOWNLOAD_CANCELED, message);
    };

    // step 3 — 下载 tarball(经 _dl_cmd 多下载器回落;下载器自带超时防卡死;URL 已 shell_quote)。
    _progress_phase('downloading', 'Downloading...', tgz_path, progress_total);
    let dl = _popen_simple(_dl_cmd(dl_url, tgz_path, dl_secs, progress_total, dl_headers));
    if (_progress_canceled() || dl.code == 130)
        return cancel_work();
    if (dl.code != 0)
        return fail_work(CODE.DOWNLOAD_FAILED, 'Failed to download the binary: ' + substr(dl.out, 0, 300));
    _progress_phase('verifying', 'Verifying checksum and architecture...', tgz_path, progress_total);
    if (_progress_canceled())
        return cancel_work();
    // 下载器退出 0 仍可能拿到代理错误页/被截断的小文件(尤其自定义 URL/镜像)。NetBird 压缩包
    // 和直链 ELF 都远大于 1MB;小于该阈值直接按不完整下载处理并清理 work。
    let dl_kb = _file_size_kb(tgz_path);
    if (dl_kb < 1024)
        return fail_work(CODE.DOWNLOAD_FAILED,
                         sprintf('Downloaded file is incomplete or too small (%d KB); removed the partial download.', dl_kb < 0 ? 0 : dl_kb));

    // step 4 — 校验和。优先用用户在「自定义 URL」页填的校验和硬校验(按十六进制长度自动判算法:
    //   32=md5 / 40=sha1 / 64=sha256 / 128=sha512);否则有版本号就去 GitHub 抓官方 sha256
    //   checksums 比对(无 curl 机/取不到时 best-effort 跳过)。用户提供的校验和在解压/执行**之前**
    //   硬校验,不匹配立即中止(防 http:// 镜像被替换;md5/sha1 仅防意外损坏,抗篡改请用 sha256+)。
    let checksum_note = '';
    let want_ck = (type(a.checksum) == 'string') ? lc(trim(a.checksum)) : '';
    if (length(want_ck) > 0) {
        let tool = '';
        if (match(want_ck, /^[0-9a-f]{32}$/))        tool = 'md5sum';
        else if (match(want_ck, /^[0-9a-f]{40}$/))   tool = 'sha1sum';
        else if (match(want_ck, /^[0-9a-f]{64}$/))   tool = 'sha256sum';
        else if (match(want_ck, /^[0-9a-f]{128}$/))  tool = 'sha512sum';
        if (length(tool) == 0)
            return fail_work(CODE.INVALID_INPUT, 'The checksum must be md5 (32), sha1 (40), sha256 (64) or sha512 (128) hexadecimal characters.');
        let lr = _popen_simple(tool + ' ' + shell_quote(tgz_path) + ' 2>/dev/null');
        let am = match(lr.out, /^([0-9a-fA-F]+)/);
        let actual = am ? lc(am[1]) : '';
        if (length(actual) == 0)
            return fail_work(CODE.INSTALL_FAILED, sprintf('Could not compute the checksum: %s is not available on this device.', tool));
        if (actual != want_ck)
            return fail_work(CODE.CHECKSUM_MISMATCH,
                             sprintf('Checksum mismatch (expected %s…, got %s…); aborted.',
                                     substr(want_ck, 0, 16), substr(actual, 0, 16)));
        checksum_note = sprintf('Checksum (%s) verified against the value you provided.', tool);
    } else if (match(ver, _SEMVER_RE)) {
        if (_progress_canceled())
            return cancel_work();
        let sums_name = 'netbird_' + ver + '_checksums.txt';
        let sums_url = 'https://github.com/netbirdio/netbird/releases/download/v' + ver + '/' + sums_name;
        let sums_headers = [];
        let sums_asset = _github_asset_api_url(ver, sums_name);
        if (length(sums_asset) > 0) {
            sums_url = sums_asset;
            sums_headers = [ 'Accept: application/octet-stream' ];
        }
        let ds = _popen_simple(_dl_cmd(sums_url, sums_path, 60, null, sums_headers));
        if (_progress_canceled())
            return cancel_work();
        if (ds.code == 0) {
            let sums_r = _popen_simple('cat ' + shell_quote(sums_path) + ' 2>/dev/null');
            let expected = '';
            for (let ln in split(sums_r.out, '\n')) {
                let mm = match(ln, /^([0-9a-fA-F]{64})\s+(\S+)$/);
                if (mm && mm[2] == tarball) {
                    expected = lc(mm[1]);
                    break;
                }
            }
            if (length(expected) == 64) {
                let local_r = _popen_simple('sha256sum ' + shell_quote(tgz_path) + ' 2>/dev/null');
                let am = match(local_r.out, /^([0-9a-fA-F]{64})/);
                let actual = am ? lc(am[1]) : '';
                if (actual != expected)
                    return fail_work(CODE.CHECKSUM_MISMATCH,
                                     sprintf('sha256 checksum mismatch (expected=%s… actual=%s); aborted',
                                             substr(expected, 0, 16), length(actual) == 64 ? substr(actual, 0, 16) : '(compute failed)'));
            } else {
                checksum_note = 'no matching filename in checksums; skipped sha256';
            }
        } else {
            checksum_note = 'could not fetch checksums; skipped sha256 (custom mirror/network)';
        }
    } else {
        checksum_note = 'no version in filename; skipped sha256';
    }

    // step 5 — 取出 netbird 二进制。下载物可能是 **tar.gz**(官方/镜像 release 包,取 netbird 成员),
    //   也可能是 **直接的二进制直链**(用户自贴):先按 ELF 魔数探测,是 ELF 就直接用,否则按 tar.gz 解压。
    _progress_phase('extracting', 'Extracting binary...', tgz_path, progress_total);
    if (_progress_canceled())
        return cancel_work();
    _popen_simple('mkdir -p ' + shell_quote(extract_dir));
    if (_elf_machine(tgz_path) > 0) {
        // 下载物本身就是 ELF 可执行 → 截断式写入 new_bin(overlay 峰值 1×),后续 step6/7 照常校验。
        // 整组 `{ …; } 2>&1` 收 stderr(同 step 9:`2>&1` 不能只绑末尾 chmod,否则 cat 写失败报错丢失)。
        let cp = _popen_simple('{ cat ' + shell_quote(tgz_path) + ' > ' + shell_quote(new_bin) +
                               ' && chmod +x ' + shell_quote(new_bin) + ' ; } 2>&1');
        if (cp.code != 0 || !access(new_bin, 'f'))
            return fail_work(CODE.INSTALL_FAILED, 'Failed to save the downloaded binary: ' +
                             (length(trim(cp.out)) > 0 ? substr(trim(cp.out), 0, 200)
                                                       : sprintf('write exited %d with no output (storage may be full)', cp.code)));
    } else {
        // 先验**整包完整性**(tar -tzf 全量遍历归档):>1MB 但被截断/损坏的下载(典型「下载中断」,
        // 大小预检放过)在解压前就判出 = 下载侧问题(DOWNLOAD_FAILED 更准),而非笼统 install 失败;
        // 失败清理 work。注:也挡住「下成了非 tar.gz 的错误页/直链非 ELF」的情况。
        let archive_check = _popen_simple('tar -tzf ' + shell_quote(tgz_path) + ' >/dev/null 2>&1');
        if (archive_check.code != 0)
            return fail_work(CODE.DOWNLOAD_FAILED, 'The downloaded archive is incomplete or corrupt (download interrupted, or the URL returned an error page instead of a tarball).');
        // 整包完整 → 仅解出 netbird 成员
        let untar = _popen_simple('tar -xzf ' + shell_quote(tgz_path) + ' -C ' + shell_quote(extract_dir) + ' netbird 2>&1');
        if (untar.code != 0 || !access(new_bin, 'f'))
            return fail_work(CODE.INSTALL_FAILED, 'Could not extract netbird (the download is neither an ELF binary nor a tar.gz containing a netbird member): ' + substr(untar.out, 0, 300));
    }
    // 解压/直链保存后再次检查大小:tar 可能生成截断成员,ELF 魔数也可能出现在不完整直链里。
    let new_kb = _file_size_kb(new_bin);
    if (new_kb < 1024)
        return fail_work(CODE.INSTALL_FAILED,
                         sprintf('Extracted netbird binary is incomplete or too small (%d KB); removed the partial download.', new_kb < 0 ? 0 : new_kb));

    // step 6 — ELF arch 校验(硬闸:坏包/错架构绝不安装,否则替换后 netbird 服务崩)。
    //   release:比对本机 arch 对应的 netbird e_machine(4 架构表);
    //   custom:比对本机原生 ELF e_machine(支持任意架构 + 端序;读不到本机 ELF 回落 4 架构表)。
    // 注:ELF 校验覆盖机器类型 + 端序,但不覆盖 mips 浮点 ABI(hard/soft);custom 路径的
    //   浮点不符由 step 7 的 `version` 可执行性兜底(用户自贴 URL 属高级操作)。
    let want_em = is_custom ? _native_emachine() : _arch_emachine(arch);
    if (want_em < 0)
        want_em = _arch_emachine(arch);
    let got_em = _elf_machine(new_bin);
    if (got_em < 0)
        return fail_work(CODE.ARCH_MISMATCH, 'The downloaded file is not a valid ELF executable; installation aborted.');
    if (want_em > 0 && got_em != want_em)
        return fail_work(CODE.ARCH_MISMATCH,
                         sprintf('Downloaded package arch mismatch: host e_machine=%d, package e_machine=%d; installation aborted', want_em, got_em));

    // step 7 — 解压件能执行 version(完整性兜底)
    if (_progress_canceled())
        return cancel_work();
    let chk = _popen_simple('chmod +x ' + shell_quote(new_bin) + '; ' + shell_quote(new_bin) + ' version 2>&1');
    let new_ver = _parse_version_output(chk.out);
    if (length(new_ver) == 0)
        return fail_work(CODE.INSTALL_FAILED, 'The downloaded binary cannot run "version" (possibly corrupt): ' + substr(chk.out, 0, 200));

    // step 7b — 决定目标路径:custom(非空 url)按版本号存 netbird-v<ver>(不覆盖 release、新文件不动 active);
    //            release(空 url)写 _NB_REL_BIN。
    let target_path = _NB_REL_BIN;
    if (is_custom) {
        let sv = _sanitize_version(new_ver);
        if (length(sv) == 0)
            return fail_work(CODE.INSTALL_FAILED, 'Could not parse a valid version from the binary (' + substr(new_ver, 0, 40) + '); refusing to save it by name.');
        target_path = _custom_version_path(sv);
    }
    // 变量名避开 `from`:它在较早的 ucode 里是保留字(import ... from ...),
    // 用作标识符会让整个文件解析失败。返回体的 `from` 键名不变。
    let from_ver = access(target_path, 'x') ? _file_version(target_path) : '';

    // step 8 — 备份目标(若存在);仅当目标正是当前运行的二进制时才停 daemon(避 ETXTBSY,所有 sibling 分支一致)
    _progress_phase('installing', 'Installing binary...', tgz_path, progress_total);
    if (_progress_canceled())
        return cancel_work();
    let active_bin = _active_binary_path();
    let need_stop = (target_path == active_bin);
    if (access(target_path, 'f'))
        _popen_simple('cat ' + shell_quote(target_path) + ' > ' + shell_quote(bak_path) + ' 2>/dev/null');
    let stopped = false;
    if (need_stop) {
        _popen_simple('/etc/init.d/netbird stop 2>&1');
        if (!_wait_daemon_gone()) {
            let stop_msg = 'The netbird daemon did not stop in time; replacement aborted to protect the current binary.';
            _progress_phase('failed', stop_msg, tgz_path, progress_total);
            cleanup();
            _popen_simple('rm -f ' + shell_quote(bak_path) + ' 2>/dev/null');
            _popen_simple('/etc/init.d/netbird start 2>&1');
            return err(CODE.INSTALL_FAILED, stop_msg);
        }
        stopped = true;
    }

    // step 9 — 截断式写入 target(1× 峰值,省 overlay 空间);验证;失败兜底。
    //   整组用 `{ …; } 2>&1` 收 stderr:原写法 `… cat > target && chmod … 2>&1` 的 `2>&1` 只绑定末尾
    //   chmod,`cat > target` 写失败(如 overlay 空间不足 ENOSPC)的报错落在未捕获的 stderr → 错误明细
    //   空白(已知 bug:UI 显示「Failed to write the binary:」后面什么都没有)。整组重定向后 wr.out 拿到真因。
    let wr = _popen_simple('{ mkdir -p ' + shell_quote(_NB_REL_DIR) + ' && cat ' + shell_quote(new_bin) +
                           ' > ' + shell_quote(target_path) + ' && chmod 0755 ' + shell_quote(target_path) + ' ; } 2>&1');
    let to = (wr.code == 0) ? _file_version(target_path) : '';
    if (wr.code != 0 || length(to) == 0) {
        // 失败兜底:有备份(=target 原已存在)则还原旧二进制;无备份(=本就是新文件)则删掉**半成品**——
        //   `cat > target` 即便写失败也已 create/truncate 出 target,且因 `&&` 短路 chmod 没跑 → 残片为
        //   非可执行的 0644;若不删,会被 _list_custom_versions 当成「已下载版本」列出(幽灵版本),切换时
        //   又因 access(x)=false 报「not downloaded」(已知 bug)。
        let restored = false;
        if (access(bak_path, 'f')) {
            _popen_simple('cat ' + shell_quote(bak_path) + ' > ' + shell_quote(target_path) +
                          ' && chmod 0755 ' + shell_quote(target_path) + ' 2>/dev/null');
            restored = true;
        } else {
            _popen_simple('rm -f ' + shell_quote(target_path) + ' 2>/dev/null');
        }
        if (stopped)
            _popen_simple('/etc/init.d/netbird start 2>&1');
        cleanup();
        _popen_simple('rm -f ' + shell_quote(bak_path) + ' 2>/dev/null');
        // 空间不足(ENOSPC)单列 code,前端本地化「删旧版本」可操作提示(K1);其它写失败走 install_failed + 明细。
        let raw = trim(wr.out);
        if (match(raw, /[Nn]o space left|ENOSPC/)) {
            let space_msg = restored ? 'storage filled up during install (previous binary kept)' : 'storage filled up during install';
            _progress_phase('failed', space_msg, tgz_path, progress_total);
            return err(CODE.INSUFFICIENT_SPACE, space_msg);
        }
        // 明细:即使 wr.out 为空也给可操作信息(写命令非零但无输出多为 overlay 空间不足/只读)。
        let detail;
        if (length(raw) > 0)
            detail = substr(raw, 0, 200);
        else if (wr.code != 0)
            detail = sprintf('write command exited %d with no output (storage may be full or read-only)', wr.code);
        else
            detail = 'the written file could not report its version (truncated or corrupt)';
        let write_msg = 'Failed to write the binary' + (restored ? '; restored the previous one' : '') + ': ' + detail;
        _progress_phase('failed', write_msg, tgz_path, progress_total);
        return err(CODE.INSTALL_FAILED, write_msg);
    }

    // step 10 — 重启(若停过);清理
    if (stopped)
        _popen_simple('/etc/init.d/netbird start 2>&1');
    _progress_phase('done', 'Binary installed.', tgz_path, progress_total);
    cleanup();
    _popen_simple('rm -f ' + shell_quote(bak_path) + ' 2>/dev/null');

    return ok({ from: from_ver, to: to, active_source: _active_source(), checksum_note: checksum_note, path: target_path, custom: is_custom });
}
// _do_update_binary(req) — _update_binary_locked 的互斥包装(二进制操作串行,见 _binop_guard)。
function _do_update_binary(req) { return _binop_guard(_update_binary_locked, req); }

// _set_binary_source_locked(req) — 切换 daemon 实际运行的二进制来源(release/opkg/custom,三态)。
// 写 netbird_bin.binary.binary_source(独立配置,不触发 netbird-settings reload)+ 实际切换
// /usr/bin/netbird(release/custom = symlink;opkg = real file 副本复原)+ 重启 daemon。破坏性 → 前端确认。
//   opkg 无副本时从软件源安全获取(opkg download / apk fetch 解压,绝不 --force-reinstall / apk add);
//   custom 需 args.version 指定切到哪个已下载版本。经 _do_set_binary_source 包 _binop_guard 互斥调用。
function _set_binary_source_locked(req) {
    let a = (req != null && req.args != null) ? req.args : (req || {});
    let source = (type(a.source) == 'string') ? a.source : '';
    if (source != 'release' && source != 'opkg' && source != 'custom')
        return err(CODE.INVALID_INPUT, 'source must be release, opkg, or custom.');

    // 解析目标二进制路径(各来源就绪性检查)——**先校验目标可用,通过后再写 binary_source**:
    // 失败时不留下「configured=新来源 但 active=旧二进制」的不一致(原先先 commit 后校验有此问题)。
    let target_bin = '';
    if (source == 'release') {
        if (!access(_NB_REL_BIN, 'x'))
            return err(CODE.NOT_INSTALLED, 'The release binary is not downloaded yet — use "Check for updates / Update now" first.');
        target_bin = _NB_REL_BIN;
    } else if (source == 'custom') {
        let version = _sanitize_version(a.version);
        if (length(version) == 0)
            return err(CODE.INVALID_INPUT, 'Switching to the custom source requires a valid version.');
        target_bin = _custom_version_path(version);
        if (!access(target_bin, 'x'))
            return err(CODE.NOT_INSTALLED, sprintf('Custom version v%s is not downloaded.', version));
    } else {
        // opkg:无副本则非破坏性从 feed 自动获取(_fetch_opkg_binary;绝不 --force-reinstall,免删 init.d)。
        if (!access(_NB_OPKG_BAK, 'x')) {
            if (!_opkg_feed_has_netbird())
                return err(CODE.NOT_INSTALLED, 'The system package feed does not provide netbird, so its binary cannot be fetched automatically. Check your package sources, or use the release or custom source.');
            let f = _fetch_opkg_binary();
            if (!f.ok)
                return err(match(f.err, /[Nn]o space left|ENOSPC/) ? CODE.INSUFFICIENT_SPACE : CODE.INSTALL_FAILED,
                           'Failed to fetch the package-feed binary automatically: ' + f.err);
        }
        target_bin = _NB_OPKG_BIN;   // opkg = /usr/bin/netbird real file 本体
    }

    // 目标来源已确认可用 → 记录用户选择(独立配置文件,不触发 netbird down→up)。
    let c = uci.cursor();
    if (c.get('netbird_bin', 'binary') == null)
        c.set('netbird_bin', 'binary', 'netbird_bin');
    c.set('netbird_bin', 'binary', 'binary_source', source);
    c.commit('netbird_bin');

    // 已是目标来源?(custom 还要确认是同一版本)
    let active = _active_source();
    if (active == source && (source != 'custom' || _active_binary_path() == target_bin))
        return ok({ source: source, already: true, active_source: active, running_version: _running_version(_NB_OPKG_BIN) });

    // 停 daemon 并校验真退出(所有动二进制/symlink 的 sibling 分支一致守 _wait_daemon_gone)
    _popen_simple('/etc/init.d/netbird stop 2>&1');
    if (!_wait_daemon_gone()) {
        _popen_simple('/etc/init.d/netbird start 2>&1');
        return err(CODE.INSTALL_FAILED, 'The netbird daemon did not stop in time; switch aborted (the binary was not touched).');
    }

    let sw;
    if (source == 'opkg') {
        // /usr/bin/netbird 当前可能是 symlink → 先删再写 real file(否则 cat> 穿透 symlink 写坏目标)。
        sw = _popen_simple('rm -f ' + shell_quote(_NB_OPKG_BIN) + ' && cat ' + shell_quote(_NB_OPKG_BAK) +
                           ' > ' + shell_quote(_NB_OPKG_BIN) + ' && chmod 0755 ' + shell_quote(_NB_OPKG_BIN) + ' 2>&1');
    } else {
        // release / custom:原子换 symlink(先建临时 link 再 mv -f,避免半态)。
        sw = _popen_simple('ln -sf ' + shell_quote(target_bin) + ' ' + shell_quote(_NB_OPKG_BIN + '.tmp') +
                           ' && mv -f ' + shell_quote(_NB_OPKG_BIN + '.tmp') + ' ' + shell_quote(_NB_OPKG_BIN) + ' 2>&1');
    }
    // 校验切换结果(读 symlink/disk,daemon 仍停——无需先 start;避免 review 指出的「已 start 再回退」窗口)
    let now = _active_source();
    let ok_switch = (now == source) && (source != 'custom' || _active_binary_path() == target_bin);
    if (sw.code != 0 || !ok_switch) {
        // 切换失败:**仍在停止态**做回退(daemon 未持 inode,rm+cat 无 ETXTBSY、不会把运行中 daemon 留在错二进制)。
        // 绝不把 /usr/bin/netbird 留成 dangling/缺失:优先回退 release symlink,否则 opkg 副本。
        if (access(_NB_REL_BIN, 'x'))
            _popen_simple('ln -sf ' + shell_quote(_NB_REL_BIN) + ' ' + shell_quote(_NB_OPKG_BIN) + ' 2>/dev/null');
        else if (access(_NB_OPKG_BAK, 'x'))
            _popen_simple('rm -f ' + shell_quote(_NB_OPKG_BIN) + ' && cat ' + shell_quote(_NB_OPKG_BAK) +
                          ' > ' + shell_quote(_NB_OPKG_BIN) + ' && chmod 0755 ' + shell_quote(_NB_OPKG_BIN) + ' 2>/dev/null');
        _popen_simple('/etc/init.d/netbird start 2>&1');
        return err(CODE.INSTALL_FAILED, sprintf('Failed to switch to %s; rolled back: %s', source, substr(sw.out, 0, 200)));
    }
    // 成功:启动切换后的二进制(单次 start,在校验之后)
    _popen_simple('/etc/init.d/netbird start 2>&1');
    return ok({ source: source, active_source: now, running_version: _running_version(_NB_OPKG_BIN) });
}
// _do_set_binary_source(req) — _set_binary_source_locked 的互斥包装(见 _binop_guard)。
function _do_set_binary_source(req) { return _binop_guard(_set_binary_source_locked, req); }

// _delete_custom_binary_locked(req) — 删除一个非 active 的自定义下载版本 netbird-v<ver>(多版本盘面清理)。
// 拒删正在使用的版本(防把 active 删掉致 daemon 跑空)。经 _do_delete_custom_binary 包 _binop_guard 互斥。
function _delete_custom_binary_locked(req) {
    let a = (req != null && req.args != null) ? req.args : (req || {});
    let version = _sanitize_version(a.version);
    if (length(version) == 0)
        return err(CODE.INVALID_INPUT, 'The version is missing or invalid.');
    let path = _custom_version_path(version);
    if (!access(path, 'f'))
        return err(CODE.NOT_INSTALLED, sprintf('Custom version v%s does not exist.', version));
    if (_active_source() == 'custom' && _active_binary_path() == path)
        return err(CODE.INVALID_INPUT, sprintf('v%s is in use and cannot be deleted; switch to another source or version first.', version));
    let r = _popen_simple('rm -f ' + shell_quote(path) + ' 2>&1');
    if (r.code != 0 || access(path, 'f'))
        return err(CODE.INSTALL_FAILED, 'Failed to delete: ' + substr(r.out, 0, 200));
    return ok({ deleted: version });
}
// _do_delete_custom_binary(req) — _delete_custom_binary_locked 的互斥包装(见 _binop_guard)。
function _do_delete_custom_binary(req) { return _binop_guard(_delete_custom_binary_locked, req); }

// _ensure_configured_binary() — 首连兜底:让「配置来源」(默认 release)成为 active(用户拍板:首连自动下 release)。
// 触发条件:① 配置来源=release(用户未手动切到 opkg/custom) ② release 尚非 active。动作:
//   - release 已下载 → 切过去;
//   - release 未下载 + 本机有官方 release 架构(amd64/arm64/386/armv6)→ 下载 GitHub latest 再切;
//   - 下载失败 / 本机无官方 release(mips 等)→ 静默保持现状(feed 兜底),配置仍记 release 待下次重试。
// **绝不抛错、绝不阻断连接**:任何分支失败都直接 return,调用方继续用当前 active 二进制连接。
// release 就位后即 no-op(后续连接零开销)。供 do_up 在连接前调用(因 ucode 不 hoist,定义在 do_up 之前)。
function _ensure_configured_binary() {
    if (_uci_binary('binary_source', 'release') != 'release')
        return;                                       // 用户已手动切走 → 尊重,不覆盖
    if (_active_source() == 'release')
        return;                                       // 已是 release → no-op
    if (!access(_NB_REL_BIN, 'x')) {
        let det = _detect_arch();
        if (length(det.arch) == 0 || !match(det.arch, _ARCH_RE))
            return;                                   // 本机无官方 release(mips 等)→ feed 兜底
        // 有界下载(20s,用户拍板):正常网络 release ~20s 内下完;超时/慢链则回落 feed
        // (netbird-openwrt 源),release 留待下次连接重试。首连不久阻,避免连接转圈过长。
        let up = _do_update_binary({ dl_timeout: 20 }); // 下载 GitHub latest release(envelope)
        if (type(up) != 'object' || up.ok != true)
            return;                                   // 下载失败/超时 → feed 兜底(daemon 未被牵连)
    }
    _do_set_binary_source({ source: 'release' });     // 切到 release(失败也不阻断;daemon 仍可连)
}

// ============================================================================
// install_iface_backend — 一键安装 WireGuard / TUN 内核后端
// ============================================================================
// 前端仅在 get_status.iface_backend.ready === false（高置信双缺）时显示按钮。
// 后端同样以 ready 为闸：已 ready 则幂等 no-op，避免健康机多此一举。
// 装什么由后端决定（绝不让前端硬编码包名）：
//   1) 优先 kmod-wireguard（NetBird 首选内核 WG 路径）
//   2) WG 装失败或装完复验仍缺 → 再试 kmod-tun（userspace wireguard-go 路径）
// 绝不触碰 netbird 包本身（remove / --force-reinstall / apk fix 红线）。
// 失败时原样截断回传包管理器输出，并按内核哈希失配 / 网络 / 源 分类 message+hint。

const _IFACE_INSTALL_LOCK = '/tmp/nb-iface-backend-install.lock';

// _classify_pkg_install_error(raw) → { message, hint }
// 把 opkg/apk 原始输出分成可行动类别；raw 始终由调用方另附，本函数只产摘要。
function _classify_pkg_install_error(raw) {
    let t = lc(raw || '');
    // 内核哈希锁定：kmod 依赖 kernel (= <ver>-<hash>)，厂商自编内核必然对不上。
    if (match(t, /satisfy_dependencies|cannot satisfy|unsatisfiable|broken packages|kernel\s*\(=\s*|depends on kernel|has no candidates for|conflicts with kernel/))
        return {
            message: 'Package install failed: kernel modules from the package feeds do not match this device kernel (common on vendor firmware with a custom kernel).',
            hint: 'Use kmod packages that match your running kernel (vendor firmware image), or flash stock OpenWrt/ImmortalWrt whose kernel matches the configured feeds.'
        };
    if (match(t, /failed to download|download failed|wget returned|network is unreachable|temporary failure resolving|connection refused|connection timed out|ssl[_\s]?error|could not resolve|no route to host|apk.*error.*fetch|unreachable/))
        return {
            message: 'Package install failed: could not reach the package feeds (network or DNS).',
            hint: 'Check WAN/DNS connectivity, then retry. You may need to run the package manager update manually first.'
        };
    if (match(t, /unknown package|no such package|has no candidates|not found in|package not found|error 404|404 not found/))
        return {
            message: 'Package install failed: the required package is not available in the configured feeds.',
            hint: 'Check /etc/opkg/distfeeds.conf or apk repositories, run a package list update, and ensure the release matches this image.'
        };
    if (match(t, /lock|locked|another instance|could not lock|failed to lock/))
        return {
            message: 'Package install failed: another package manager instance is already running.',
            hint: 'Wait for the other install/update to finish, then try again.'
        };
    return {
        message: 'Package install failed.',
        hint: 'See the package manager output below for the exact error.'
    };
}

// _pkg_install_exact(name) → { code, out, cmd }：精确包名安装（禁 glob）；复用 _pkg_mgr 分流。
// name 仅允许 [A-Za-z0-9._+-]，防注入；输出截到 2KiB。
function _pkg_install_exact(name) {
    if (!match(name || '', /^[A-Za-z0-9._+-]+$/))
        return { code: -1, out: 'refusing invalid package name', cmd: '' };
    let mgr = _pkg_mgr();
    let cmd;
    if (mgr == 'apk')
        cmd = 'apk add --allow-untrusted ' + name + ' 2>&1';
    else
        cmd = 'opkg install ' + name + ' 2>&1';
    let r = _popen_simple(cmd); // shell-audit-ok: name 经严格白名单校验
    return { code: r.code, out: substr(r.out || '', 0, 2048), cmd: cmd };
}

// _pkg_update_lists() → { code, out }：刷新索引；失败不阻断后续 install（可能本地缓存仍可用）。
function _pkg_update_lists() {
    let cmd = (_pkg_mgr() == 'apk') ? 'apk update 2>&1' : 'opkg update 2>&1';
    let r = _popen_simple(cmd); // shell-audit-ok: 纯字面常量
    return { code: r.code, out: substr(r.out || '', 0, 1024) };
}

// _iface_install_lock() → true 拿到锁 / false 已有并发安装。
function _iface_install_lock() {
    // mkdir 原子占位；成功=拿到锁。
    let r = _popen_simple('mkdir ' + shell_quote(_IFACE_INSTALL_LOCK) + ' 2>/dev/null');
    return r.code == 0;
}

function _iface_install_unlock() {
    _popen_simple('rmdir ' + shell_quote(_IFACE_INSTALL_LOCK) + ' 2>/dev/null');
}

// _do_install_iface_backend() — 写方法主体。
// 注意：不用 try/finally（22.03 ucode 无 finally）；所有 return 前显式 unlock。
function _do_install_iface_backend(req) {
    let before = probe_iface_backend();
    let mgr = _pkg_mgr();

    // 幂等：已有 WG 或 TUN 正证据 → 不跑包管理器。
    if (before.ready) {
        return ok({
            already: true,
            packages: [],
            pkg_mgr: mgr,
            iface_backend: before,
            output: ''
        });
    }

    if (!_iface_install_lock()) {
        return err(CODE.INSTALL_FAILED,
            'Another WireGuard/TUN package install is already in progress.',
            'Wait for it to finish, then retry if the warning is still shown.');
    }

    let installed = [];
    let outputs = [];
    let last_fail = null;

    // 刷新软件源索引（失败只记日志，仍尝试 install——缓存可能够用）。
    let upd = _pkg_update_lists();
    if (length(upd.out) > 0)
        push(outputs, 'update:\n' + upd.out);

    // 优先内核 WireGuard；NetBird 主路径。
    let wg = _pkg_install_exact('kmod-wireguard');
    push(outputs, wg.cmd + '\n' + wg.out);
    if (wg.code == 0)
        push(installed, 'kmod-wireguard');
    else
        last_fail = wg;

    let mid = probe_iface_backend();
    // WG 已就绪则不必再动 TUN；否则退而装 kmod-tun（userspace 路径）。
    if (!mid.ready) {
        let tun = _pkg_install_exact('kmod-tun');
        push(outputs, tun.cmd + '\n' + tun.out);
        if (tun.code == 0)
            push(installed, 'kmod-tun');
        else if (last_fail == null || wg.code == 0)
            last_fail = tun;
    }

    let after = probe_iface_backend();
    let raw = substr(join('\n---\n', outputs), 0, 2400);

    if (after.ready) {
        _iface_install_unlock();
        return ok({
            already: false,
            packages: installed,
            pkg_mgr: mgr,
            iface_backend: after,
            output: raw
        });
    }

    // 包管理器都失败，或装上了但复验仍双缺（错版本 kmod / 需重启等）。
    if (length(installed) == 0 && last_fail != null) {
        let cls = _classify_pkg_install_error(last_fail.out);
        _iface_install_unlock();
        return err(CODE.INSTALL_FAILED,
            cls.message + ' Output: ' + substr(trim(last_fail.out), 0, 900),
            cls.hint);
    }

    let pkgs_txt = (length(installed) > 0) ? join(', ', installed) : '(none)';
    _iface_install_unlock();
    return err(CODE.INSTALL_FAILED,
        'Packages were processed but WireGuard/TUN is still unavailable after re-probe. Installed: ' +
        pkgs_txt + '. Output: ' + substr(trim(raw), 0, 900),
        'If packages installed successfully, reboot the device and check again. Vendor kernels may still lack a matching module.');
}

return {
    'luci.netbird': {
        // ==== 13 read ====（ACL read.ubus.luci.netbird 对齐）

        // 任何态都 ok:true；data.status 暴露 5 态字面量
        get_status: {
            args: {},
            call: _safe(function() {
                return ok(probe_state());
            }),
        },

        // 友好化：非 running 态 ok:true + 空 lines + state + note
        // 数据源（改动 1，对齐 OPNsense，显示真实 peer 活动）：
        //   优先读 netbird 守护进程日志文件 /var/log/netbird/client.log（默认路径，含
        //   真实 peer 握手/relay/连接日志，不进 syslog）。文件大（~12MB），故只 tail -n <limit>
        //   读尾部，绝不全读。文件不存在则回退 logread -e netbird（兼容日志走 syslog 的部署）。
        //   返回 source: 'daemon'|'syslog' 标识，供前端选解析器。
        //   running + 文件存在但空 → ok:true + note:'no_logs_in_ring'
        get_logs: {
            args: { limit: 200, since_ts: 0 },
            call: _safe(function(req) {
                let st = probe_state();
                if (st.status != 'running') {
                    return ok({
                        lines: [],
                        state: st.status,
                        source: 'daemon',
                        note: 'service not running, logs unavailable',
                    });
                }

                // 参数取值兼容：rpcd 把 args 传入 req.args；防御性处理 null / 非数字
                let a = (req != null && req.args != null) ? req.args : (req || {});
                let limit = +a.limit;
                if (limit == null || limit != limit || limit == 0) limit = 200;  // NaN/0 默认
                if (limit < 1)    limit = 1;
                if (limit > 1000) limit = 1000;

                // 数据源选择 + 读取（路径/命令均字面常量，无用户输入；limit 已 clamp 为整数）。
                let src = _read_daemon_logs(limit);

                let lines = src.lines;
                let total = length(lines);
                // tail -n 已在 shell 侧截到尾部 limit 行；source=syslog 时 logread 可能超 limit。
                let truncated = src.truncated || (total > limit);
                if (total > limit)
                    lines = slice(lines, total - limit);

                let data = { lines: lines, truncated: truncated, source: src.source };
                if (length(lines) == 0)
                    data.note = 'no_logs_in_ring';
                return ok(data);
            }),
        },

        // 非 running 返 err+code；running 返 peers details 数组 + 计数。
        // 0.72.4 `status --json` 的 peers 是对象 {total,connected,details:[...]}，
        // 旧代码把整个对象当数组返回（bug）；此处解包 details 并透传计数。
        // peer 对象字段来自 0.72.4 status --json 的 peers.details。
        list_peers: {
            args: {},
            call: _safe(function() {
                let g = _require_running();
                if (g._gate) return g._gate;
                let js = g._json;
                let connected = !!(js != null && js.management != null && js.management.connected);
                let p = (js != null && js.peers != null) ? js.peers : {};
                let details = (p.details != null) ? p.details : [];
                return ok({
                    peers: details,
                    total: (p.total != null) ? p.total : length(details),
                    connected_count: (p.connected != null) ? p.connected : 0,
                    connected: connected,
                });
            }),
        },

        // 非 running 返 err+code；running 透传 networks 字段（缺失 []）
        list_networks: {
            args: {},
            call: _safe(function() {
                let g = _require_running();
                if (g._gate) return g._gate;
                let js = g._json;
                let connected = !!(js != null && js.management != null && js.management.connected);
                return ok({ networks: js.networks || [], connected: connected });
            }),
        },

        // list_exit_nodes — 可用 exit node（0.0.0.0/0 路由）清单 + 各自选中态。
        // 非 running 返 err+code；running 但未连接管理端 → ok + connected:false + 空表
        // （networks list 依赖 engine，未连接时必报错，这里直接短路成友好态）。
        // ACL: 方法名已加入 read.ubus.luci.netbird（一字不差）。
        list_exit_nodes: {
            args: {},
            call: _safe(function() {
                let g = _require_running();
                if (g._gate) return g._gate;
                let js = g._json;
                let connected = !!(js != null && js.management != null && js.management.connected);
                if (!connected)
                    return ok({ exit_nodes: [], connected: false });
                let res = _collect_exit_nodes(g._state.bin_path);
                if (!res.ok)
                    return err(CODE.CLI_ERROR, res.message);
                return ok({ exit_nodes: res.exit_nodes, connected: true });
            }),
        },

        // **任何态** ok:true；preshared_key 只回 preshared_key_configured:boolean
        get_settings: {
            args: {},
            call: _safe(function() {
                let c = uci.cursor();
                let raw = c.get_all('netbird', 'settings') || {};
                return ok(sanitize_settings(raw));
            }),
        },

        // **任何态** ok:true；opkg 本地可用，不依赖 daemon
        get_package_versions: {
            args: {},
            call: _safe(function() {
                return ok(get_opkg_versions());
            }),
        },

        // get_auth_info — 改动 2：认证页预填用（纯读，任何态 ok:true）。
        //   management_url：展示用有效管理 URL，优先级 UCI management_url →
        //       config.json ManagementURL（Scheme://Host 重建，只读）→ ''。
        //   setup_key_hint：打码后的安装密钥提示（OPNsense 风格），无则 ''；
        //       绝不返回原始 key（原始 key 本就不入 UCI）。
        // ACL: 方法名已加入 read.ubus.luci.netbird（一字不差）。
        get_auth_info: {
            args: {},
            call: _safe(function() {
                let c = uci.cursor();
                let hint = c.get('netbird', 'settings', 'setup_key_hint');
                return ok({
                    management_url:  _resolve_display_mgmt_url(),
                    setup_key_hint:  (type(hint) == 'string') ? hint : '',
                    last_error:      (type(c.get('netbird', 'runtime', 'last_error')) == 'string') ? c.get('netbird', 'runtime', 'last_error') : '',
                });
            }),
        },

        // 仅 running 态（_require_running 闸）：从 status --json 顶层抽取连接概览精选字段。
        // 字段来源 0.72.4 status --json 顶层；缺失字段给保守默认。
        // ACL: 方法名已加入 read.ubus.luci.netbird（一字不差）。
        get_connection_info: {
            args: {},
            call: _safe(function() {
                let g = _require_running();
                if (g._gate) return g._gate;
                let js = g._json;

                let mgmt   = (js.management != null) ? js.management : {};
                let signal = (js.signal != null)     ? js.signal     : {};
                let relays = (js.relays != null)     ? js.relays     : {};
                let peers  = (js.peers != null)      ? js.peers      : {};

                return ok({
                    cliVersion:            js.cliVersion || '',
                    daemonVersion:         js.daemonVersion || '',
                    management: {
                        url:       mgmt.url || '',
                        connected: !!mgmt.connected,
                    },
                    signal: {
                        url:       signal.url || '',
                        connected: !!signal.connected,
                    },
                    relays: {
                        total:     (relays.total != null) ? relays.total : 0,
                        available: (relays.available != null) ? relays.available : 0,
                    },
                    netbirdIp:             js.netbirdIp || '',
                    netbirdIpv6:           js.netbirdIpv6 || '',
                    fqdn:                  js.fqdn || '',
                    usesKernelInterface:   !!js.usesKernelInterface,
                    quantumResistance:     !!js.quantumResistance,
                    lazyConnectionEnabled: !!js.lazyConnectionEnabled,
                    forwardingRules:       (js.forwardingRules != null) ? js.forwardingRules : 0,
                    networks:              js.networks || [],
                    profileName:           js.profileName || '',
                    peers: {
                        total:     (peers.total != null) ? peers.total : 0,
                        connected: (peers.connected != null) ? peers.connected : 0,
                    },
                });
            }),
        },

        // get_automation_status — OpenWRT 装配态（纯读 UCI，任何态 ok:true）。
        // 供 Network Tab 顶部显示：接口/zone 是否已创建、两向 forwarding 当前状态。
        // ACL: 方法名已加入 read.ubus.luci.netbird（一字不差）。
        get_automation_status: {
            args: {},
            call: _safe(_do_get_automation_status),
        },

        // get_binary_info — 二进制来源概览（纯读，任何态 ok:true）。
        // 默认只回本地信息（active/configured source、release/opkg 版本+路径、running、arch、luci_app）；
        // args.check_remote=true 才拉 GitHub latest + opkg upgradable（「检测更新」按钮，避限流）。
        // ACL: 方法名已加入 read.ubus.luci.netbird（一字不差）。
        get_binary_info: {
            args: { check_remote: false },
            call: _safe(_do_get_binary_info),
        },

        // get_binary_update_progress — 二进制下载/安装进度（供版本页弹窗轮询）。
        // ACL: 方法名已加入 read.ubus.luci.netbird（一字不差）。
        get_binary_update_progress: {
            args: {},
            call: _safe(_do_get_binary_update_progress),
        },

        // check_luci_app_update — 检测 luci-app-netbird 自身包是否有新版本。
        // ACL: 方法名已加入 read.ubus.luci.netbird（一字不差）。
        check_luci_app_update: {
            args: {},
            call: _safe(_do_check_luci_app_update),
        },

        // ==== 16 write ====（ACL write.ubus.luci.netbird 对齐）— zone 设备直绑设计已移除 setup_network

        // do_up — 连接（拉起 WireGuard + 连管理端 + 建 P2P）。
        // args { management_url, setup_key } 均瞬时（setup_key 绝不入 UCI/backup）。
        // 流程：
        //   1. 解析 management_url（arg → UCI 回退 → null=用 daemon 现值）；非法 → invalid_input。
        //   2. 若 arg 传了合法 management_url：持久化到 UCI（非机密）。
        //   3. resolve_netbird_bin（未安装 → not_installed）。
        //   4. 组命令 netbird up --no-browser [--management-url..][--setup-key..]（全 shell_quote）。
        //   5. 有界认证命令 exec，返回后同步轮询 management.connected（轮询确认）。
        //   6. setup_key 局部变量用完置空；超时 → connect_failed。
        do_up: {
            args: { management_url: '', setup_key: '', caller: '' },
            call: _safe(function(req) {
                let a = (req != null && req.args != null) ? req.args : (req || {});
                let arg_url = (type(a.management_url) == 'string') ? a.management_url : '';
                let setup_key = (type(a.setup_key) == 'string') ? a.setup_key : '';  // 瞬时

                let mr = _resolve_mgmt_url(arg_url);
                if (!mr.ok)
                    return err(CODE.INVALID_INPUT, mr.message);

                // 仅当 caller 显式传入合法 url 才持久化（非机密）
                if (length(arg_url) > 0)
                    _persist_mgmt_url(arg_url);

                // 首连兜底:配置来源=release(默认)但 release 未就位时,先下载并切到 release
                // (用户拍板:首连自动下 release;失败则用 feed 兜底,绝不阻断本次连接)。release
                // 就位后 no-op。注:首次会增加 ~数十秒下载耗时(前端 do_up 已是长调用,见上轮询说明)。
                _ensure_configured_binary();

                let bin = resolve_netbird_bin();
                if (bin == null)
                    return err(CODE.NOT_INSTALLED, 'The netbird binary is not installed.');

                // 分叉自愈：daemon 持有的 management URL 与本次期望不一致时，up 前先 down。
                // daemon 启动时可能从磁盘读入过期/默认 ManagementURL（如旧版本包写下的遗留
                // 默认值，或配置目录落在 tmpfs、重启后被持久的旧文件重新播种），随后
                // auto-connect 引擎对旧地址持续重试；引擎忙时 Login 请求推不进，
                // `up --management-url` 在有界墙钟内写不进新 URL。down 停掉引擎后，同样的
                // up 数秒内即可把新 URL 写进 daemon 配置（写入先于登录完成，不依赖登录
                // 成功）。仅在确认分叉时 down：URL 一致的瞬时断连不能无差别 down——
                // 管理面断连期间 P2P 数据面可能仍在工作。
                if (mr.url != null) {
                    let held = _daemon_mgmt_url(bin);
                    if (held != null && _norm_mgmt_url(held) != _norm_mgmt_url(mr.url))
                        _exec_short_verb(bin, 'down');
                }

                let reconnect_with_existing_identity = (length(setup_key) == 0);
                // watchdog 发起的重连只是"执行已有意图",不应改写 desired_connected;只有用户发起的
                // 连接才预置 desired=1(表达意图,即便本次超时也让 watchdog 续连)。否则 watchdog 会反复
                // 把刚被认证 fatal/key 超时刻意清成 0 的 desired 重新写回 1,使刻意的停止无法生效。
                let from_watchdog = (type(a.caller) == 'string' && a.caller == 'watchdog');
                if (reconnect_with_existing_identity && !from_watchdog)
                    _set_desired_connected(true);

                let auth_log_before = _recent_auth_log_text().text;
                let cmd = _build_auth_cmd(bin, 'up', mr.url, setup_key);
                // watchdog 的周期重连用短墙钟 + 短确认轮询:管理端不可达时 netbird up 内部
                // backoff 不返回,每次尝试都会跑满墙钟;同脚本 RPC 串行使状态页在此期间排队,
                // 长尝试 = 页面长时间假死。健康恢复场景 up 几秒即返回,10s 足够;真不可达时
                // 缩短的只是「注定失败的等待」,下一轮尝试与 30s 状态巡检兜底恢复。
                // 用户点击的连接保持 25s/6 轮:错误归因需要让 CLI/daemon 日志有时间沉淀。
                let r = _exec_auth_cmd(cmd, 4096, from_watchdog ? 10 : 25); // shell-audit-ok: bin/url/key 均经 shell_quote，verb 字面
                // 安全加固：若 CLI 把 setup_key 回显进 stdout，先脱敏再用于任何错误回传。
                if (length(setup_key) > 0 && r.stdout != null)
                    r.stdout = replace(r.stdout, setup_key, '***');

                // 认证 fatal 早退：CLI 被墙钟杀掉（stdout 带 wrapper 的 timed out 标记）
                // 且日志已沉淀可归因的认证错误（如 setup key 被拒）时，_poll_connected
                // 纯属白等——daemon 对无效/过期 key 无限 backoff，绝不会自行连上；而
                // uhttpd 对浏览器 /ubus 调用有 60s 硬上限（script_timeout 默认值），多等的轮询会
                // 把总墙钟推过掐断线，前端只能收到裸 -32003 而非下面的归因文案。
                // 门槛必须含"CLI 是被杀的"：有效 key 的成功登录 CLI 会在墙钟内自行
                // 返回（不带标记），不会进此分支——成功路径中 daemon 早期也可能落
                // PermissionDenied/no peer auth method 之类瞬时行，仅凭日志归因会误杀。
                let cli_timed_out = !!match(r.stdout || '', /netbird command timed out after/);
                if (cli_timed_out) {
                    let early_auth = _auth_failure_from_attempt(r.stdout || '', auth_log_before);
                    if (early_auth != null) {
                        setup_key = '';
                        _exec_short_verb(bin, 'down');
                        _set_desired_connected(false);
                        _persist_runtime_error(early_auth.message);
                        return err(CODE.CONNECT_FAILED, early_auth.message, early_auth.hint);
                    }
                }

                // exec 后同步轮询确认（不信任 up 退出码本身）
                let poll = _poll_connected(bin, from_watchdog ? 3 : 6);
                if (poll.connected) {
                    // 认证成功：把本次 setup_key 算成打码 hint 存 UCI（只存打码串，原始 key 用完即弃）。
                    if (length(setup_key) > 0)
                        _persist_setup_key_hint(setup_key);
                    setup_key = '';  // 立即清零瞬时密钥（密钥绝不入 UCI）
                    // 重连后定向 flush 经 netbird 设备路由的在途 conntrack:断开期间被钉在错误路由
                    // (br-lan)的持续转发流(LAN 主机 ping -t 对端子网)不会自愈,flush 后即恢复
                    // (断开期间被钉错路由的流不自愈,flush 后恢复)。只 flush wtX-routed 目的,绝不全表(安全红线)。
                    _flush_reconnect_conntrack();
                    let mgmt = (poll.json != null && poll.json.management != null) ? poll.json.management : {};
                    _set_desired_connected(true);
                    _clear_runtime_error();
                    return ok({
                        connected: true,
                        management_url: mgmt.url || mr.url || '',
                        netbirdIp: (poll.json != null) ? (poll.json.netbirdIp || '') : '',
                    });
                }
                setup_key = '';  // 超时分支同样清零瞬时密钥（密钥绝不入 UCI）
                let auth = _auth_failure_from_attempt(r.stdout || '', auth_log_before);
                if (auth != null) {
                    _exec_short_verb(bin, 'down');
                    _set_desired_connected(false);
                    _persist_runtime_error(auth.message);
                    return err(CODE.CONNECT_FAILED, auth.message, auth.hint);
                }
                // 先分类 transient(管理端不可达/DNS/连接拒绝/超时),拿到比泛化超时更可定位的原因;
                // 两条路径都复用它,带 key 路径不再丢失具体原因。
                let transient = _classify_transient_connect_failure((r.stdout || '') + '\n' + _recent_log_text(80));
                if (!reconnect_with_existing_identity) {
                    // 带 setup key 的首连超时(非 fatal):netbird daemon 仍会在后台用该 key 续试注册,
                    // 前端已判失败 → 显式 down 停住后台续试,并清 desired_connected:该位可能早被之前的
                    // 成功连接/watchdog adopt 置 1,若不清,watchdog 下一轮会用空 key 把连接拉回、抵消
                    // 这里的 down。停止后需用户重新点击连接。
                    _exec_short_verb(bin, 'down');
                    _set_desired_connected(false);
                    let msg = (transient != null) ? transient.message
                        : 'NetBird did not become connected before the timeout.';
                    _persist_runtime_error(msg);
                    return err(CODE.CONNECT_FAILED, msg,
                        'Check the Logs tab for the last NetBird message, then try again.');
                }
                // 空 key 重连超时:desired_connected=1,交 watchdog 继续重连(transient 提示会持续重连)。
                if (transient != null) {
                    _persist_runtime_error(transient.message);
                    return err(CODE.CONNECT_FAILED, transient.message, transient.hint);
                }
                _persist_runtime_error('NetBird did not become connected before the timeout.');
                return err(CODE.CONNECT_FAILED,
                    'NetBird did not become connected before the timeout.',
                    'Check the Logs tab for the last NetBird message, then try again.');
            }),
        },

        // do_down — 仅断开当前会话，保留认证（与 do_logout 语义区别）。
        // 幂等：本就断开也算成功（netbird down 在未连态退 0 或可忽略错误）。
        do_down: {
            args: {},
            call: _safe(function() {
                let bin = resolve_netbird_bin();
                if (bin == null)
                    return err(CODE.NOT_INSTALLED, 'The netbird binary is not installed.');
                let r = _exec_short_verb(bin, 'down');
                // 幂等：down 即便因「本就断开」非零退出也视为成功；仅 popen 失败(-1)透传。
                if (r.code == -1)
                    return err(CODE.CLI_ERROR, r.stdout || 'netbird down failed');
                _set_desired_connected(false);
                _clear_runtime_error();
                return ok({ connected: false });
            }),
        },

        // do_login — 仅认证不拉起连接（与 do_up 区别）。
        // args { management_url, setup_key } 同 do_up 瞬时处理；不轮询 connected（login 不建连）。
        do_login: {
            args: { management_url: '', setup_key: '' },
            call: _safe(function(req) {
                let a = (req != null && req.args != null) ? req.args : (req || {});
                let arg_url = (type(a.management_url) == 'string') ? a.management_url : '';
                let setup_key = (type(a.setup_key) == 'string') ? a.setup_key : '';  // 瞬时

                let mr = _resolve_mgmt_url(arg_url);
                if (!mr.ok)
                    return err(CODE.INVALID_INPUT, mr.message);
                if (length(arg_url) > 0)
                    _persist_mgmt_url(arg_url);

                let bin = resolve_netbird_bin();
                if (bin == null)
                    return err(CODE.NOT_INSTALLED, 'The netbird binary is not installed.');

                let auth_log_before = _recent_auth_log_text().text;
                let cmd = _build_auth_cmd(bin, 'login', mr.url, setup_key);
                let r = _exec_auth_cmd(cmd, 4096); // shell-audit-ok: bin/url/key 均经 shell_quote，verb 字面
                // 安全加固：若 CLI 把 setup_key 回显进 stdout，先脱敏再用于任何错误回传。
                if (length(setup_key) > 0 && r.stdout != null)
                    r.stdout = replace(r.stdout, setup_key, '***');

                if (r.code == 0) {
                    // 登录成功：存打码 hint（只存打码串，原始 key 用完即弃）。
                    if (length(setup_key) > 0)
                        _persist_setup_key_hint(setup_key);
                    setup_key = '';  // 立即清零瞬时密钥（密钥绝不入 UCI）
                    _clear_runtime_error();
                    return ok({ logged_in: true });
                }
                setup_key = '';  // 失败分支同样清零瞬时密钥（密钥绝不入 UCI）
                let auth = _auth_failure_from_attempt(r.stdout || '', auth_log_before);
                if (auth != null) {
                    _exec_short_verb(bin, 'down');
                    _set_desired_connected(false);
                    _persist_runtime_error(auth.message);
                    return err(CODE.CONNECT_FAILED, auth.message, auth.hint);
                }
                _persist_runtime_error('Login failed before NetBird accepted the setup key.');
                return err(CODE.CONNECT_FAILED,
                    'Login failed before NetBird accepted the setup key.',
                    'Check the Logs tab for the last NetBird message, then try again.');
            }),
        },

        // do_logout — 完整登出：netbird down 后 netbird deregister（别名 logout）。
        // 会从管理端注销并删本地身份；与 do_down 语义不同（UI 必须区分）。
        // 注：deregister 后需重新用 setup-key 登录，不可仅靠 do_up 现有身份重连。
        //
        // args.local_only='1' — 本地身份清除兜底：deregister 必须管理服务器配合,服务器
        // 重建/不可达/已删本机时只会一直失败,旧身份卡死在设备上。此分支不调 deregister,
        // 改为 down → 停 daemon → 删本地 config.json → 重启 daemon(回到待登录态)。
        // 服务器端的 peer 记录不受影响,需用户在控制台自行删除(前端确认弹窗已说明)。
        // 注:config.json 的"只读"基线约束的是 read 方法(禁绕过 CLI 语义读状态);
        // 本分支是用户二次确认后的显式销毁动作,且删除前 daemon 已停,无一致性风险。
        do_logout: {
            args: { local_only: '' },
            call: _safe(function(req) {
                let a = (req != null && req.args != null) ? req.args : (req || {});
                let local_only = (type(a.local_only) == 'string' && a.local_only == '1');

                if (local_only) {
                    _set_desired_connected(false);
                    let bin = resolve_netbird_bin();
                    if (bin != null)
                        _exec_short_verb(bin, 'down');     // 幂等,断开在途连接,忽略非零
                    _run_init('stop');                     // 删配置前必须停 daemon(否则内存身份继续重连)
                    let removed = _wipe_local_identity();
                    if (removed < 0) {
                        _run_init('start');
                        return err(CODE.CLI_ERROR, 'Failed to remove the local NetBird configuration files.');
                    }
                    _run_init('start');                    // 拉回 daemon,页面回到待登录态
                    _clear_runtime_error();
                    return ok({ logged_out: true, local_only: true, removed_files: removed });
                }

                let bin = resolve_netbird_bin();
                if (bin == null)
                    return err(CODE.NOT_INSTALLED, 'The netbird binary is not installed.');
                _set_desired_connected(false);
                // 先 down（幂等，忽略非零）再 deregister
                _exec_short_verb(bin, 'down');
                let r = _exec_short_verb(bin, 'deregister');
                if (r.code == -1)
                    return err(CODE.CLI_ERROR, r.stdout || 'netbird deregister failed');
                // deregister 非零分两种，绝不一概当成功（否则真失败也误报「本地身份已删除」误导用户）：
                //   (a) 本就无身份/已注销 → netbird 返 gRPC NotFound / "peer not found" / "not registered"
                //       （nb 0.66.2 实际输出: exit 1 "rpc error: code = NotFound desc = ... peer not found"）
                //       → 登出目标已达成，幂等成功；
                //   (b) 管理面不可达/认证失败/CLI 真错（connection refused / deadline / unauthenticated…）
                //       → 不匹配 NotFound 语义 → 透传错误。
                //   ⚠ 注意：**不能靠 probe_state 区分**——down+deregister 后 `netbird status` 文本不再
                //   报 NeedsLogin（某些版本 status 会变 'running'），状态判据失效（曾据此误报错误）。改按
                //   netbird 稳定错误语义（gRPC NotFound）**精确**白名单放行：只认 deregister 专有的
                //   `code = NotFound` / `peer not found` / `not registered`，**不碰泛化 "host not found"**
                //   （DNS 类管理面失败仍被正确报错）。不匹配仅退化为「重复注销显错误」（原 bug，无害），
                //   绝不把真失败误报成功（errs safe，假阳性纪律）。
                if (r.code != 0) {
                    let out = lc(r.stdout || '');
                    let idempotent = match(out, /code\s*=\s*notfound|peer not found|not registered|no such peer/);
                    if (!idempotent)
                        return err(CODE.CLI_ERROR,
                            'Deregister failed (rc=' + r.code + '): ' + (r.stdout || 'unknown error'));
                }
                _clear_runtime_error();
                return ok({ logged_out: true });
            }),
        },

        // do_enable_and_start — 启用并启动 daemon 写方法。
        // 决策树：
        //   step 1 running/needs_login 双 early-return（不调 init start；避免 false start_failed）
        //   step 2 not_installed → err NOT_INSTALLED
        //   step 3 service_disabled → _run_init('enable')；失败 err ENABLE_FAILED
        //   step 4 _run_init('start')；失败 err START_FAILED（不回滚已成功的 enable）
        //   step 5 重跑 probe_state()；running/needs_login 合法终态 ok + already:false；其他 err START_FAILED
        // 所有 init 子进程调用走 _run_init：白名单 + 5s timeout。
        do_enable_and_start: {
            args: {},
            call: _safe(function() {
                let st = probe_state();

                // step 1 — already running 或 needs_login 都短路（双 early-return）
                if (st.status == 'running' || st.status == 'needs_login') {
                    _mark_service_enabled();  // 修正主开关显示（服务实际在跑则 UCI 应为 '1'）
                    return ok({ state: st.status, already: true });
                }

                // step 2 — not_installed 直接拒
                if (st.status == 'not_installed')
                    return err(CODE.NOT_INSTALLED, 'The netbird binary is not installed.');

                // step 3 — service_disabled 先 enable
                if (st.status == 'service_disabled') {
                    let rc_en = _run_init('enable');
                    if (rc_en.code != 0)
                        return err(CODE.ENABLE_FAILED, rc_en.stderr || 'init enable returned a non-zero exit code');
                }

                // step 4 — start（service_stopped 或刚 enable 完）
                let rc_start = _run_init('start');
                if (rc_start.code != 0)
                    return err(CODE.START_FAILED, rc_start.stderr || 'init start returned a non-zero exit code');

                // step 5 — 重探测（running 或 needs_login 都算成功终态）
                let st2 = probe_state();
                if (st2.status == 'running' || st2.status == 'needs_login') {
                    _mark_service_enabled();  // 「启用并启动」成功 → UCI service_enabled=1，与设置页一致
                    return ok({ state: st2.status, already: false });
                }

                return err(CODE.START_FAILED, `post-start state: ${st2.status}`);
            }),
        },
        // OpenWRT 自动化（zone 直接绑定 netbird 设备，不建 network 接口）。幂等 named section,
        // 安全红线见各 _do_* 注释。注：zone 设备直绑设计已移除 setup_network（zone 直接 list device 绑定）。
        setup_firewall_zone:   { args: {},  call: _safe(_do_setup_firewall_zone) },
        setup_forwarding:      { args: { lan_to_netbird: false, netbird_to_lan: false }, call: _safe(_do_setup_forwarding) },
        // teardown_automation — setup_* 逆操作（删 zone+两条 forwarding + 旧版残留 iface，幂等，
        // 绝不碰 lan/wan，不杀 wtX 设备）。破坏性 → 前端二次确认。ACL: 已加入 write.ubus.luci.netbird。
        teardown_automation:   { args: {},  call: _safe(_do_teardown_automation) },

        // update_binary — 下载官方/镜像 release 二进制,校验(sha256/ELF/arch/可执行)后装到
        // _NB_REL_BIN（绝不直写 /usr/bin/netbird）；备份+失败还原。args.url 空=GitHub latest。
        // ACL: 方法名已加入 write.ubus.luci.netbird（一字不差）。
        update_binary:         { args: { url: '', checksum: '' },  call: _safe(_do_update_binary) },
        // start_binary_update — 为 LuCI 前端启动独立后台 worker 跑 update_binary,让 rpcd 可继续响应
        // 进度轮询/停止按钮。ACL: 方法名已加入 write.ubus.luci.netbird（一字不差）。
        start_binary_update:   { args: { url: '', checksum: '' },  call: _safe(_do_start_binary_update) },
        // cancel_binary_update — 请求停止当前二进制下载。下载器看到取消文件后清理并返回 download_canceled。
        // ACL: 方法名已加入 write.ubus.luci.netbird（一字不差）。
        cancel_binary_update:  { args: {}, call: _safe(_do_cancel_binary_update) },
        // set_binary_source — 切换 daemon 运行的二进制来源(release/opkg/custom;custom 带 version);
        // 破坏性 → 前端确认。ACL: 方法名已加入 write.ubus.luci.netbird（一字不差）。
        set_binary_source:     { args: { source: '', version: '' }, call: _safe(_do_set_binary_source) },
        // delete_custom_binary — 删非 active 的自定义下载版本(多版本盘面清理)。
        // ACL: 方法名已加入 write.ubus.luci.netbird（一字不差）。
        delete_custom_binary:  { args: { version: '' }, call: _safe(_do_delete_custom_binary) },
        // update_luci_app — 从 luci-app-netbird.okk.sh 对应 OpenWrt 系列目录下载并安装 LuCI 包。
        // ACL: 方法名已加入 write.ubus.luci.netbird（一字不差）。
        update_luci_app:       { args: {}, call: _safe(_do_update_luci_app) },

        // install_iface_backend — 高置信缺 WG+TUN 时一键装 kmod-wireguard（优先）/ kmod-tun。
        // 装完复验 probe_iface_backend；失败原样回传包管理器输出。ACL: write 段已同步。
        install_iface_backend: { args: {}, call: _safe(_do_install_iface_backend) },

        // select_exit_node — 切换/关闭 exit node。args.id：目标 exit node ID，'' = 关闭。
        // 流程：白名单校验（目标必须在当前 list 的 exit node 集内，任意字符串到不了 CLI）
        //   → 先 deselect 其余全部 exit node → 再 select -a 目标 → 回读最终态返回。
        // 先 deselect 后 select 的显式互斥不依赖上游版本：0.74 的 daemon 侧互斥只在
        // network map 对账时生效（select 当下不强制），更旧版本完全没有互斥逻辑。
        // 关闭（id=''）对全部 exit node 记显式 deselect，管理端 auto-apply 不会再压回来。
        // ACL: 方法名已加入 write.ubus.luci.netbird（一字不差）。
        select_exit_node: {
            args: { id: '' },
            call: _safe(function(req) {
                let a = (req != null && req.args != null) ? req.args : (req || {});
                let id = (type(a.id) == 'string') ? trim(a.id) : '';
                // 防御性拒绝：超长、控制字符、CLI 保留关键字 'all'（唯一参数时被
                // 解释为全选/全清）。'-' 开头的 id 无需拒绝——_exec_networks 用 `--`
                // 终止 flag 解析后可安全透传（与 list 白名单口径一致）。
                if (length(id) > 256 || index(id, '\n') >= 0 || index(id, '\r') >= 0 || id == 'all')
                    return err(CODE.INVALID_INPUT, 'Invalid exit node id.');

                let g = _require_running();
                if (g._gate) return g._gate;
                let js = g._json;
                if (!(js != null && js.management != null && js.management.connected))
                    return err(CODE.CLI_ERROR, 'NetBird is not connected to the management server.');

                let bin = g._state.bin_path;
                let res = _collect_exit_nodes(bin);
                if (!res.ok)
                    return err(CODE.CLI_ERROR, res.message);

                let target = null;
                let others = [];
                for (let n in res.exit_nodes) {
                    if (length(id) > 0 && n.id == id)
                        target = n;
                    else
                        push(others, n.id);
                }
                if (length(id) > 0 && target == null)
                    return err(CODE.INVALID_INPUT, `Exit node not found: ${id}`);

                if (length(others) > 0) {
                    let rd = _exec_networks(bin, 'deselect', others, false);
                    if (rd.code != 0)
                        return err(CODE.CLI_ERROR, trim(rd.stdout) || 'netbird networks deselect failed');
                }
                if (target != null) {
                    let rs = _exec_networks(bin, 'select', [ id ], true);
                    // deselect 已生效而 select 失败时,净效果是"全部关闭"而非维持原状,
                    // 错误信息须提示核对当前状态,避免用户以为切换前的节点还开着。
                    if (rs.code != 0)
                        return err(CODE.CLI_ERROR,
                            (trim(rs.stdout) || 'netbird networks select failed') +
                            ' (other exit nodes may already be deselected; check the current state)');
                }

                // 回读 daemon 实际状态返回（不回显期望值），前端据此原地刷新。
                let after = _collect_exit_nodes(bin);
                if (!after.ok)
                    return err(CODE.CLI_ERROR, after.message);
                return ok({ exit_nodes: after.exit_nodes });
            }),
        },
    },
};
