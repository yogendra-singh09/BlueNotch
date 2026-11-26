import CoreBluetooth
import Foundation

/// Reads the standard BLE Battery Service (0x180F / Battery Level 0x2A19) from devices that
/// macOS is already connected to. Many third-party mice and keyboards expose their battery
/// only this way, so it never shows up in system_profiler or IOKit.
final class BLEBatteryReader: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private static let batteryService = CBUUID(string: "180F")
    private static let batteryLevel = CBUUID(string: "2A19")

    private var central: CBCentralManager!
    private var waitingForPower: [() -> Void] = []
    private var pending: [UUID: (peripheral: CBPeripheral, completions: [(Int?) -> Void])] = [:]

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    /// Calls back on the main queue with 0–100, or nil if the device has no readable battery.
    func read(name: String, timeout: TimeInterval = 3, completion: @escaping (Int?) -> Void) {
        guard central.state == .poweredOn else {
            if central.state == .unknown || central.state == .resetting {
                waitingForPower.append { [weak self] in self?.read(name: name, timeout: timeout, completion: completion) }
            } else {
                completion(nil)
            }
            return
        }

        let matches = central.retrieveConnectedPeripherals(withServices: [Self.batteryService])
            .filter { $0.name == name }
        guard let peripheral = matches.first else { completion(nil); return }

        let id = peripheral.identifier
        if pending[id] != nil {
            pending[id]?.completions.append(completion)
            return
        }
        pending[id] = (peripheral, [completion])
        peripheral.delegate = self
        central.connect(peripheral)

        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.finish(id, value: nil)
        }
    }

    private func finish(_ id: UUID, value: Int?) {
        guard let entry = pending.removeValue(forKey: id) else { return }
        // Only drops this app's logical link; the system keeps the device connected.
        central.cancelPeripheralConnection(entry.peripheral)
        entry.completions.forEach { $0(value) }
    }

    // MARK: CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state != .unknown && central.state != .resetting else { return }
        let waiting = waitingForPower
        waitingForPower.removeAll()
        waiting.forEach { $0() }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([Self.batteryService])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        finish(peripheral.identifier, value: nil)
    }

    // MARK: CBPeripheralDelegate

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == Self.batteryService }) else {
            finish(peripheral.identifier, value: nil); return
        }
        peripheral.discoverCharacteristics([Self.batteryLevel], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let ch = service.characteristics?.first(where: { $0.uuid == Self.batteryLevel }) else {
            finish(peripheral.identifier, value: nil); return
        }
        peripheral.readValue(for: ch)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == Self.batteryLevel else { return }
        let value = characteristic.value?.first.map(Int.init)
        finish(peripheral.identifier, value: value.flatMap { (0...100).contains($0) ? $0 : nil })
    }
}
