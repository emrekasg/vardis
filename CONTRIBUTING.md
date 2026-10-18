# Contributing to Vardis

Thanks for helping. Vardis is a small, opinionated app, so a short read here saves everyone time.

## Before you start

- **Bugs:** open an issue with the bug template. Include your macOS version and Mac model.
- **Ideas:** open a feature request first, before writing code, so we can agree it fits.
- **Security issues:** do not open a public issue. See [SECURITY.md](SECURITY.md).

## Two rules every change must keep

1. **The privacy promise.** Vardis collects nothing. No analytics, telemetry, crash reporting or third-party SDKs, and no new network calls. The only network use is the update check and the Anthropic plan-limits request described in [PRIVACY.md](PRIVACY.md). A pull request that adds a network request or a dependency that phones home will not be merged.
2. **The performance budgets.** The table in the [README](README.md#fast-by-design) is a release gate. No disk I/O on the main thread, no per-sample allocation in hot paths, no spinners on screen switches. If your change touches sampling, charts or startup, say how you measured it.

## Setting up

You need Xcode 26 and XcodeGen.

```sh
brew install xcodegen
xcodegen generate
open Vardis.xcodeproj
```

Run the tests:

```sh
cd Packages/VardisKit && swift test
```

The `.xcodeproj` is generated and not committed. Change `project.yml` instead.

## How the code is organised

- `App/` holds the app target: AppKit lifecycle, menu bar items and SwiftUI screens.
- `Packages/VardisKit/` holds the logic, split into `VardisCore`, `VardisSampling`, `VardisStore`, `VardisClaude` and `VardisCleanup`. Put logic here, with tests, rather than in the app target.
- Features that only work outside the sandbox go behind `Edition.current.supports(_:)` so the App Store build still compiles.

The full design is in [docs/specs](docs/specs/).

## Pull requests

- Keep each pull request to one change. Smaller is easier to review.
- Add or update tests for logic in VardisKit.
- Build both schemes (`Vardis` and `VardisAppStore`) before opening the pull request. CI does the same.
- Use Swift 6 strict concurrency. Avoid new dependencies; if you think one is needed, ask in an issue first.
- Write user-facing text in plain, short sentences.

## Code of conduct

Everyone taking part follows the [Code of Conduct](CODE_OF_CONDUCT.md).

## License

By contributing, you agree that your contributions are released under the [MIT License](LICENSE). The Vardis name and logo are not part of that license.
