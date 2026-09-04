# iPod Pro Max

A Mac app that syncs music and podcasts to classic click-wheel iPods (iPod Video, nano 1st/2nd gen, photo, mini, and the original iPods). No iTunes, no Finder sync, no libgpod dependency: the iPod database format is implemented in Swift.

## How it works

- **Device** (`iPod Pro Max/Device/`): detects mounted iPods (`iPod_Control` folder on a local removable volume), identifies the model from `SysInfo`, `SysInfoExtended`, or the USB product id when those are empty, and knows each generation's artwork sizes and database-signature requirements.
- **Core** (`iPod Pro Max/Core/`): reader and writer for `iTunesDB` (tracks, videos, playlists, podcast groups, library sort indexes), `ArtworkDB` + `.ithmb` RGB565 thumbnails, the `Photo Database` (`Photos/`) with RGB565 / UYVY / I420 thumbnails and albums, the `Play Counts` file the iPod writes, and the hash58 signature used by iPod classic / nano 3G–4G (experimental).
- **Library** (`iPod Pro Max/Library/`): the app's own library (JSON in `~/Library/Application Support/iPod Pro Max`), metadata extraction with AVFoundation, a Music-app catalog (iTunesLibrary framework) with per-item sync status, Photos-app album access (PhotoKit), RSS podcast subscriptions and downloads, AAC transcoding for audio formats the iPod can't play, and H.264 Baseline 1.3 / 320×240 video conversion (AVAssetWriter, with the declared level patched in the MP4 so the iPod accepts it).
- **Sync** (`iPod Pro Max/Sync/`): incremental sync engine (reads play counts back, copies new files into `F00…F49`, removes deselected ones, rebuilds playlists and artwork, writes the database atomically) plus the main-actor coordinator that drives the UI.
- **UI** (`iPod Pro Max/UI/`): SwiftUI views for devices, music, videos, playlists, podcasts, photos, the Music import chooser, and settings.

### Apple Music
Songs from an Apple Music subscription are FairPlay-encrypted; no iPod can play them, so the Music import chooser lists them as "Apple Music (protected)". iTunes Store purchases, CD rips and files import normally. Items that live only in iCloud show as "Not downloaded" until they are downloaded in the Music app.

## Supported iPods (1.0)

| Model | Status |
| --- | --- |
| iPod Video (5th / 5.5 gen), nano 1G/2G, photo/color, mini, iPod 1G–4G | Full |
| iPod classic (all), nano 3G/4G | Experimental (signed database, untested on hardware) |
| nano 5G+, shuffle, touch | Not supported |

Apple Music / DRM-protected songs are skipped because the iPod can't play them.

## Permissions and entitlements
The app is not sandboxed but uses the Hardened Runtime, so access to protected resources needs both a usage string in Info.plist and a resource-access entitlement in `iPod Pro Max/iPod Pro Max.entitlements`, otherwise macOS denies silently without showing a prompt:

- Photos: `NSPhotoLibraryUsageDescription` + `com.apple.security.personal-information.photos-library`
- Music app downloads (AppleScript `download`): `NSAppleEventsUsageDescription` + `com.apple.security.automation.apple-events`
- Music library reading (iTunesLibrary): `NSAppleMusicUsageDescription`

To re-test the prompts during development: `tccutil reset Photos beardfm.iPod-Pro-Max` and `tccutil reset AppleEvents beardfm.iPod-Pro-Max`.

## Building

Open `iPod Pro Max.xcodeproj` in Xcode 26 and run. Deployment target is macOS 15. App Sandbox is off (the app is distributed outside the Mac App Store).

Development launch arguments (Edit Scheme › Arguments):

- `-simulatedIPodFolder /path/to/folder` — treat a folder with an `iPod_Control` directory as an iPod for this launch.
- `-libraryDir /path` — use a different library folder.
- `-initialSelection music|podcasts|device`

Settings › Advanced can also create a test iPod folder without hardware.

## Testing tools

- `Tools/dbtest/run.sh <samples dir> <ipod folder>` — end-to-end sync against a simulated iPod, then dumps the resulting database. Add `--read-only` to just parse an iPod folder.
- `Tools/gpodcheck/gpodcheck.c` — small C program that reads an iPod with [libgpod](https://sourceforge.net/projects/gtkpod/) (the reference open-source implementation) to cross-check databases written by this app. Build libgpod from source first; see the comment at the top of the file.

## Shipping

The app is signed with Developer ID and notarized, then distributed as a DMG from beard.fm (Cloudflare). Steps once the certificate is installed:

1. Product › Archive in Xcode, or `xcodebuild -scheme "iPod Pro Max" -configuration Release archive`.
2. Export with the Developer ID option (hardened runtime is already on).
3. `xcrun notarytool submit iPodProMax.dmg --keychain-profile <profile> --wait` and `xcrun stapler staple`.

Only an Apple Development certificate is installed on this Mac today, so local builds run but a Developer ID certificate is needed before the DMG can be distributed.
