# capcap

[中文说明](README.zh-CN.md)

capcap is a lightweight, native macOS screenshot tool that lives in your menu bar. Trigger it with a double-tap of `⌘ Command` or a custom shortcut, select a region or click a window, then annotate, beautify, copy, save, or pin the result.

Built with pure AppKit + ScreenCaptureKit and Swift Package Manager. No SwiftUI, storyboards, XIBs, or third-party dependencies.

## Features

- **Fast region and window capture** — drag any area, or hover and click a detected window to snap to its bounds.
- **Multi-display support** — creates overlays on every connected screen and captures at full Retina resolution.
- **Full annotation editor** — rectangle, ellipse, arrow, pen, highlighter, mosaic, numbered callouts, and text.
- **Editable annotations** — move existing marks, change color and size, rotate supported annotations, bend arrows/callouts, edit text, delete marks, and use undo/redo.
- **Scroll capture** — capture a selected scrolling area, preview the stitched image live, and merge it back into the editor.
- **Beautify mode** — wrap screenshots in rounded corners, soft shadow, gradient presets, wallpaper background, and adjustable padding.
- **Color picker** — use the macOS color sampler, copy the picked hex value, and keep it in history.
- **Pin to screen** — float the current screenshot above other windows as a draggable reference image.
- **Save or copy** — save as PNG, confirm to copy PNG/TIFF data to the clipboard, or cancel without output.
- **Recent history** — menu bar history with thumbnails and picked colors for quick re-copy, with a configurable cache size.
- **Custom trigger** — use the default double-tap `⌘`, or record a custom global shortcut in Settings.
- **Settings and localization** — Chinese/English UI, menu bar icon toggle, launch at login, demo mode, permission status, shortcut recording, and history cache size.
- **Menu bar app** — runs as an agent app without a Dock icon.

## Requirements

- macOS 14.0+
- Accessibility permission, used for the default double-tap `⌘` trigger
- Screen Recording permission, used by ScreenCaptureKit and screenshot capture

On first launch, capcap opens a setup window that shows both permission states. The app can launch once both required permissions are granted.

## Install with Homebrew

This repository ships a Homebrew cask at `Casks/capcap.rb`.

Because the repository name is `capcap` rather than `homebrew-capcap`, tap it with an explicit URL:

```bash
brew tap realskyrin/capcap https://github.com/realskyrin/capcap
brew install --cask capcap
```

See [docs/homebrew.md](docs/homebrew.md) for the release/update workflow.

## Build from Source

```bash
# Build and bundle build/capcap.app
./scripts/bundle.sh
```

For local development, this script rebuilds the app, kills any running instance, launches the new bundle, and verifies that it started:

```bash
bash scripts/rebuild-and-open.sh
```

To package a draggable DMG:

```bash
scripts/package-dmg.sh
```

The app bundle is output to `build/capcap.app`; DMGs are output to `dist/`.

## Usage

1. Double-tap `⌘ Command`, press your custom shortcut, or choose **Take Screenshot** from the menu bar.
2. Hover a window and click to capture it, or drag to select any region.
3. Use the floating toolbar to annotate, pick a color, start scroll capture, beautify, save, pin, cancel, or confirm.
4. Click the green checkmark or press `Enter` to copy the final image to the clipboard. Press `Esc` or click `x` to cancel.

## Editor Tools

| Tool | What it does |
|------|--------------|
| Rectangle / Ellipse | Draw outlined shapes with selectable colors and stroke widths |
| Arrow | Draw straight arrows; select an arrow later to move endpoints or bend the shaft |
| Pen | Draw smoothed freehand strokes |
| Highlighter | Draw semi-transparent marker strokes without darkening overlaps |
| Mosaic | Brush pixelated regions over sensitive content, with adjustable block size |
| Numbered | Add incrementing callout badges; drag while placing to add an arrow |
| Text | Add editable single-line text with color and 10-100 pt size controls |
| Eyedropper | Pick any screen color and copy its `#RRGGBB` value |
| Undo / Redo | Revert and restore editor changes |
| Move Selection | Drag the whole selected screenshot region after selection |
| Scroll Capture | Scroll inside the selected area, stitch frames, and continue editing the merged result |
| Beautify | Add gradient or wallpaper backgrounds, rounded corners, shadow, and padding |
| Save | Save the current result as a PNG |
| Pin | Keep the current result floating above other windows |
| Confirm | Copy the final result to the clipboard |

When an annotation is selected, capcap shows adjustment handles where supported: rotation for shapes, strokes, and text; curve handles for arrows and numbered callouts; endpoint handles for arrows; and edit/delete actions for text and selected annotations.

## Settings

Open Settings from the menu bar to configure:

- Language: Chinese or English
- Menu bar icon visibility
- Launch at login
- Demo Mode, which allows external screen recorders to capture capcap's overlay and editor
- Screenshot shortcut: keep double-tap `⌘`, record a custom shortcut, or restore the default
- History cache size, from 5 to 20 recent screenshots/colors
- Accessibility and Screen Recording permission shortcuts

## History

The menu bar **History** submenu stores recent screenshots and picked colors in `~/Library/Application Support/capcap/History`. Click an image entry to copy it back to the clipboard, click a color entry to copy its hex value, or clear the full history from the submenu.

## macOS Verification Warning

If macOS shows a warning like `Apple cannot verify "capcap" is free of malware`, remove the quarantine flag from the app bundle you trust, then open it again:

```bash
xattr -dr com.apple.quarantine /Applications/capcap.app
```

If you are running a locally built copy instead of the app in `/Applications`, replace the path with your actual app location, for example:

```bash
xattr -dr com.apple.quarantine ./build/capcap.app
```

Only do this for builds downloaded from this repository or ones you built yourself.

## Project Structure

- `capcap/App/` — app entry point, delegate, and bundle metadata
- `capcap/Capture/` — overlay, selection, window detection, ScreenCaptureKit capture, scroll stitching, clipboard, and history
- `capcap/Editor/` — annotation models, editor canvas, floating toolbar, beautify rendering, mosaic, scroll preview, and pin windows
- `capcap/Trigger/` — double-tap `⌘` monitor and custom Carbon hotkey registration
- `capcap/UI/` — menu bar controller, toast, cursor chip, and tooltips
- `capcap/Settings/` — startup/settings window and preferences UI
- `capcap/Utilities/` — defaults, localization, and launch-at-login support
- `scripts/` — compile check, bundle, rebuild/open, icon, DMG, and Homebrew cask helpers

## Development

```bash
# Fast compile validation for Swift-affecting changes
bash scripts/compile-check.sh

# Build, restart, and verify the local app
bash scripts/rebuild-and-open.sh
```

## License

MIT
