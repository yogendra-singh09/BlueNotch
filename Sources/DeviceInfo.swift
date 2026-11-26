import AppKit
import IOBluetooth
import IOKit

struct BatteryInfo: Equatable {
    var main: Int?
    var left: Int?
    var right: Int?
    var caseLevel: Int?

    /// Single headline number: main battery, or the weaker earbud.
    var primary: Int? { main ?? [left, right].compactMap { $0 }.min() }
    var isEmpty: Bool { primary == nil && caseLevel == nil }
}

struct ProfileEntry {
    var minorType: String?
    var battery: BatteryInfo
}

enum DeviceInfo {

    // MARK: - system_profiler (works for most headsets/AirPods, gives device type for BLE devices)

    /// Blocking (~0.2s). Call off the main thread. Keyed by normalized address.
    static func systemProfile() -> [String: ProfileEntry] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        p.arguments = ["SPBluetoothDataType", "-json", "-detailLevel", "basic"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return [:] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()

        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let controllers = root["SPBluetoothDataType"] as? [[String: Any]] else { return [:] }

        var out: [String: ProfileEntry] = [:]
        for controller in controllers {
            for (_, value) in controller {
                guard let list = value as? [[String: Any]] else { continue }
                for item in list {
                    for (_, propsAny) in item {
                        guard let props = propsAny as? [String: Any],
                              let addr = props["device_address"] as? String else { continue }
                        let battery = BatteryInfo(
                            main: pct(props["device_batteryLevelMain"]) ?? pct(props["device_batteryLevel"]),
                            left: pct(props["device_batteryLevelLeft"]),
                            right: pct(props["device_batteryLevelRight"]),
                            caseLevel: pct(props["device_batteryLevelCase"]))
                        out[normalizeAddress(addr)] = ProfileEntry(minorType: props["device_minorType"] as? String,
                                                                   battery: battery)
                    }
                }
            }
        }
        return out
    }

    private static func pct(_ v: Any?) -> Int? {
        if let n = v as? NSNumber { return valid(n.intValue) }
        guard let s = v as? String else { return nil }
        return valid(Int(s.trimmingCharacters(in: CharacterSet(charactersIn: "% "))) ?? -1)
    }

    private static func valid(_ n: Int) -> Int? { (1...100).contains(n) ? n : nil }

    // MARK: - IOBluetooth (AirPods / Beats / many HFP headsets)

    /// Must run on the main thread.
    static func ioBluetoothBattery(rawAddress: String) -> BatteryInfo? {
        guard let d = IOBluetoothDevice(addressString: rawAddress) else { return nil }
        func v(_ key: String) -> Int? {
            guard d.responds(to: NSSelectorFromString(key)),
                  let n = d.value(forKey: key) as? NSNumber else { return nil }
            return valid(n.intValue)
        }
        let info = BatteryInfo(main: v("batteryPercentSingle") ?? v("batteryPercentCombined"),
                               left: v("batteryPercentLeft"),
                               right: v("batteryPercentRight"),
                               caseLevel: v("batteryPercentCase"))
        return info.isEmpty ? nil : info
    }

    // MARK: - IOKit HID (Apple keyboards/mice/trackpads and some third-party HID devices)

    static func hidBattery(address: String, name: String) -> Int? {
        for cls in ["AppleDeviceManagementHIDEventService", "IOHIDDevice", "AppleUserHIDEventService"] {
            var it: io_iterator_t = 0
            guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(cls), &it) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(it) }
            var s = IOIteratorNext(it)
            while s != 0 {
                defer { IOObjectRelease(s); s = IOIteratorNext(it) }
                guard let n = prop(s, "BatteryPercent") as? NSNumber, let pctValue = valid(n.intValue) else { continue }
                let addr = (prop(s, "DeviceAddress") as? String).map(normalizeAddress)
                let product = prop(s, "Product") as? String
                if addr == address || product == name { return pctValue }
            }
        }
        return nil
    }

    private static func prop(_ s: io_object_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(s, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    // MARK: - Icon

    static func symbol(name: String, major: UInt32, minor: UInt32, minorType: String?) -> String {
        let n = name.lowercased()
        let t = (minorType ?? "").lowercased()
        func has(_ words: String...) -> Bool { words.contains { n.contains($0) || t.contains($0) } }

        var candidates: [String] = []
        if n.contains("airpods max") { candidates += ["airpods.max", "airpodsmax"] }
        else if n.contains("airpods pro") { candidates += ["airpods.pro", "airpodspro"] }
        else if n.contains("airpods") { candidates += ["airpods"] }
        else if has("buds", "earbud", "tws", "earphone") { candidates += ["earbuds", "airpods", "headphones"] }
        else if has("headphone", "headset", "beats", "wh-", "qc") { candidates += ["headphones"] }
        else if has("speaker", "soundbar", "boombox", "homepod") { candidates += ["hifispeaker.fill"] }
        else if has("keyboard", "keys") { candidates += ["keyboard.fill"] }
        else if has("trackpad") { candidates += ["rectangle.and.hand.point.up.left.fill"] }
        else if has("mouse", "mx master", "pointing") { candidates += ["computermouse.fill"] }
        else if has("controller", "gamepad", "joystick", "xbox", "dualsense", "dualshock") { candidates += ["gamecontroller.fill"] }
        else if has("iphone", "phone", "pixel", "galaxy") { candidates += ["iphone"] }
        else if has("watch") { candidates += ["applewatch"] }
        else if has("pencil", "stylus") { candidates += ["applepencil", "pencil"] }

        // Classic Bluetooth class-of-device fallback
        switch major {
        case 4: // Audio/Video
            candidates += (minor == 5 ? ["hifispeaker.fill"] : ["headphones"])
        case 5: // Peripheral
            if minor & 0x10 != 0 { candidates += ["keyboard.fill"] }
            if minor & 0x20 != 0 { candidates += ["computermouse.fill"] }
            if minor & 0x0F == 1 || minor & 0x0F == 2 { candidates += ["gamecontroller.fill"] }
        case 2: candidates += ["iphone"]
        case 1: candidates += ["laptopcomputer"]
        case 7: candidates += ["applewatch"]
        default: break
        }
        candidates += ["dot.radiowaves.left.and.right"]

        return candidates.first { NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil }
            ?? "dot.radiowaves.left.and.right"
    }
}
