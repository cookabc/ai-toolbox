# AI Toolbox / AIToolbox

<p align="center">
  <img src="docs/images/hero.png" width="720" alt="AI Toolbox: usage and configuration, right in the menu bar">
</p>

A macOS menu bar app that gathers the local usage, trends and provider
configuration of Codex and Claude Code into one pixel-styled panel. Everything
comes from this Mac's own logs; it never queries a remote bill or subscription
quota.

Written in Swift 6, with no external SPM dependencies, and requires macOS 13+.

## Interface

| Usage details | Provider configuration |
| --- | --- |
| ![Usage details (light)](docs/images/detail-light.png) | ![Provider configuration (light)](docs/images/config-light.png) |

It follows the system's light and dark appearance (`docs/images/detail-dark.png`,
`docs/images/config-dark.png`).

- **Usage**: today's output, the input composition (cache read, cache write,
  uncached), per-day output over the last 7 days, lifetime usage and a model
  ranking. The lifetime and models cards collapse, and the collapsed state is
  remembered.
- **Config**: the official sign-in and the saved providers form one group. The
  one in use is pressed in and the rest can be switched to; each can be tested,
  edited or deleted, and the configuration in effect can be imported. Deleting a
  provider and switching back to Claude Code's official sign-in both confirm
  first.

## Design

- Grid: 1 pixel = 1 pt, 2 pt borders, stepped corners and hard shadows, so
  nothing blurs on either a 1x or a Retina display.
- Type: titles, labels and numbers use the Ark Pixel font (Ark Pixel 12px, Latin
  variant); running text stays in the system font so long passages remain
  readable.
- The palette comes from the app icon (midnight navy, cyan, blue, violet), with
  one set for light and one for dark, and body text meets WCAG AA; turning on
  Increase Contrast deepens text and borders.
- Motion is limited to a step-wise loading indicator; with Reduce Motion on it
  becomes a still hourglass and blocks.
- Numbers follow English grouping: full digits below 10,000, and K / M / B / T
  above with three significant digits kept; hovering reveals the exact value.

## Build and test

```bash
swift build
swift test
```

The package product is an executable target (`AIToolbox`); the interface
resources (the pixel font and its license file) ship with the bundle.

Optional render tasks (sample data only):

```bash
USAGE_RENDER_DOCS=1 swift test --filter DocumentationRenderTests/testRenderDocumentation   # updates docs/images
USAGE_RENDER_GALLERY=/tmp/gallery swift test --filter DocumentationRenderTests/testRenderGallery  # every page and state
USAGE_RENDER_ICON=1 swift test --filter DocumentationRenderTests/testRenderAppIcon         # regenerates the app icon
```

## Packaging and installation

```bash
bash scripts/package-app.sh
```

The script has no executable bit set, so run it through `bash` explicitly. The
product is `dist/AIToolbox.app` (ad-hoc signed). The icon comes straight from the
per-size pixel art in `Assets/AppIcon.iconset`, with no resampling. To install it
in /Applications:

```bash
pgrep -x AIToolbox || true          # make sure it is not running
rm -rf /Applications/AIToolbox.app
cp -R dist/AIToolbox.app /Applications/
open /Applications/AIToolbox.app
```

## First run

After launch the icon appears on the right of the menu bar (the status item
area); clicking it opens the usage and configuration panel. The app is an
`LSUIElement`, so it does not appear in the Dock; to launch it at login, add it
yourself under System Settings → General → Login Items.

The interface is English only; `Info.plist` declares `en` as its sole
localization, so the system pieces inside the panel (text-field context menus,
system error messages) come out in English too.

## Data sources and privacy

- Codex usage: this Mac's `~/.codex/sessions/` session logs
- Claude Code usage: this Mac's `~/.claude/projects/` session logs
- Provider library: `~/Library/Application Support/AIToolbox/providers.json`

The app only reads these local files and makes no remote usage query. When the
configuration panel changes `~/.codex/config.toml` or `~/.claude/settings.json`
it writes atomically, backs the original up as `.ai-toolbox.bak` beside it, and
touches only the keys it owns, leaving the rest of the configuration alone.

## Uninstalling

1. Quit the app (menu bar icon → Quit)
2. Delete `/Applications/AIToolbox.app`
3. To remove the provider library too, delete
   `~/Library/Application Support/AIToolbox/`
4. `.ai-toolbox.bak` backups are never cleaned up automatically; delete them by
   hand once you are sure you will not need to roll back

## Distribution

The product is ad-hoc signed and meant for local builds only; copying it to
another Mac will be stopped by Gatekeeper. Distributing it publicly needs a
Developer ID signature and notarization first.

## License

The app code is released under the [MIT License](LICENSE). The bundled Ark
Pixel font stays under its own
[SIL Open Font License 1.1](Sources/AIToolbox/Resources/ArkPixel-OFL.txt); see
Third-party resources below.

## Third-party resources

The pixel font is the Latin variant of
[Ark Pixel Font](https://github.com/TakWolf/ark-pixel-font) 12px proportional,
© TakWolf, licensed under the SIL Open Font License 1.1, redistributed with the
app unmodified; the full license text is in
`Sources/AIToolbox/Resources/ArkPixel-OFL.txt`.
