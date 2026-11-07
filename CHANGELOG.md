# Changelog

All notable changes to this project are documented here.
This project adheres to [Semantic Versioning](https://semver.org/).

## 0.2.1-r1 — 2026-11-06

### Fixed

- On OpenWrt 22.03 and 23.05, updating this app from its own page no longer reports a failure after the update has already succeeded. The update to this version can still show the old message once, because the new install step only takes effect from this version on.

## 0.2.0-r1 — 2026-11-06

This release starts the `0.2` series after the features added across `0.1.0-r2` to `r27`. Upgrades from `0.1.0` work normally.

### Fixed

- Login failures now report the real cause. A setup key rejected in the newer `setup-key` log format is shown as rejected, and earlier log lines or a closed connection between the command line and the local NetBird service no longer appear as "The management server is temporarily unreachable."
- After a failed connect or reconnect, the Authentication page updates its status and last error in place. The notification and the management URL you entered stay on the page. If the status cannot be read, the page shows Unknown instead of the old state.
- Saving settings after a failed login no longer starts an SSO wait that could hold up other configuration reloads on the router for up to 45 seconds.

### Changed

- If you saved settings after disconnecting or after a failed login, they now apply on the next successful connection instead of reconnecting right away. The Settings page shows a notice while settings are waiting. Connections made outside LuCI, such as `netbird up`, pick up waiting settings after about two minutes.



### Fixed

- Settings now take effect on the first connection. After a fresh install or a logout, the first login with a setup key applies the saved settings once, so options such as disabling DNS no longer wait until the Settings page is saved again. Thanks to @gw826943555 ([#15](https://github.com/looong-cat/luci-app-netbird/pull/15)).
- The **Log level** setting now reaches the running NetBird service without reconnecting, and is restored automatically after the service restarts. This needs NetBird 0.27.4 or newer; older versions stay at info. The Logs tab also recognizes the short level names used by newer clients.
- On apk systems, the package feed's signing key is kept across firmware upgrades that keep settings, so `apk update` no longer fails signature checks afterwards. The uninstall script removes this entry.
- Manual binary downloads tolerate slow connections better: a longer connection timeout and retries, detection of stalled transfers, and the actual `curl` error in the failure message.
- Package upgrades restart the auto-reconnect service, so apk systems no longer keep running the old script until the next reboot.

### Changed

- The Versions tab warns when the configured NetBird-Release binary is missing, for example after a firmware upgrade, and explains how to download it again.
- `/etc/netbird.env` is no longer created. The NetBird service never read it; an existing file is harmless and is left in place.

## 0.1.0-r26 — 2026-10-12

### Added

- **Allow remote diagnostics** setting (Settings → Logging, off by default). Since NetBird 0.78 the client refuses remote jobs from the management server — currently collecting a debug bundle from the dashboard — unless the device allows them, so this stopped working for routers managed through the app. Turning it on passes `--allow-remote-jobs=true`; it is skipped automatically on NetBird versions that do not have the option.
- The Versions tab warns when the running NetBird is older than 0.76.1. NetBird 0.76.0 and 0.76.1 fixed two security issues in the client's local service socket (a high-severity local privilege escalation, GHSA-qcpp-8vwj-hhwr, and a medium-severity arbitrary root file read, GHSA-28q5-j9qm-gx35). The NetBird packages in the OpenWrt 22.03, 23.05 and 24.10 feeds (0.17, 0.24 and 0.59) and in some 25.x builds (ImmortalWrt 25.12.2 ships 0.73) are older than that; switching to the official release on the same tab fixes it.

## 0.1.0-r25 — 2026-10-12

### Fixed

- Saving NetBird settings on a router that is not logged in yet could stall every other configuration change on the router — firewall, network, wireless and DHCP changes from LuCI were no longer applied until the next reboot. Applying settings runs `netbird up`, which on a device without a login waits for a browser sign-in indefinitely, and OpenWrt applies configuration changes one at a time, so everything else queued behind it. Settings saved before the first login are now stored and applied right after the next successful login, and applying settings never waits longer than a fixed limit.
- Connecting from the Login tab failed on OpenWrt 22.03 and 23.05 when NetBird from the system package feed is in use (for example on architectures without an official NetBird release, when GitHub is unreachable, or when the package-feed build was chosen on purpose). The app always passed `--no-browser`, which NetBird 0.17 and 0.24 do not know, and the failure surfaced only as a generic "did not become connected before the timeout". The option is now passed only when the installed NetBird supports it, and when NetBird rejects a command or its service is not running, the real reason is shown right away instead of after a long wait.
- Stock OpenWrt BusyBox has no `timeout` command, so the 5-second limits the app puts on NetBird status, version and service commands never applied there. If the NetBird service stopped responding, LuCI pages (not only this app's) and automatic reconnect could hang with it. The app now enforces these limits itself when `timeout` is unavailable; reading version information from GitHub also has an overall time limit.
- Long-running actions block all of LuCI while they run. Automatic reconnect no longer downloads the official NetBird release as part of each retry — on networks where GitHub is slow or blocked every retry used to wait for the download to time out — and after a failed automatic download the app does not try again for 30 minutes. Downloads from the Versions tab are not affected.
- Turning the NetBird service off in Settings now also stops automatic reconnect; it resumes when the service is turned back on.
- Saving an unrelated page in LuCI could briefly disconnect NetBird. The app keeps connection state, the selected exit node and similar values in its configuration, and OpenWrt reapplies a package whose configuration changed since the last apply. Settings are now reapplied only when the options passed to NetBird actually change.
- On some preinstalled firmware images the settings and automatic-reconnect services were never enabled, so saving settings and automatic reconnect silently did nothing until the app was updated once. They are now enabled when the NetBird service is enabled or a connection is started.
- Backups for keep-settings firmware upgrades included every downloaded NetBird binary (tens of MB, built in RAM) and copied this app's own scripts over the newer ones in the new firmware. They now keep only the configuration; the NetBird identity is kept as before. After such an upgrade the system-feed NetBird is used again and the official release can be downloaded from the Versions tab.
- If the background download of a NetBird binary was killed (for example by the out-of-memory killer), the Versions tab kept showing it as running and every binary action reported "another operation is in progress" until a reboot. The app now notices the stopped download, releases the lock, and the page stops waiting after about 30 seconds without a reply from the router.
- Updating a NetBird binary uses less temporary memory, refuses to touch the current binary when it cannot be backed up completely, and only reports "restored the previous one" when the restored binary actually runs. A custom download link whose file name is exactly `netbird` no longer fails. Replacing a binary also no longer fails with `Text file busy` when a NetBird command happens to be running from it.
- On apk-based systems (OpenWrt / ImmortalWrt 25+), `apk upgrade` and LuCI's Software page stopped upgrading the app after it had been updated from the Versions tab. The in-app updater installs the downloaded package files directly, and apk records a package installed from a file in `/etc/apk/world` as pinned to that exact file (`luci-app-netbird><Q1…`), so later upgrades from the package feed skip it without any message. Installing the package now turns such pins for the app and its translation packages back into plain package names right after the install finishes; the installed version does not change. This also clears pins left by earlier in-app updates and by manually installing a downloaded `.apk` file, and it applies already to the update that installs this version.
- Stopping or restarting the automatic-reconnect watchdog (including at reboot) no longer waits for the service manager to kill it. The watchdog was meant to exit as soon as it is asked to stop, but the shell only handles that request after its current 30-second pause has finished, so procd gave up after 5 seconds, killed it, and left the pause process behind. The pause can now be interrupted.
- Logging out locally now waits for the NetBird service to stop before removing its identity.
- The Logs tab now shows logs when the service is not running or not logged in, which is when they are most useful.
- After a reboot on opkg-based releases the Versions tab no longer claims that the package feed does not provide NetBird; the package lists are cleared on reboot, and the tab now says so.
- Installing the WireGuard or TUN kernel module from the Status tab keeps the package manager's signature check on apk-based systems.
- Downloaded binaries are now also checked for the device's word size and byte order, not only its CPU type.
- The installer no longer stops on firmware without `/etc/opkg/customfeeds.conf`, and it stops with a clear message when the feed script itself cannot be downloaded.
- NetBird 0.80's "pass --profile" error is recognized and reported directly.
- Upgrades add newly introduced settings with their defaults again. The check relied on a comment at the top of `/etc/config/netbird`, which disappears the first time the configuration is saved, so the step was being skipped.
- Added `ucode`, `ucode-mod-fs` and `ucode-mod-uci` to the package dependencies; on 22.03 they were only present because firewall4 happened to install them.

Reboot once after upgrading (or restart rpcd, `netbird-settings` and `luci-netbird-watchdog`) so the updated backend and services load.

## 0.1.0-r23 — 2026-10-11

### Fixed

- On some firmwares the Versions tab showed `-` for every version and installing the official NetBird release failed with `the written file could not report its version (truncated or corrupt)`; the Status tab could also report the service as disabled while it was running. The cause was a `/usr/bin/timeout` symlink pointing at a BusyBox built without the `timeout` applet: the file exists and is executable, but every command run through it exits 127 with `applet not found`. The app decided whether to use `timeout` only by checking that the file exists, so every version, package and service query wrapped in it returned nothing, and the check that runs right after writing a downloaded binary rejected a perfectly good file. The backend and the automatic-reconnect watchdog now actually run `timeout 1 true` once to decide, and fall back to running commands directly when it does not work. Nothing on the system is changed or removed.
- If the check after writing a binary still fails, the error now includes the real exit code and output instead of always blaming a corrupt file.
- Downloading the official NetBird release from the Versions tab failed on OpenWrt 22.03 and 23.05 routers without `curl` (`uclient-fetch: unrecognized option: header=...`). The download goes through GitHub's API, which needs an extra request header, and the `uclient-fetch` shipped with those releases has no option to send one. The app now checks whether the downloader can send headers and otherwise downloads from the regular GitHub release link. On those releases this switch is the recommended way to get a NetBird new enough for exit nodes, so it works again there.

Reboot once after upgrading (or restart rpcd and the `luci-netbird-watchdog` service) so the updated backend and watchdog load.

## 0.1.0-r22 — 2026-09-17

### Fixed

- Reconnect no longer leaves the router offline when LuCI is opened over NetBird ([#12](https://github.com/looong-cat/luci-app-netbird/pull/12), reported with a clear analysis by [@stackcn](https://github.com/stackcn)). The button used to send two requests from the browser, disconnect and then connect, but the disconnect removed the tunnel the second request had to travel through, so it never arrived. Disconnecting also cleared the "stay connected" intent, so the automatic-reconnect watchdog treated it as a deliberate stop and never brought the connection back. Reconnect is now a single request: the router records that it should stay connected, disconnects and reconnects on its own, and replies once it is connected again. Over NetBird the tunnel drops for a second or two and the page still receives the result; if the request is cut off anyway, the router still finishes reconnecting, and the watchdog takes over if it could not.
- The install script no longer stops when an unrelated package feed fails to update ([#13](https://github.com/looong-cat/luci-app-netbird/issues/13), reported by [@netsrot303](https://github.com/netsrot303)). `opkg update` and `apk update` exit with an error when any configured feed fails, for example the `glinet` feed on GL.iNet firmware, which publishes no `Packages.sig`. `feed.sh` therefore aborted before the one-click installer reached the install step. It now stops only if the NetBird feed itself could not be loaded, including when its signature does not verify, and prints a warning about other feeds.

Reboot once after upgrading (or restart rpcd) so the updated backend loads.

## 0.1.0-r21 — 2026-08-17

### Fixed

- The Exit Node tab now works on setups with many network resources ([#11](https://github.com/looong-cat/luci-app-netbird/issues/11), reported with careful measurements and on-device verification by [@nonnname](https://github.com/nonnname)). `netbird networks list` output grows with the number of network resources on the management server, and the app refused to parse it beyond a 64 KiB cap — about 680 resources at the observed ~97 bytes per entry — so listing and selecting an exit node both failed with "too many networks to parse safely". The same cap also silently disabled the reboot-time exit-node restore introduced in r20 on such peers. The cap is now 1 MiB (roughly 10k resources); the safeguard that refuses to act on a truncated list stays in place above it.
- The `status --json` reader cap is raised from 256 KiB to 1 MiB for the same class of growth: that payload grows per routed resource rather than per peer, so a handful of routing peers could approach the old ceiling and reproduce the #8 symptom — the UI showing Disconnected while fully connected. Both readers always buffer the full output before truncating, so raising the caps costs one parse of a longer string, not extra memory.

## 0.1.0-r20 — 2026-08-13

### Added

- The exit node selected in LuCI now survives a reboot ([#10](https://github.com/looong-cat/luci-app-netbird/issues/10), requested by [@netsrot303](https://github.com/netsrot303)). The netbird daemon keeps its network selection in a state file that lives in RAM on OpenWrt, so every reboot silently dropped the selected exit node. The app now stores the selection in its own configuration when you apply it, and the automatic-reconnect watchdog re-selects it once per boot after the connection is up — typically within a minute of booting. Switching the exit node off in LuCI clears the stored selection, and that also sticks across reboots. Selections made outside LuCI (via the netbird CLI or other clients) are not stored. Restoring never selects anything that is not offered by the management server at that moment; if the configured exit node no longer exists, it is skipped with a log line.

### Fixed

- Logging in with an invalid or expired setup key now fails in about half a minute with the actual reason instead of a raw RPC error. The daemon retries a rejected key indefinitely, and the app used to keep polling long enough for the web server's 60-second RPC limit to cut the request — the browser then showed an unhelpful `ubus request timed out` error while the real cause (`the setup key was rejected…`) only landed in the "Last authentication error" field after a page reload. The backend now returns as soon as the failure can be classified, and any remaining timeout-type RPC errors are shown as a friendly message instead of raw error text.
- After deregistering, pressing Connect with an empty setup key field used to stall for ~40 seconds before failing. A deregistered device has no identity left to reconnect with: the login page now states that a key is required (the masked "Last used" text is only a reminder — keys are never stored on the device), an empty submit is caught immediately in the page, and the backend answers instantly with the same message as a fallback.

Reboot once after upgrading (or restart rpcd and the `luci-netbird-watchdog` service) so the updated backend and watchdog load.

## 0.1.0-r19 — 2026-08-10

### Fixed

- The in-app updater no longer installs the Simplified Chinese translation package on systems that never had it (#3, follow-up report by [@Kopterlove](https://github.com/Kopterlove)). It used to download and install the translation package unconditionally alongside the main package, and installing it re-registers Chinese in LuCI's language list — so updating from the Version tab brought Chinese back on English-only systems, undoing the r9 cleanup. The updater now upgrades the translation package only when it is already installed, and never introduces it. As usual, reboot once after upgrading (or restart rpcd) so the updated backend loads.
- **Heads-up for English-language routers**: any in-app update performed before r19 installed `luci-i18n-netbird-zh-cn` unconditionally — and the update **to** r19 itself still runs under the old updater code, so it happens one last time. If Chinese shows up in your LuCI language list and you don't want it, clean up once after upgrading (also walked through in [#3](https://github.com/looong-cat/luci-app-netbird/issues/3#issuecomment-5238240821)): `opkg remove luci-i18n-netbird-zh-cn` (apk-based systems: `apk del luci-i18n-netbird-zh-cn`), then `uci -q delete luci.languages.zh_cn && uci commit luci`; if the UI language itself got switched, `uci set luci.main.lang='auto' && uci commit luci`.

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
