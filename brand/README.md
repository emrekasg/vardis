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

The site lives in `website/` and is plain static files: no build step, no third-party requests, a strict CSP (`website/_headers`) with no inline scripts or style attributes.

- **Look:** light pages, no navigation bar. Bold system sans headlines (700, tight tracking), with the key phrase in the brand gradient (`#0e9f9a → #1a8fd8 → #1a6dcb`, from the icon's teal→blue stroke). Navy `#0b1220` for primary buttons and for the product-art panels (hero stage, Claude Code stage). Soft teal/blue glows and a faint 64 px grid behind sections, used sparingly.
- **Product art:** the screens are recreated in HTML/SVG/canvas with fictional data and animated (live tiles, processes collapsing into apps, a scrubbable day timeline, cleanup moving to the Trash with Undo, Claude Code tabs). Tile colours follow the app (CPU blue, memory amber, GPU pink, disk teal, network violet, battery green).
- **Real screenshots:** only the top row of the Now screen is used (`website/assets/img/now-real-*.webp`). Real screens contain project names, paths, session titles and costs; never publish them unredacted.
- **Motion:** transform/opacity only, paused off screen and in hidden tabs, started after the `load` event, off under `prefers-reduced-motion`, and a Pause motion button.
- **Share image:** `website/assets/img/og.png` (1200 × 630) is rendered from `website-src/og/og.html` with headless Chrome.

## Use of the name and logo

The code in this repository is MIT licensed. The Vardis name and logo are not. You may use them to refer to Vardis, for example in an article or a link. Forks and redistributed builds need their own name and icon.
