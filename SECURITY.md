# Security policy

## Supported versions

Vardis has not had its first release yet. Once it does, security fixes go into the latest release only.

## Reporting a vulnerability

Please do not open a public issue for security problems.

Report privately through GitHub: go to the [Security tab](https://github.com/emrekasg/vardis/security/advisories/new) of this repository and choose **Report a vulnerability**. Include what you found, how to reproduce it, and which version and edition (direct download or App Store) you used.

You can expect a first reply within a week. Once a fix is ready, we will publish an advisory and credit you unless you prefer otherwise.

## What is in scope

Vardis reads sensitive local data: process information, Claude Code transcripts and, in the direct download, the Claude Code sign-in from the Keychain. We especially want to hear about:

- any way Vardis could send data anywhere other than `vardis.app/appcast.xml` and `api.anthropic.com`
- the Claude sign-in token being exposed, logged, or sent anywhere other than `api.anthropic.com`
- Disk Cleanup removing something it should not, or deleting instead of moving to the Trash
- problems with the update mechanism or code signing
