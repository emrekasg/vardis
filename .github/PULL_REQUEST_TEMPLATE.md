## What this changes

<!-- One or two sentences. Link the issue if there is one. -->

## How it was tested

<!-- Tests added or updated, and what you checked by hand. -->

## Checklist

- [ ] Both schemes build (`Vardis` and `VardisAppStore`)
- [ ] `swift test` passes in `Packages/VardisKit`
- [ ] No new network requests, analytics, telemetry or third-party SDKs
- [ ] No disk I/O on the main thread; performance budgets still hold (say how you measured if this touches sampling, charts or startup)
- [ ] Direct-only features sit behind `Edition.current.supports(_:)`
