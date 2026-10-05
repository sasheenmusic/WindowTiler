# Window Tiler

<img src="Resources/AppIcon.png" alt="Window Tiler icon" width="128">

Turn your open windows into a tidy, edge-to-edge layout. Window Tiler is a small, free macOS menu-bar app that works across multiple displays.

**Requires macOS 13 or later.** Released under the MIT license.

## Install

1. Download the ZIP from the [latest release](../../releases/latest).
2. Unzip it and move **Window Tiler.app** to **Applications**.
3. Right-click the app and choose **Open**. If macOS blocks it, go to **System Settings → Privacy & Security → Open Anyway**. The app is not notarized by Apple.
4. Enable Window Tiler under **System Settings → Privacy & Security → Accessibility** so it can move and resize windows.

## Start tiling

Press **Control–Option–Command–T**, or click the grid icon in the menu bar and choose **Tile All Windows**.

Automatic tiling is on by default. Windows reflow when they open, close, minimize, return, or move between displays. You can turn it off or change the keyboard shortcut in the menu.

## Pick your layout

| Control | What it does |
| --- | --- |
| **Windows Per Row** | Set the automatic layout to use up to 2, 3, 4, or 5 windows per row. |
| **Choose Layout…** | Pick the number of windows in each row using a five-by-five grid. |
| **Swap Windows by Dragging** | Drag one window onto another to trade their places. |

In **Choose Layout…**, each grid row is a band of the screen, from top to bottom. To put four windows above one window, click the fourth square in row 1 and the first square in row 2. **Apply** becomes available when your choices add up to the number of open windows on that display. Click a selected square again to clear its row.

A custom layout pauses automatic tiling. Opening or closing a window, or changing Spaces, returns to the automatic layout. Until then, the shortcut re-applies your custom layout.

When swapping, drop a window over another managed window. A drop elsewhere snaps it back. Normal edge resizing is left alone.

## How windows are handled

- Each display gets its own layout above the Dock and below the menu bar.
- Hidden and minimized windows, and windows on other Spaces, are skipped.
- Open and Save panels, modal dialogs, tiny helper panels, and floating palettes are left alone.
- Window Tiler learns each window's size limits and adjusts the layout to fit them.
- Terminal windows can leave a small gap because they resize in whole character cells.
- Switching native window tabs does not trigger a re-tile.
- Wispr Flow's transparent status overlay is ignored.

There is no hard window limit. If the display gets crowded, the app uses the closest layout that keeps every window visible.

## Build from source

With the Xcode command-line tools installed:

```bash
git clone https://github.com/sasheenmusic/WindowTiler.git
cd WindowTiler
./Scripts/build-app.sh
open "dist/Window Tiler.app"
```

The build script uses an available Apple Development signing identity to help keep Accessibility trust across local rebuilds. For a public build without a developer certificate, use an ad-hoc signature:

```bash
WINDOW_TILER_SIGNING_IDENTITY=- ./Scripts/build-app.sh
```

Ad-hoc builds may need Accessibility access granted again after a rebuild.

## Troubleshooting

**Windows do not move:** check **System Settings → Privacy & Security → Accessibility**.

**A window will not fit:** some apps enforce a minimum or maximum window size. Window Tiler works around these limits where possible.

**An app is slow to respond:** Accessibility requests are capped at one second. An app that times out is skipped for five seconds.

To view diagnostics:

```bash
log stream --predicate 'subsystem == "com.windowtiler.app"'
```

## Development

```bash
swift test
swift build
```

## License

[MIT](LICENSE).
