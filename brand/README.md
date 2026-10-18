# Brand

This folder holds the Vardis icon and the approved screen designs.

| File | What it is |
|---|---|
| `icon-1024.png` | App icon, 1024 × 1024. The app's icon set in `App/Resources` is generated from it. |
| `screens/*.png` | Approved designs exported from Figma (file `Nay4HUHlzZlxYOGyzAfaZN`, page Screens). They show the intended product, not a shipped build. |

## Colours

| Name | Light | Dark | Use |
|---|---|---|---|
| Ink | `#14171C` | `#EEF1F5` | Text |
| Muted ink | `#5A626E` | `#9AA3AE` | Secondary text |
| Surface | `#FFFFFF` | `#0E1116` | Backgrounds |
| Hairline | `#E4E7EB` | `#252A33` | Dividers and borders |
| Accent blue | `#1F7AE0` | `#5AA2F0` | Links, focus, primary actions (`#1A6DCB` behind white text) |
| Teal | `#2FD4C4` | `#2FD4C4` | One highlight at a time, from the icon's stroke |

Type is the system font (SF Pro on Apple platforms) in the app.

## Website (vardis.app)

Plain static files in `website/`, no build step, no third-party requests, strict CSP in `website/_headers`. Two screens, light, no navigation bar: icon, name, one sentence, Download and GitHub, and a fictional Now window whose numbers tick (off under reduced motion); then a short feature list, the privacy line and a footer. No dates, benchmarks or comparisons.

- `website/assets/img/og.png` is rendered from `website-src/og/og.html` with headless Chrome.
- `brand/now-window.png` (used in the README) is rendered from `website-src/now-window.html`.
- Real app screenshots contain personal data (project names, paths, session titles, costs). Do not publish them.

## Use of the name and logo

The code in this repository is MIT licensed. The Vardis name and logo are not. You may use them to refer to Vardis, for example in an article or a link. Forks and redistributed builds need their own name and icon.
