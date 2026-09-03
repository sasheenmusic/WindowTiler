# Window Tiler

A small native macOS menu-bar app that arranges all normal app windows into a balanced, edge-to-edge mosaic.

## Build and run

```bash
./Scripts/build-app.sh
open "dist/Window Tiler.app"
```

On first launch, allow **Window Tiler** in **System Settings → Privacy & Security → Accessibility**.

Press **Control–Option–Command–T** to tile your windows. Click the grid icon in the menu bar to tile manually, choose another shortcut, or turn automatic re-tiling on and off.

Automatic re-tiling is on by default. Window Tiler listens for window events instead of polling, so when a normal window opens, closes, minimizes, or returns, the visible windows reflow about a quarter of a second after the change settles. Minimized windows, hidden apps, and windows on other Spaces stay out of the way until you bring them back.

Windows stay on their current display and are tiled within that display's usable area, avoiding the menu bar and Dock. Every visible window receives an approximately equal share of the display. A window reported as a dialog counts only when it is the app's main window, so Open and Save panels do not reflow the desktop. Temporary system popups, tiny helper panels, and floating palettes are left alone.

Window Tiler learns the minimum and maximum size each window actually permits by watching what the window does when asked to fill its tile, and re-lays out the screen with that knowledge. Learned limits are forgotten when a window closes and re-measured on every manual tile. Terminal resizes in whole character cells, so a window that lands up to one cell short of its tile keeps that wiggle room at its bottom and right edges instead of being treated as fixed-size. It allows up to five windows per row while the screen can still honor every window's minimum size, then compares valid arrangements and favors equal row heights and equal window areas. Minimum-size windows may grow to complete a row; truly bounded windows become blocks that the other windows tile around. Shared pixel boundaries make every tile touch its neighbors and the usable screen edges with zero gaps. There is no hard window limit: if the screen becomes too crowded to preserve both five-across and every minimum size, Window Tiler keeps every window visible and uses the closest complete layout that fits.

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
