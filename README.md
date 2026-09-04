# Window Tiler

A small native macOS menu-bar app that arranges all normal app windows into a balanced, edge-to-edge mosaic. Free and open source under the MIT license.

## Install

1. Download `Window-Tiler-<version>.zip` from the [latest release](../../releases/latest) and unzip it.
2. Drag **Window Tiler.app** into your Applications folder.
3. The first time, right-click the app and choose **Open** (it is signed by the author but not notarized by Apple, so macOS shows a warning once). On macOS Sequoia you may instead need **System Settings → Privacy & Security → Open Anyway**.
4. Allow **Window Tiler** in **System Settings → Privacy & Security → Accessibility** so it can move windows.

Requires macOS 13 or later.

## Build and run

```bash
./Scripts/build-app.sh
open "dist/Window Tiler.app"
```

On first launch, allow **Window Tiler** in **System Settings → Privacy & Security → Accessibility**.

Press **Control–Option–Command–T** to tile your windows. Click the grid icon in the menu bar to tile manually, choose another shortcut, or turn automatic re-tiling on and off.

**Choose Layout…** opens a small floating panel with a five-by-five matrix for the times the automatic split is not the one you want. Each row of the matrix is a band of the screen, top to bottom. Click the fourth square in row 1 and the first square in row 2 to put four windows across the top and one below; click a lit square again to clear its row. The panel shows how many windows are open on that display, and Apply lights up when the squares add up to that number. Bands are equal height and the windows in a band share its width. Applying pauses automatic re-tiling; the moment a window opens, closes, or the Space changes, automatic re-tiling turns itself back on and reflows. Until then the shortcut and Tile All Windows re-apply the hand-picked layout. The matrix holds up to five per row and five rows.

**Swap by dragging.** Drag any window onto the area of another window and let go: the two trade places, each taking the other's tile. Drop a window on empty space, on its own area, or on something Window Tiler does not manage, and it snaps back to where it was. Dragging an edge to resize, or a click that wobbles a few points, is left alone. The gesture works whether automatic re-tiling is on or off and can be switched off with **Swap Windows by Dragging** in the menu.

Automatic re-tiling is on by default. Switching between native window tabs (Terminal, Finder, TextEdit) does not count as a change, and a re-tile keeps windows in their current reading order. Window Tiler listens for window events instead of polling, so when a normal window opens, closes, minimizes, or returns, the visible windows reflow about a quarter of a second after the change settles. Minimized windows, hidden apps, and windows on other Spaces stay out of the way until you bring them back.

Windows stay on their current display and are tiled within that display's usable area, avoiding the menu bar and Dock. Every visible window receives an approximately equal share of the display. Open and Save panels and modal dialogs are never tiled, and a non-modal window reported as a dialog counts only when the app has no standard window at all. Temporary system popups, tiny helper panels, and floating palettes are left alone.

Window Tiler learns the minimum and maximum size each window actually permits by watching what the window does when asked to fill its tile, and re-lays out the screen with that knowledge. Learned limits are forgotten when a window closes and re-measured on every manual tile. Terminal resizes in whole character cells, so a window that lands up to one cell short of its tile keeps that wiggle room at its bottom and right edges instead of being treated as fixed-size. It allows up to five windows per row while the screen can still honor every window's minimum size, then compares valid arrangements and favors equal row heights and equal window areas. **Windows Per Row** in the menu changes that fold to 2, 3, 4, or 5 (the default); windows are still spread evenly across the rows the fold requires, so five windows at 2 become 2 + 2 + 1. The choice is remembered, takes effect immediately, ends any hand-picked layout, and shapes the automatic layout only; the Choose Layout matrix stays five wide. Minimum-size windows may grow to complete a row; truly bounded windows become blocks that the other windows tile around. Shared pixel boundaries make every tile touch its neighbors and the usable screen edges with zero gaps. There is no hard window limit: if the screen becomes too crowded to preserve both five-across and every minimum size, Window Tiler keeps every window visible and uses the closest complete layout that fits.

On multi-monitor Macs, each display is tiled independently using its own usable area. Moving a window to another display, changing a resolution, moving the menu bar or Dock, and connecting or disconnecting a display all trigger automatic re-tiling.

Wispr Flow's transparent status HUD is ignored because macOS reports it as a large window even though it has no visible content.

Every Accessibility request is capped at one second, and an app that fails to answer in time is skipped for five seconds instead of freezing the tiler. Learned size limits expire after ten minutes so a window whose limits change is measured again.

Diagnostics go to the unified log:

```bash
log stream --predicate 'subsystem == "com.windowtiler.app"'
```

## Develop

```bash
swift test
swift build
```

## License

MIT. See [LICENSE](LICENSE).
