# Window Tiler

A small native macOS menu-bar app that arranges all normal app windows into a balanced, edge-to-edge mosaic.

## Build and run

```bash
./Scripts/build-app.sh
open "dist/Window Tiler.app"
```

On first launch, allow **Window Tiler** in **System Settings → Privacy & Security → Accessibility**.

Press **Control–Option–Command–T** to tile your windows. Click the grid icon in the menu bar to tile manually, choose another shortcut, or turn automatic re-tiling on and off.

Automatic re-tiling is on by default. When a normal window opens, closes, minimizes, or returns, the visible windows reflow within about one second. Minimized windows and hidden apps stay out of the way until you bring them back.

Windows stay on their current display and are tiled within that display's usable area, avoiding the menu bar and Dock. Every visible window receives an approximately equal share of the display. Main windows reported by an app as dialogs are included; temporary system popups, tiny helper panels, and floating palettes are left alone.

Window Tiler measures the minimum and maximum size each app actually permits. It allows up to five windows per row while the screen can still honor every window's minimum size, then compares valid arrangements and favors equal row heights and equal window areas. Minimum-size windows may grow to complete a row; truly bounded windows become blocks that the other windows tile around. Shared pixel boundaries make every tile touch its neighbors and the usable screen edges with zero gaps. There is no hard window limit: if the screen becomes too crowded to preserve both five-across and every minimum size, Window Tiler keeps every window visible and uses the closest complete layout that fits.

On multi-monitor Macs, each display is tiled independently using its own usable area. Moving a window to another display, changing a resolution, moving the menu bar or Dock, and connecting or disconnecting a display all trigger automatic re-tiling.

Wispr Flow's transparent status HUD is ignored because macOS reports it as a large window even though it has no visible content.

## Develop

```bash
swift test
swift build
```
