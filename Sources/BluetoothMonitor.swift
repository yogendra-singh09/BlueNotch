import Foundation
import IOBluetooth

struct BTDevice {
    let rawAddress: String   // as IOBluetooth reports it, e.g. "c0-d1-25-83-ad-40"
    let name: String
    let majorClass: UInt32
    let minorClass: UInt32

    var key: String { normalizeAddress(rawAddress) }
}

/// "c0-d1-25-83-ad-40" / "C0:D1:25:83:AD:40" -> "C0:D1:25:83:AD:40"
func normalizeAddress(_ s: String) -> String {
    s.uppercased().replacingOccurrences(of: "-", with: ":")
}

/// Watches every Bluetooth device (Classic + BLE) and reports connect/disconnect transitions.
/// IOBluetooth notifications give instant feedback for Classic devices; a light poll of
/// `isConnected()` catches BLE devices (mice, keyboards) that don't fire those notifications.
final class BluetoothMonitor: NSObject {
    var onChange: ((BTDevice, Bool) -> Void)?

    private var state: [String: Bool] = [:]
    private var extraDevices: [String: IOBluetoothDevice] = [:]
    private var connectNote: IOBluetoothUserNotification?
    private var timer: Timer?

    func start() {
        for (dev, connected) in snapshot() { state[dev.key] = connected }
        connectNote = IOBluetoothDevice.register(forConnectNotifications: self,
                                                 selector: #selector(didConnect(_:device:)))
        let t = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in self?.poll() }
        t.tolerance = 0.5
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    @objc private func didConnect(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        if let addr = device.addressString { extraDevices[normalizeAddress(addr)] = device }
        device.register(forDisconnectNotification: self, selector: #selector(didDisconnect(_:device:)))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.poll() }
    }

    @objc private func didDisconnect(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        note.unregister()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.poll() }
    }

    private func snapshot() -> [(BTDevice, Bool)] {
        var devices: [String: IOBluetoothDevice] = extraDevices
        for d in (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? [] {
            if let a = d.addressString { devices[normalizeAddress(a)] = d }
        }
        return devices.values.compactMap { d in
            guard let addr = d.addressString else { return nil }
            let dev = BTDevice(rawAddress: addr,
                               name: d.name ?? d.nameOrAddress ?? addr,
                               majorClass: d.deviceClassMajor,
                               minorClass: d.deviceClassMinor)
            return (dev, d.isConnected())
        }
    }

    private func poll() {
        for (dev, connected) in snapshot() {
            let previous = state[dev.key]
            state[dev.key] = connected
            if let previous, previous != connected {
                onChange?(dev, connected)
            } else if previous == nil && connected {
                onChange?(dev, true) // newly paired device
            }
        }
    }
}
