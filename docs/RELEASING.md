# Releasing

1. Add what changed under `## Unreleased` in `CHANGELOG.md` and commit.
2. `scripts/bump-version.sh 0.2.0` sets the version, bumps the build number, dates the changelog, commits and tags `v0.2.0`.
3. `git push origin main --tags`. The **Release** workflow tests, builds `Vardis-0.2.0.dmg` and `.zip`, and publishes a GitHub release with the changelog section as notes.

Local build of the same artifacts: `scripts/build-release.sh` (output in `build/dist`).

## Signing and notarization

Without secrets the app is ad-hoc signed. Add these repository secrets to sign with Developer ID and notarize:
`DEVELOPER_ID_CERT_P12` (base64 .p12), `DEVELOPER_ID_CERT_PASSWORD`, `DEVELOPER_ID_IDENTITY`, `APPLE_TEAM_ID`, `NOTARY_APPLE_ID`, `NOTARY_APP_PASSWORD`.

## App Store

The `app-store` job runs on tags when `ASC_KEY_ID`, `ASC_ISSUER_ID` and `ASC_KEY_P8` (App Store Connect API key) exist. It archives `VardisAppStore` and uploads it with `Config/ExportOptions-AppStore.plist`.

## Website

Pushes to `website/**` deploy with the **Website** workflow (`npx cf deploy`), using `CLOUDFLARE_API_TOKEN` and `CLOUDFLARE_ACCOUNT_ID`. Locally: `cd website && npm ci && npx cf deploy`.
