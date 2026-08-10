# Changelog

All notable changes to this project are documented here.
This project adheres to [Semantic Versioning](https://semver.org/).

## 0.1.0-r19 — 2026-08-10

### Fixed

- The in-app updater no longer installs the Simplified Chinese translation package on systems that never had it (#3, follow-up report by [@Kopterlove](https://github.com/Kopterlove)). It used to download and install the translation package unconditionally alongside the main package, and installing it re-registers Chinese in LuCI's language list — so updating from the Version tab brought Chinese back on English-only systems, undoing the r9 cleanup. The updater now upgrades the translation package only when it is already installed, and never introduces it. Note: the update **to** r19 itself still runs under the old updater code, so affected routers should clean up once afterwards: `opkg remove luci-i18n-netbird-zh-cn` (apk-based systems: `apk del luci-i18n-netbird-zh-cn`), then `uci -q delete luci.languages.zh_cn && uci commit luci`; if the UI language itself got switched, `uci set luci.main.lang='auto' && uci commit luci`. As usual, reboot once after upgrading (or restart rpcd) so the updated backend loads.

## 0.1.0-r18 — 2026-08-10

### Fixed

- Unchecking a boolean setting now actually takes effect (#9, reported with a spot-on analysis by [@mipa87](https://github.com/mipa87)). The netbird daemon keeps its previously persisted value for any flag omitted from `netbird up`, and the app only passed boolean flags when they were switched on — so switching one off (Rosenpass Permissive, inbound blocking, SSH options, and every other toggle) silently kept the old value. All boolean settings are now passed explicitly as `--flag=true/false`, pinning the daemon to the configured state; applying settings once also heals any value stuck from before. Each flag is additionally capability-gated against the running binary's `netbird up --help` — a side benefit is that applying settings now works at all on the very old netbird shipped by the 22.03/23.05 package feeds, which used to hard-fail on flags those binaries don't know. Takes effect on the first Save & Apply after upgrading — no reboot needed.

## 0.1.0-r17 — 2026-08-09

### Fixed

- LuCI could show NetBird as Disconnected while the connection was actually fine (#8). The backend read `netbird status --json` with an 8 KB cap; on larger meshes — or once an exit node is selected — the output exceeds it, the truncated JSON fails to parse, and every status read in the app reports Disconnected (exit-node switching also showed `"status --json" did not return JSON`). The cap is now 256 KB. Display-only: the connection itself was never affected. As usual, reboot once after upgrading (or restart rpcd) so the updated backend loads.

## 0.1.0-r16 — 2026-08-07

### Fixed

- The automatic-reconnect watchdog could stall silently after a single failed reconnect attempt (#7). A failed attempt — for example at boot, when the uplink or DNS is not ready yet, common when the only uplink is a Wi-Fi repeater that associates late — can leave the netbird daemon in the `LoginFailed` state, whose plain status output is just a login hint that matches none of the watchdog's known patterns; the watchdog then polled forever without retrying, and only a manual disable/enable cycle recovered the connection. The watchdog now reads the machine-readable status first, and whenever automatic reconnect is on and the daemon is not connected — and the state is not a definitive authentication failure — it keeps retrying with the existing backoff, logging any unrecognized state instead of going quiet. Deliberate side effect: a plain `netbird down` on the command line is now also reconnected automatically while automatic reconnect is on; disconnect from the app's UI if you want to stay down.
- The in-app updater rejected branch-snapshot firmwares such as `23.05-SNAPSHOT` (as shipped by GL.iNet 4.x) with `Unsupported OpenWrt release` (#7). It now recognizes any supported branch (22.03 / 23.05 / 24.10 / 25.12) regardless of the version suffix, matching what the install script already accepted; apk-based main-branch `SNAPSHOT` builds map to the 25.12 feed.

### Changed

- README and the website now state explicitly that OpenWrt 21.02 and older cannot be supported: their package feeds lack `ucode` / `rpcd-mod-ucode`, which the backend runs on.

## 0.1.0-r15 — 2026-08-05

### Fixed

- Devices no longer lose their self-hosted management server after a reboot (#7). On firmwares whose `netbird` package starts the daemon without pinning a config path (the 23.05 feed's netbird 0.24.x — as shipped on GL.iNet firmware 4.x, among others), the 0.7x binary keeps its live config under `/var/lib/netbird`, which sits in RAM on OpenWrt. Every boot re-seeds that config from the stale `/etc/netbird/config.json` the old package wrote on its very first start, resurrecting the long-dead `api.wiretrustee.com` default; a plain reconnect could not push the correct URL into the daemon while it was busy retrying the dead endpoint, so only a manual disable/enable cycle in LuCI helped. The backend now detects that the daemon is running with a management URL different from the configured one and takes the connection down first, which unblocks the re-apply — the automatic-reconnect watchdog then heals a freshly booted router on its own, typically within a minute. Applies whenever a management URL is set in the app; the identity is untouched, so no setup key is needed again. Note: the updated backend loads when rpcd restarts — after upgrading, simply reboot the router once (or run `/etc/init.d/rpcd restart`).

### Added

- OpenWrt / ImmortalWrt **22.03** (`opkg`) support. 22.03 is the oldest series that can run this app — it is the first one shipping `ucode` and `rpcd-mod-ucode`, which the whole backend is written in (21.02 and older ship neither and are rejected by the feed script). The package is architecture-independent and every runtime dependency (`rpcd-mod-ucode`, `ucode`, `conntrack`, `netbird`) exists in the 22.03 feeds, so the 24.10 ipk feed installs there unchanged. The feed script and the in-app updater both recognize 22.03 releases. Verified on OpenWrt 22.03.6: signed-feed install, first-run initialization, every ubus method registering, the settings apply pipeline, and the LuCI pages' API surface. Note: the 22.03 packages feed ships a very old netbird (0.17.x) — connect / status / settings work, but exit-node selection needs netbird 0.35+; switching the binary to the latest official release on the Versions tab is strongly recommended there.
- The Overview and Status pages now detect when neither the WireGuard kernel module nor a TUN device is available, and offer a one-click **Install** button that fetches the needed kernel package for you. NetBird requires one of them to create its interface, stock OpenWrt images ship neither, and the `netbird` package does not depend on them — previously this surfaced only as a service that would not start. The install prefers `kmod-wireguard` and only falls back to `kmod-tun` if the interface backend is still unavailable; it never touches the `netbird` package itself. If the packages cannot be installed the raw package-manager output is shown together with a plain-language reason — most often that the feed's kernel modules do not match the running kernel, which is normal on vendor firmware built with a custom kernel; in that case install modules matching your own kernel. The detection is read-only and stays silent whenever the kernel module tree cannot be inspected confidently, so systems with WireGuard built into the kernel are not flagged, and the button never appears on devices where the interface backend already works.

### Fixed

- The backend could not be parsed by the `ucode` version shipped in older OpenWrt releases, because a local variable used the reserved word `from`. This made the whole app unusable on 22.03 (no ubus methods registered at all).
- The in-app updater reported `Unsupported OpenWrt release` on 22.03, so checking for and installing app updates from the LuCI UI did not work there.

## 0.1.0-r13 — 2026-07-17

### Added

- OpenWrt / ImmortalWrt 23.05 (`opkg`) support (#6, contributed by [@moallemi](https://github.com/moallemi)): the package is architecture-independent and all runtime dependencies (`rpcd-mod-ucode`, `ucode`, `conntrack`, `netbird`) are available in the 23.05 feeds, so the 24.10 ipk feed installs there unchanged. The feed script and the in-app updater now recognize 23.05 releases. Verified on OpenWrt 23.05.4. Note: the 23.05 packages feed ships an old netbird (0.24.x) — connect / status / settings work, but exit-node selection needs netbird 0.35+; switch the binary to the latest official release on the Versions tab.

## 0.1.0-r12 — 2026-07-14

### Added

- Exit node selection on the Network tab (#5): pick any exit node your NetBird management server has granted this router, or switch back to direct internet access. Changes take effect immediately — no save or restart — and are remembered by the NetBird daemon. Internet traffic from the router and from LAN clients using it as gateway follows the selected node; more-specific mesh routes keep working unchanged.

### Changed

- The Hostname setting's help text now explains that the peer name and FQDN are taken from the hostname only when the peer first registers; renaming an already registered device must be done in the NetBird management console.

## 0.1.0-r11 — 2026-07-10

### Fixed

- NetBird pages no longer freeze for long stretches while the management server is unreachable. Background watchdog reconnect attempts now run with a shorter command budget (10s wall clock and 3 confirmation polls instead of 25s and 6): concurrent RPC calls to the backend are serialized, so each doomed retry used to block status reads for up to ~35 seconds. User-initiated connects keep the full budget so authentication errors can still be attributed reliably.

## 0.1.0-r10 — 2026-07-07

### Added

- Recovery path for a rebuilt or unreachable management server: when deregister fails because the server cannot cooperate, the UI now offers to remove the local identity only (with confirmation), so a new setup key can re-register the device.
- `conntrack` is now a package dependency — cancelling a forwarding rule reliably disconnects established flows on every deployment instead of only where the tool happened to be installed.

### Changed

- Authentication-failure hints now explain that entering a new setup key re-registers the device directly — no deregister needed, including after a management-server rebuild.

## 0.1.0-r9 — 2026-07-07

### Added

- Language-split install scripts: `install.sh` installs the app only; the new `install-zh.sh` also installs the Simplified Chinese language pack (#3 follow-up).
- OpenWrt snapshot support: apk-based `SNAPSHOT` builds now use the 25.x package feed — the package is architecture-independent, so it installs there unchanged. Old opkg-based snapshots get a clear unsupported message (#1).

### Fixed

- Uninstall now unregisters the Simplified Chinese entry from the LuCI language list when no other zh-cn language pack remains, and falls back to auto-detection if Chinese was the active UI language (#3).
- On apk systems, uninstalling the LuCI app no longer removes a `netbird` that was installed as its dependency — the client is pinned as explicitly installed before package removal.

### Changed

- Repository links updated to the new GitHub owner (`looong-cat`).

## 0.1.0-r8 — 2026-06-24

### Added

- Automatic reconnect: a watchdog restores the connection after transient management/network outages while the user intends to stay connected; fatal authentication states stop the retries.

### Fixed

- Authentication failures (invalid or revoked setup key, removed peer, expired login, permission errors) are detected and reported with a hint in the UI instead of a generic timeout, and the background retry loop is stopped.

*(PKG_RELEASE 6 and 7 were internal iterations of this work; r8 is the shipped build.)*

## 0.1.0-r5 — 2026-06-24

### Fixed

- UI wording now follows the system package manager (opkg vs apk) instead of always saying opkg.

## 0.1.0-r4 — 2026-06-24

### Fixed

- LuCI package metadata (project URL, maintainer) in the built packages.

## 0.1.0-r3 — 2026-06-24

### Added

- Binary download progress display and cancel button; official binaries are fetched via the GitHub API release-assets endpoint.
- Update detection for luci-app-netbird itself on the Versions tab.

### Fixed

- Download speed display unit.

## 0.1.0-r2 — 2026-06-23

### Fixed

- Binary download failures and stale "ghost" entries in the Versions tab.

## 0.1.0 — 2026-06-22

Initial public release.

### Added

- Six-tab LuCI UI for the NetBird client: **Authentication, Versions, Settings, Status, Network, Logs**.
- **Authentication** — setup-key login, connect / reconnect / disconnect / deregister, self-hosted management URL.
- **Versions** — switch the running binary between the official GitHub release (SHA-256 + ELF-arch verified, with auto-restore on failure), the system package feed, or a custom URL (multi-version, optional checksum).
- **Settings** — full `netbird up` configuration: WireGuard port & interface name, hostname, pre-shared key, firewall, DNS, routes, SSH (0.72.x+), IPv6, Rosenpass (post-quantum), log level. Capability-gated to the installed binary.
- **Status** — peer list (IP / FQDN / latency / last handshake / routed networks), daemon and kernel versions.
- **Network** — one-click firewall zone bound to the NetBird device (no OpenWrt network interface → zero data-plane disruption); opt-in, per-direction LAN ↔ mesh forwarding with instant-effect cancel; explicit removal.
- **Logs** — NetBird `client.log` viewer with search, severity-threshold and time-window filters, and paging.
- English + Simplified Chinese UI.
- Packaging for OpenWrt / ImmortalWrt 24.10 (opkg / ipk) and 25+ (apk); architecture-independent (`PKGARCH:=all`).
