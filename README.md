# Window Tiler

<img src="Resources/AppIcon.png" alt="Window Tiler icon" width="128">

Turn your open windows into a tidy, edge-to-edge layout. Window Tiler is a small, free macOS menu-bar app that works across multiple displays.

**Download requires Apple silicon and macOS 13 or later.** Released under the MIT license.

## Install

Paste this into Terminal:

```bash
curl -fsSL https://raw.githubusercontent.com/sasheenmusic/WindowTiler/main/install.sh | bash
```

The installer downloads the latest release, checks its checksum and code signature, and opens it. It updates your existing copy in **Applications** or **~/Applications**, keeping your settings and presets. For a first install, it uses **Applications** when writable, otherwise **~/Applications**. It does not ask for `sudo`. Run the same command again to update.

If macOS blocks opening, go to **System Settings → Privacy & Security → Open Anyway**, or right-click **Window Tiler.app** and choose **Open**. The app is not notarized by Apple. Enable Window Tiler under **System Settings → Privacy & Security → Accessibility** so it can move and resize windows.

For a manual install, download the ZIP from the [latest release](../../releases/latest), unzip it, and move **Window Tiler.app** to **Applications**.

## Updates

Choose **Check for Updates…** in the menu bar to check now. **Automatically Install Updates** is on by default: the app checks daily, installs signed updates, and restarts itself when idle. Uncheck it to update manually. Settings and saved presets are kept. An update restart keeps the active preset selected without moving windows.

Turning automatic updates off stops future downloads and automatic restarts. An update already downloaded may still install when you quit the app.

Public builds use an ad-hoc code signature. macOS may require you to grant Accessibility access again after an update.

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

A custom row layout pauses automatic tiling. Opening or closing a window returns to the automatic layout. Switching Mac desktops leaves windows where they are. Until the window set changes, the shortcut re-applies your custom row layout.

When swapping, drop a window over another managed window. A drop elsewhere snaps it back. Normal edge resizing is left alone.

## Saved presets

Arrange your windows, then choose **Save Preset…** from the menu bar. Give the preset a name and select the screens to include. Saving also activates it.

- **Remember apps** is on by default. Applying the preset puts the selected apps back in their saved spots. It can restore hidden or minimized windows, exit full screen, and bring saved windows from other Mac desktops. Other apps are left alone.
- **Launch missing apps** is off by default. Turn it on to open saved apps that are not running. It is available only with Remember apps enabled.
- With **Remember apps** off, the currently shown windows fill the saved spots. Extra windows stay where they are; unfilled spots stay empty.
- The save form includes only currently shown normal windows. Uncheck an app to leave it out of restoration while keeping its spot in the layout. Presets use one window per app.
- Each included screen keeps its own layout. Disconnected screens are skipped; saved sizes and positions scale to the current usable screen area when its resolution changes.

Only one preset is active at a time. It pauses automatic tiling and drag swapping, so you can move or resize windows freely. Opening or closing an app does not change the preset or arrange the other windows. Switching desktops does not move windows either.

Click a preset in the menu to activate it. Click it again to turn it off and resume automatic tiling. A preset's optional shortcut does the same. **Tile All Windows** and its shortcut reapply the active preset. Without an active preset, that command also gathers eligible normal windows from other Mac desktops before tiling them; hidden, minimized, and full-screen windows are left alone.

**Manage Presets…** shows a list, a read-only layout preview, app and screen checkboxes, and an optional shortcut recorder. Settings save automatically. Changes to an active preset take effect immediately; editing an inactive preset does not activate it. Arrange your actual windows and choose **Update from Current Windows** to replace the saved layout. Updating and deleting require confirmation.

Presets remain saved after restarting Window Tiler, but a normal restart activates none. If an app cannot be launched or moved, the other slots are applied and a message names the app. Moving windows between Mac desktops relies on macOS interfaces that may change; Window Tiler verifies each move and reports failures.

## How windows are handled

- Each display gets its own layout above the Dock and below the menu bar.
- Automatic tiling skips hidden and minimized windows and windows on other Mac desktops. Saved presets and an explicit Tile All Windows command follow the rules above.
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
./Scripts/test-preset-session.sh
./Scripts/test-window-discovery.sh
./Scripts/test-preset-boundaries.sh
./Scripts/test-installer.sh
./Scripts/test-updater.sh
./Scripts/test-sparkle-bundle.sh
swiftc Sources/WindowTilerApp/HotKey.swift Scripts/test-hotkeys.swift -o /tmp/windowtiler-hotkey-tests
/tmp/windowtiler-hotkey-tests
```

The session checks use in-memory settings and window stubs. The discovery checks simulate stale Accessibility handles, unresponsive apps, and temporary Electron flag cleanup; boundary checks cover capture filtering and shortcut recording through UI refreshes. The hotkey checks register temporary shortcuts and send events only within the test process. Neither moves your windows. Run these checks in a normal macOS login session.

The installer checks use offline downloads, fake signatures, and launch stubs in a temporary directory. They never replace your installed app.

The updater checks cover restart timing and menu settings. After building the app, `python3 Scripts/test-signed-updates.py` tests real signed upgrades, automatic relaunch, invalid signatures, and an already-current version using disposable apps. This requires the release key in Keychain and never runs the tiler or moves user windows. See [release instructions](Scripts/RELEASING.md) for packaging and signing.

`./Scripts/test-preset-windows.sh` runs the native fixture checks, including restoration across desktops and cancellation. It requires Accessibility access, two existing Mac desktops, and any running Window Tiler instance to be paused or closed. It moves only its disposable test app and removes that app afterward.

## License

[MIT](LICENSE).
