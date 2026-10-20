# Take Control brand

## Concept
A fan inside a gauge. The arc runs from cool to hot, and the knob is the "take control" point where you set the fan. It points at the app's two features: temperature and one fan control.

## Files
| File | Use |
|---|---|
| `icon.svg` | App icon master (1024 px, macOS tile grid with 100 px margin) |
| `menubar.svg` | Menu bar template glyph (18 pt). Black only: macOS tints it for light, dark and highlighted states |
| `logo-light.svg`, `logo-dark.svg` | Icon + wordmark lockups for light and dark backgrounds (vector; the wordmark uses the system font) |
| `png/` | Raster exports: `icon-1024.png`, `logo-light.png`, `logo-dark.png` (2x) |
| `render.sh` | Regenerates everything from the SVGs, including `../Resources/AppIcon.icns` and `../Resources/MenuBarIcon*.png` |

After editing an SVG, run `Branding/render.sh`, then `./build.sh`.

## Colors
| Role | Hex |
|---|---|
| Tile top | `#2B3242` |
| Tile bottom / ink | `#0D1016` / `#141821` |
| Cool | `#3EDCFF` |
| Warm | `#FFB53D` |
| Hot | `#FF4F3A` |
| Blades | `#FFFFFF` → `#C7D0DD` |

The heat gradient (cool → warm → hot) is the only accent. Keep everything else neutral.

## Wordmark
"Take" in medium weight and "Control" in heavy weight, in the system font (SF Pro), with slightly tight tracking. Write the name as **Take Control**: two words, both capitalized.
