# Releasing

The public package feed is built by GitHub Actions and deployed to Cloudflare Pages.

## Automatic trigger

Pushes to `main` or `master` run the release workflow only when package code or the
release workflow changes:

- `luci-app-netbird/**`
- `.github/workflows/release.yml`

Changes limited to non-code public material such as `feed/**`, `site/**`, `docs/**`,
`README.md`, or `CHANGELOG.md` do not automatically rebuild or redeploy the feed.
Use the manual `workflow_dispatch` trigger if a rebuild is still desired — note this
includes the install/uninstall scripts under `feed/`, which only reach the site
through a workflow run.

A `workflow_dispatch` run on any branch other than `main`/`master` only builds and
signs the packages (kept as workflow artifacts); it never creates a Release or
deploys. Use it to test workflow changes before merging.

A running release is never cancelled: a newer push to the same branch waits until
the current run finishes.

## Changelog

Every release must update `CHANGELOG.md` in the same change set: one entry per
shipped version, titled with the public version and date (`## x.y.z — YYYY-MM-DD`),
followed by notable changes. Entries before `0.2.2` keep their original `x.y.z-rN`
titles. The automated GitHub Release notes only list build provenance and assets —
they are not a substitute for the changelog.

## Versions

The package version is `x.y.z-r1`: `PKG_VERSION` is `x.y.z` and `PKG_RELEASE` stays 1.
Everything public shows only `x.y.z`.

| Where | Shows |
| --- | --- |
| Package file names, the feed's `index.json`, what opkg/apk report | `0.2.2-r1` |
| The app's Versions page, `manifest.json` `version`, GitHub Release tag and title, changelog titles, docs | `0.2.2` (tag `v0.2.2`) |

The `-r1` suffix is kept on purpose. Installed copies of this app check for updates
by reading the feed's `index.json`, and they only accept a version in the `x.y.z-rN`
form there. Copies already on routers cannot be changed, so without the suffix their
update check would fail and they would never be offered a new version from the app.
The app compares the full `x.y.z-rN` versions; only the display drops an exact `-r1`.
Any other suffix, such as `0.1.0-r27`, is shown unchanged so two different versions
never look the same.

Always bump `PKG_VERSION` in `luci-app-netbird/Makefile` for a code change that should
ship:

- A new feature or a behavior change users will notice: increase the middle number and
  reset the last number to 0.
- Anything else, such as bug fixes and translations: increase the last number.

## What the workflow does

The workflow reads the package version from the built file names, for example:

- `luci-app-netbird_0.2.2-r1_all.ipk`
- `luci-app-netbird-0.2.2-r1.apk`

It verifies that the ipk and apk builds report the same full version, drops an exact
`-r1` suffix to get the public version, and then:

- writes the public version to `manifest.json` (the download links there come from the
  file list, so they keep the real `-r1` file names)
- creates the GitHub Release `v<public version>` (for example `v0.2.2`), or updates it
  and replaces its assets if that Release already exists
- uploads the ipk/apk packages and `manifest.json` as release assets
- deploys the signed feed and landing page to Cloudflare Pages

Releases up to `v0.2.1-r1` keep their existing tags. Because an existing Release is
updated in place, a push to `main` that ships code without bumping `PKG_VERSION`
overwrites the assets of the current Release.

## Checks before releasing

The workflow does not run these. Run them locally (needs `node` and `ucode`) whenever
login, connection or settings code changes:

```sh
node scripts/test-login-errors.cjs
node scripts/test-config-paths.cjs
```

Whenever the binary download or checksum code changes:

```sh
node scripts/test-update-checksum.cjs
```

Whenever backend code that writes UCI changes, run this in a disposable OpenWrt 22.03
container and in one newer release, because the 22.03 `ucode` cannot commit a single
named config (needs Docker):

```sh
docker run --rm --platform linux/amd64 -v "$PWD:/src:ro" \
  openwrt/rootfs:x86-64-22.03.6 sh /src/scripts/test-uci-commit.sh
docker run --rm --platform linux/amd64 -v "$PWD:/src:ro" \
  openwrt/rootfs:x86-64-25.12.2 sh /src/scripts/test-uci-commit.sh
```
