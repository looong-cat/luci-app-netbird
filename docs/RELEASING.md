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
shipped `PKG_RELEASE` (version, date, notable changes). The automated GitHub
Release notes only list build provenance and assets — they are not a substitute
for the changelog.

## Version source

The release version is extracted from the built package filenames, for example:

- `luci-app-netbird_0.1.0-r2_all.ipk`
- `luci-app-netbird-0.1.0-r2.apk`

The workflow verifies that the ipk and apk builds report the same version. It then:

- writes that version to `manifest.json`
- creates or updates the GitHub Release tag `v<version>`
- uploads the ipk/apk packages and `manifest.json` as release assets
- deploys the signed feed and landing page to Cloudflare Pages

Always bump `PKG_RELEASE` in `luci-app-netbird/Makefile` for a code change that
should ship as a new package revision.
