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

Type is the system font (SF Pro on Apple platforms). No web fonts.

## Website assets

The website copies are in `website/assets/screens`. They are cropped to the window (the Figma frame padding removed) and compressed to WebP:

```sh
sips -c 902 1442 --cropOffset 39 59 brand/screens/now.png --out /tmp/now.png
cwebp -q 82 -m 6 /tmp/now.png -o website/assets/screens/now.webp
```

## Use of the name and logo

The code in this repository is MIT licensed. The Vardis name and logo are not. You may use them to refer to Vardis, for example in an article or a link. Forks and redistributed builds need their own name and icon.
