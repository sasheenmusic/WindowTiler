# Window Tiler help

## Accessibility is on, but windows will not move

An older update may have changed the app's signing identity. macOS can show an enabled entry for the old app while denying the current app access.

If the permission dialog offers **Show This App**, click it to reveal the running copy in Finder. Older versions can use the Finder locations below.

1. Quit Window Tiler from its menu bar icon.
2. In Finder, find your current **Window Tiler.app** in **Applications** or **~/Applications**. Use one installed copy. Avoid opening an older copy from Downloads or an old ZIP.
3. Select the app and press **Command–I**. Check **Version** and **Where**. Install the latest version from the [release page](https://github.com/sasheenmusic/WindowTiler/releases/latest) if needed.
4. Open **System Settings → Privacy & Security → Accessibility**.
5. Select **Window Tiler** and click **–** to remove its old entry. Remove only Window Tiler entries; leave other apps alone.
6. Click **+**, choose the current app from step 2, and enable its switch.
7. Reopen that same app. Try **Tile All Windows**.

macOS may ask you to unlock these settings. Follow its normal prompt. You do not need to disable macOS security or reset every app's permissions.

The first Developer ID release changes identity from older builds, so you may need this one fresh grant. Later releases keep the same signing team and app identity to help preserve access. macOS still controls permission and may ask again.

## Check for an old or duplicate copy

Quit any open Window Tiler copies. In Finder, check **Applications**, **~/Applications**, and **Downloads**. Keep using the latest installed app from one location. If the installer reports two installed copies, remove the older duplicate before running it again. Your settings and saved presets are separate from the app.

## If it still fails

Include these details when [reporting the problem](https://github.com/sasheenmusic/WindowTiler/issues):

- Window Tiler version and app location from Finder's **Get Info**.
- macOS version from **Apple menu → About This Mac**.
- Whether this happened after an update or a fresh install.
- The exact error message and whether all windows or one app fails.

Do not share passwords, signing keys, or a copy of your permissions database.
