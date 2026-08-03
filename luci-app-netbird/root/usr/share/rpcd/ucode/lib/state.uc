// SPDX-License-Identifier: Apache-2.0
//
// Canonical runtime path: /usr/share/rpcd/ucode/lib/state.uc
// Repo canonical source:  root/usr/share/rpcd/ucode/lib/state.uc
//
// state.uc — 5 态判定算法（runtime-first）+ WireGuard/TUN 后端只读能力探测
//
// 关键设计：
//   旧顺序：bin → enabled → running → needs_login → running
//   新顺序：bin → runtime(ubus/pgrep) → needs_login(running 子分支) → enabled
//   原因：service disabled 但用户手动 netbird service run 在旧顺序下被误判为
//   service_disabled 空态；改为 runtime-first 后，service_disabled
//   只在 (!running && !enabled) 时返回。
//
// 返回纯 dict（不套信封）：
//   { status, bin_path, init_enabled?, init_running?, raw_text?, iface_backend }
//   iface_backend: { ready, wireguard, tun }
//     ready=false 仅在「高置信两个后端都不可用」时；存疑时 ready=true（宁漏报不误报）
//
// module-compat：作为 ucode 模块经 loadfile()() 加载，返回 { probe_state }。
// 依赖 paths/netbird_cli/shell 也走 loadfile，路径 NBLIB env override。

import { popen, access, open } from 'fs';

const _LIB = getenv('NBLIB') || '/usr/share/rpcd/ucode/lib';
let _paths = loadfile(_LIB + '/paths.uc')();
let _cli = loadfile(_LIB + '/netbird_cli.uc')();
let _shell = loadfile(_LIB + '/shell.uc')();
let resolve_netbird_bin = _paths.resolve_netbird_bin;
let classify_status_text = _cli.classify_status_text;
let probe_running_via_ubus = _cli.probe_running_via_ubus;
let shell_quote = _shell.shell_quote;

// _HAS_TIMEOUT：BusyBox 1.36.1 默认未携带 timeout applet；
// 缺失时降级为透传命令；保留字面 "timeout 5s" 标明超时(5s)设计。
const _HAS_TIMEOUT = access('/usr/bin/timeout', 'x') || access('/bin/timeout', 'x');

function _t(cmd) {
    if (_HAS_TIMEOUT)
        return 'timeout 5s ' + cmd;
    return cmd;
}

// 读小文件；失败返 null。只读、有上限，避免把大文件拖进 get_status 热路径。
function _read_small(path, max_bytes) {
    let fd = open(path, 'r');
    if (fd == null)
        return null;
    let text = fd.read('all');
    fd.close();
    if (text == null)
        return null;
    if (max_bytes != null && length(text) > max_bytes)
        text = substr(text, 0, max_bytes);
    return text;
}

// 在 modules root 下按常见相对目录探测 name.ko（含常见压缩后缀）。
// 不 walk 整树：netbird 自己会 lazy-load，我们只需「.ko 是否在磁盘上」的廉价证据。
function _ko_present(root, name, rel_dirs) {
    let suffixes = [ '.ko', '.ko.gz', '.ko.xz', '.ko.zst' ];
    for (let d in rel_dirs) {
        for (let sfx in suffixes) {
            if (access(root + '/' + d + name + sfx, 'f') || access(root + '/' + d + name + sfx, 'r'))
                return true;
        }
    }
    return false;
}

// modules.dep / modules.builtin 文本里是否出现「路径末端的 name.ko」
// （避免把名字当子串误匹配）。
function _mod_inventory_has(text, name) {
    if (text == null || length(text) == 0)
        return false;
    // e.g. kernel/drivers/net/wireguard/wireguard.ko:  or  .../tun.ko
    return match(text, regexp('(^|/)(' + name + ')\\.ko')) != null;
}

// /proc/modules 行首模块名匹配（字段以空白分隔）。
function _proc_modules_has(text, name) {
    if (text == null || length(text) == 0)
        return false;
    return match(text, regexp('(^|\n)' + name + '[\t ]')) != null;
}

