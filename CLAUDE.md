# Multicast: notes for Claude

## Keep the README and its screenshots current

Any change that alters what a person sees or does in the apps (a screen, a control, a row, wording, a new
feature, a changed behaviour or limitation) is not finished until the README matches it. Before calling such
work done, and before it is merged into main:

1. **Text.** Update the sections of `README.md` the change touches ("What it does", the feature's own section,
   "Status and limitations", the command-line examples). Say plainly what was verified live and what was not.
2. **Screenshots.** The images in `docs/images/` are the apps' own review renders with sample data, never
   captures of a real library or real speakers. If the change shows on a screen that has a screenshot, or adds a
   screen worth showing, render them again and replace the files (same names, so the README keeps working):
   - **Mac:** `Multicast.app/Contents/MacOS/Multicast --snapshot <dir>` writes every scene in light and dark
     (`Apps/Mac/Snapshot/Snapshotter.swift`). The README uses the dark renders, scaled to 1600 px wide
     (`sips -Z 1600`): `main-iphone-as-speaker` → `mac-library-speakers.png`, `main-up-next` →
     `mac-up-next.png`, `main-search-with-catalog` → `mac-search.png`.
   - **iPhone:** build "Multicast Remote" for the simulator, launch with `-MCScene <name> -MCAppearance dark`
     (`Apps/iOS/Support/RemoteScenes.swift`), status bar overridden to 09:41, `xcrun simctl io <device>
     screenshot`, scaled to 1200 px tall (`sips -Z 1200`): `phone-speaker` → `iphone-speakers.png`,
     `now-playing`, `playlists`, `up-next` → `iphone-<name>.png`. Use a simulator of your own
     (`xcrun simctl create`), because other sessions boot and shut down the shared ones.
3. **New states get a review scene.** A new screen or state gets a mock scene (Mac `MockScene`, iPhone
   `RemoteScene`) so it can be rendered without real hardware, and the README lists the scene name.
4. **Look at the result.** Open each replaced image and check it shows the change and nothing private.

## This repository is public

Never put a real name, email address, host name, signing team id, device id or MAC address, serial number, key
or token, LAN IP address, real room or speaker name, or a real playlist or song name in a tracked file, a
screenshot or a commit message. Sample data only ("Hall Sonos", "Main Bedroom", "Slow Weather"). Per-machine
signing lives in the git-ignored `Apps/Config/Local.xcconfig`.

## Running the Mac app

Run it with `Apps/Scripts/run-mac.sh`, which installs to `/Applications` and opens it from there: macOS ties
Local Network access to where the app lives, so a copy run from a build folder cannot see speakers.
