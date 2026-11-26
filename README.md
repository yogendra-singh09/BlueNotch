# BlueNotch

A tiny macOS menu-bar app that shows a **Dynamic Island–style notification under your MacBook's notch** whenever a Bluetooth device connects or disconnects.

```
        ┌────[ notch ]────┐
   ┌────┴─────────────────┴────┐
   │ 🎧  AirPods Pro      82% 🔋│
   │  ● Connected · 11:42 AM   │
   └───────────────────────────┘
```

## Features

- Drops down from the notch with a spring animation and hides itself after ~4 seconds
- Shows the **device name**, a **device-type icon** (earbuds, headphones, mouse, keyboard, speaker, controller, phone…), and the **connect/disconnect time**
- Shows the **battery percentage** on connect, colour-coded (green / yellow ≤ 40% / red ≤ 20%), with **left / right / case** levels for earbuds
- Works with both Classic Bluetooth (headphones, speakers) and Bluetooth Low Energy devices (mice, keyboards)
- Appears on **every screen**. External displays without a notch get a matching pill at the top centre.
- Lightweight: native Swift + SwiftUI, no dependencies, no Dock icon
- Menu-bar controls: preview, pause, launch at login, quit

## Requirements

- macOS 14 (Sonoma) or later
- Apple Silicon Mac. A notched MacBook looks best, but any Mac works.
- Xcode Command Line Tools, which provide the Swift compiler:
  ```bash
  xcode-select --install
  ```

## Installation

```bash
git clone git@github.com:yogendra-singh09/BlueNotch.git
cd BlueNotch
./build.sh install
```

This compiles the app, copies it to `~/Applications/BlueNotch.app`, and launches it.

### First launch

1. **Allow Bluetooth access** when macOS asks. Without it the app can't see your devices.
   If you missed the prompt: *System Settings → Privacy & Security → Bluetooth → enable BlueNotch*.
2. BlueNotch registers itself to **launch at login** on first run. You can toggle this from the menu-bar icon.
3. Click the menu-bar icon (📶) → **Preview Connect** to see the notification.

### Build only (without installing)

```bash
./build.sh            # produces build/BlueNotch.app
open build/BlueNotch.app
```

## Usage

BlueNotch runs in the background. Its menu-bar icon offers:

| Menu item | What it does |
|---|---|
| Show Connected Devices | Show a notification, with battery, for every device connected right now |
| Preview Connect / Preview Disconnect | Show a sample notification |
| Pause Notifications | Temporarily stop showing notifications |
| Launch at Login | Start BlueNotch automatically when you log in |
| Quit BlueNotch | Exit the app |

## Battery support

macOS has no single public API for Bluetooth battery levels, so BlueNotch checks four sources:

1. IOBluetooth device properties (AirPods, Beats, many hands-free headsets)
2. `system_profiler SPBluetoothDataType` (most headsets / earbuds)
3. IOKit HID `BatteryPercent` (Apple keyboards, mice, trackpads, some third-party HID devices)
4. The standard **BLE Battery Service** (`0x180F` / `0x2A19`), read directly with CoreBluetooth. Many third-party BLE mice and keyboards report their battery only this way.

Battery levels often arrive a second or two after the device connects, so the app retries for about 3 seconds and updates the notification once a value appears. **If a device doesn't expose its battery through any of these, no percentage is shown.**

## Customisation

Edit the values below, then run `./build.sh install` again.

| Setting | Location |
|---|---|
| How long the notification stays | `displayDuration` in `Sources/Notch.swift` |
| Notification width | `expandedWidth` in `Sources/Notch.swift` |
| Content height | `contentHeight` in `Sources/Notch.swift` |
| Polling interval for BLE devices | `Timer(timeInterval: 2.0 …)` in `Sources/BluetoothMonitor.swift` |
| Device icons | `DeviceInfo.symbol(...)` in `Sources/DeviceInfo.swift` |

> Note: the app is ad-hoc signed, so macOS may ask for Bluetooth permission again after each rebuild.

## Project structure

```
BlueNotch/
├── build.sh                    # build / install script
├── Info.plist                  # app bundle metadata + Bluetooth usage description
└── Sources/
    ├── main.swift              # app entry, menu bar, event handling
    ├── BluetoothMonitor.swift  # connect / disconnect detection
    ├── DeviceInfo.swift        # battery lookup + device icons
    ├── BLEBattery.swift        # BLE Battery Service reader (CoreBluetooth)
    └── Notch.swift             # notch window, animation, SwiftUI views
```

## How it works

- **Detection:** IOBluetooth connect/disconnect notifications give instant events for Classic devices. A light 2-second poll of `IOBluetoothDevice.pairedDevices()` catches BLE devices, which don't fire those notifications.
- **Display:** a borderless, click-through `NSPanel` sits above the menu bar on each screen. A SwiftUI shape grows from the notch's exact size, read from `NSScreen.safeAreaInsets` and `auxiliaryTopLeftArea` / `auxiliaryTopRightArea`, to the expanded pill.

## Troubleshooting

| Problem | Fix |
|---|---|
| No notification appears | Check Bluetooth permission (see *First launch*), and make sure *Pause Notifications* is off |
| No battery percentage | The device doesn't expose its battery over any supported channel. Try *Show Connected Devices* a few seconds after connecting, since some devices report battery late. |
| BLE device shows a second late | Expected: BLE devices are detected by the 2-second poll |
| "Couldn't change Launch at Login" | Make sure the app is in `~/Applications` or `/Applications` (use `./build.sh install`) |
| Intel Mac | In `build.sh`, change `-target arm64-apple-macos14.0` to `-target x86_64-apple-macos14.0` |

## Uninstall

```bash
pkill -x BlueNotch
rm -rf ~/Applications/BlueNotch.app
defaults delete local.bluenotch 2>/dev/null
```

Then remove it from *System Settings → General → Login Items* if it's still listed.