// ============================================================================
// probe_iface_backend() —— 只读、无副作用的 WireGuard / TUN 能力探测
// ============================================================================
// 与 netbird client/iface 选择逻辑对齐（kernel WG → wireguard-go+TUN），但：
//   - 绝不 modprobe/insmod/netlink 建链（get_status 被轮询，且误报代价高）
//   - 「当前未加载」≠「不可用」：磁盘上有 .ko / modules.dep 条目即可被 netbird lazy-load
//   - 「无 .ko、无 /sys/module」可能是把 WG 编进内核的固件 → 必须能读到
//     modules.builtin 并确认未列出，才敢宣称缺失；否则 ready 保持 true（沉默）
//
// 返回 { ready, wireguard, tun }：
//   ready=false → 高置信两者皆不可用，前端可提示装 kmod-wireguard / kmod-tun
//   ready=true  → 至少一端有正证据，或证据不足（宁漏报）
function probe_iface_backend() {
    let wg = false;
    let tun = false;

    // --- 快路径：已加载 / 已有设备节点（各一次 access，最常见健康机直接返回）---
    if (access('/sys/module/wireguard', 'r') || access('/sys/module/wireguard', 'f'))
        wg = true;
    if (access('/dev/net/tun', 'r') || access('/dev/net/tun', 'f'))
        tun = true;
    if (!tun && (access('/sys/module/tun', 'r') || access('/sys/module/tun', 'f')))
        tun = true;

    if (wg || tun)
        return { ready: true, wireguard: wg, tun: tun };

    // --- /proc/modules：已加载但 sysfs 异常时的兜底（文件很小）---
    let proc_mods = _read_small('/proc/modules', 65536);
    if (_proc_modules_has(proc_mods, 'wireguard'))
        wg = true;
    if (_proc_modules_has(proc_mods, 'tun'))
        tun = true;
    if (wg || tun)
        return { ready: true, wireguard: wg, tun: tun };

    // --- 内核模块目录：.ko / modules.dep / modules.builtin ---
    // 用 osrelease 文件避免再起 uname 子进程。
    let krel = trim(_read_small('/proc/sys/kernel/osrelease', 256) || '');
    if (length(krel) == 0)
        return { ready: true, wireguard: false, tun: false };  // 无法锚定 modules 树 → 沉默

    let root = '/lib/modules/' + krel;
    let builtin = _read_small(root + '/modules.builtin', 262144);
    let dep = _read_small(root + '/modules.dep', 1048576);

    // 两份清单都读不到：可能是静态内核 / 容器 host 内核与 rootfs 不匹配。
    // 此时不能区分「编进内核」与「真的没有」→ 沉默。
    if (builtin == null && dep == null)
        return { ready: true, wireguard: false, tun: false };

    if (_mod_inventory_has(builtin, 'wireguard') || _mod_inventory_has(dep, 'wireguard'))
        wg = true;
    if (_mod_inventory_has(builtin, 'tun') || _mod_inventory_has(dep, 'tun'))
        tun = true;

    // modules.dep 未跑 depmod 时的常见路径兜底（仍只 access，不 walk）。
    if (!wg)
        wg = _ko_present(root, 'wireguard', [ '', 'kernel/drivers/net/wireguard/', 'updates/' ]);
    if (!tun)
        tun = _ko_present(root, 'tun', [ '', 'kernel/drivers/net/', 'kernel/drivers/net/tun/', 'updates/' ]);

    if (wg || tun)
        return { ready: true, wireguard: wg, tun: tun };

    // 高置信「双缺」：必须能读 modules.builtin，才能排除「WG=y 编进内核、无 .ko」的误报。
    // 仅有 modules.dep 时 built-in 不会出现在 dep 里 → 仍沉默。
    if (builtin == null)
        return { ready: true, wireguard: false, tun: false };

    return { ready: false, wireguard: false, tun: false };
}

// ============================================================================
// probe_state() —— 5 态判定（runtime-first）
// ============================================================================
// 返回 { status, bin_path, init_enabled?, init_running?, raw_text?, iface_backend }
//
// 顺序（短路）：
//   step 1. resolve_netbird_bin() == null → 'not_installed'
//   step 2. ubus probe_running_via_ubus() 主判定 → running_flag
//           pgrep -f '^<bin> service run' 兜底（procd 读不到 pidfile 时）
//   step 3. running_flag == true → 跑 `<bin> status`（不带 --json），文本分类：
//             - classify_status_text() 命中 → 'needs_login'
//             - 否则 → 'running'
//   step 4. running_flag == false → 判 /etc/init.d/netbird enabled 退出码：
//             - 非 0 → 'service_disabled'  (!running && !enabled)
//             - 0    → 'service_stopped'   (!running && enabled)
//
// 不抛异常；任何子进程异常返保守上位（false / 空串）以保证返回结构稳定。
function probe_state() {
    let st;

    // step 1: binary 路径探测
    let bin = resolve_netbird_bin();
    if (bin == null) {
        st = { status: 'not_installed', bin_path: null };
    } else {
        // step 2: runtime-first（ubus 主 + pgrep 兜底）
        let ub = probe_running_via_ubus();
        let running_flag = !!ub.running;

        if (!running_flag) {
            // pgrep 兜底：BusyBox pgrep -f 锚定 '^<bin> service run'
            // shell_quote 包模式串防注入；timeout 5s 防 hang；rc==0 即命中。
            let pgrep_pat = '^' + bin + ' service run';
            let pg_cmd = _t('pgrep -f ' + shell_quote(pgrep_pat) + ' >/dev/null 2>&1');
            let pg_rc = system(pg_cmd);
            if (pg_rc == 0)
                running_flag = true;
        }

        // step 3: running 子分支 → needs_login 文本分类 vs running
        if (running_flag) {
            // 跑 `<bin> status`（不带 --json）
            let status_cmd = _t(shell_quote(bin) + ' status 2>&1');
            let fd = popen(status_cmd, 'r');
            let stdout = '';
            if (fd != null) {
                stdout = fd.read('all') || '';
                fd.close();
            }
            let raw = substr(stdout, 0, 512);
            if (classify_status_text(raw) == 'needs_login') {
                st = {
                    status: 'needs_login',
                    bin_path: bin,
                    init_enabled: true,    // procd 在跑 → init 必然 enabled or 用户 manual run
                    init_running: true,
                    raw_text: trim(raw),
                };
            } else {
                st = {
                    status: 'running',
                    bin_path: bin,
                    init_enabled: true,
                    init_running: true,
                };
            }
        } else {
            // step 4: 非 running → /etc/init.d/netbird enabled 区分 disabled vs stopped
            // 注：/etc/init.d/netbird enabled 不接用户输入，命令字面安全；timeout 5s 防 hang。
            let en_rc = system(_t('/etc/init.d/netbird enabled'));
            if (en_rc != 0) {
                st = {
                    status: 'service_disabled',
                    bin_path: bin,
                    init_enabled: false,
                    init_running: false,
                };
            } else {
                st = {
                    status: 'service_stopped',
                    bin_path: bin,
                    init_enabled: true,
                    init_running: false,
                };
            }
        }
    }

    // 附加只读能力探测；失败时不阻断 5 态（降级为 ready:true 沉默）。
    try {
        st.iface_backend = probe_iface_backend();
    }
    catch (e) {
        st.iface_backend = { ready: true, wireguard: false, tun: false };
    }
    return st;
}

return { probe_state };
