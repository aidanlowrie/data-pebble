# Data Pebble

A small native Mac menu-bar app for understanding Wi-Fi data use.

Open **Data Pebble.app**. The `↕` number in the menu bar is today's total. Click it for downloads, uploads, current traffic, 7- and 30-day history, and estimated app usage. The **Since reset** counter measures an activity without deleting daily history. Reset it before opening or playing something; all background traffic in that interval is included.

Data Pebble alerts only when **Apple transfers · Mac** increases, including either downloads or uploads. **macOS system** and named **simulator** transfers are still measured but do not trigger alerts. An alert fires once at least 1 MB of new transfer has accumulated since the previous alert; smaller increases are counted but stay silent. Alerts name the source, show its increase and today's recorded total, and replace the previous alert for that source. Allow notifications when macOS asks. Checks run every 30 seconds; historical totals at launch do not trigger an alert. The **Test background transfer alert** menu item checks the notification without transferring data or changing recorded usage. Enable banners and sounds in System Settings → Notifications → Data Pebble; macOS Focus and notification settings control presentation.

The `…` menu contains **Open at login**, **Export history**, **Test background transfer alert**, and **Quit**. If macOS asks for approval to run at login, allow Data Pebble in System Settings → General → Login Items. Keep this app bundle in its current location when login startup is enabled.

## Install

```sh
brew install --cask aidanlowrie/tap/data-pebble
```

Then open **Data Pebble** from Applications. Update with `brew upgrade --cask data-pebble`; remove with `brew uninstall --cask data-pebble` (add `--zap` to also delete recorded history).

## What the numbers mean

- Tracking starts when the app first opens. Earlier data cannot be reconstructed. Today's first day is partial.
- Totals are this Mac's Wi-Fi interface (`en0`) bytes, across all Wi-Fi networks, while the app is running. Both uploads and downloads count. Local network traffic is included; Ethernet and other devices are excluded. These are not carrier billing records.
- App estimates come from macOS `nettop`. They may differ from interface totals due to protocol overhead, short-lived connections, VPNs, and shared services. An app's traffic through a VPN may appear under the VPN instead.
- **Apple transfers** is `nsurlsessiond`, split by the live process's user and simulator identity. Other apps may use each service; this identifies the worker, not the requesting app. Simulator names include a short device ID to keep devices distinct. Metadata unavailable at observation time falls back to a separate process label. **Earlier combined** preserves old grouped history, which cannot be split retroactively.
- The first cumulative interface and app samples are discarded. Interface counter resets produce a new baseline. Measurements crossing midnight are split proportionally. After sleep, interface counters are re-baselined; some traffic around sleep/wake can be missed.
- Decimal units: 1 MB = 1,000,000 bytes; 1 GB = 1,000,000,000 bytes.
- Downloaded photos, videos and documents can be viewed without internet traffic. Streaming and cloud syncing use data. The counter measures the whole Mac, so background activity can appear during any activity.

Wi-Fi totals are read directly from macOS kernel counters every 15 seconds with the panel closed, or every 2 seconds while it is open. One persistent, low-CPU network monitor updates app estimates every 30 seconds. Its input stays open to avoid an EOF busy loop. Timers stop during sleep, and the panel is released while closed. App values are accumulated totals, not live transfer rates. It does not run speed tests, intercept packet contents, contact a server, or alter iCloud or router settings. No dependencies are downloaded.

History is saved every 60 seconds, before sleep, and on normal quit to `~/Library/Application Support/DataPebble/usage.json`. An abrupt crash can lose the last unsaved samples. History remains after quitting. CSV export includes daily totals and daily app estimates.

## Build

Run `./build.sh` from this directory with Apple's command-line developer tools installed. It builds a universal (Apple silicon and Intel) app, ad-hoc signed and not notarised. `./package.sh` also writes `dist/DataPebble-<version>.zip` and its SHA-256 for a GitHub release; update `version` and `sha256` in the cask in the `aidanlowrie/homebrew-tap` repo to match.

To stop recording, choose **Quit Data Pebble**. To stop automatic startup, turn off **Open at login** first, or disable it in macOS Login Items.
