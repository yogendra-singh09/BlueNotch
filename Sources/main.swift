import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let monitor = BluetoothMonitor()
    private let notch = NotchController()
    private let bleBattery = BLEBatteryReader()
    private var statusItem: NSStatusItem!
    private var profileCache: [String: ProfileEntry] = [:]
    private let bg = DispatchQueue(label: "bluenotch.info", qos: .utility)

    private var paused: Bool {
        get { UserDefaults.standard.bool(forKey: "paused") }
        set { UserDefaults.standard.set(newValue, forKey: "paused") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        registerLoginItemOnFirstRun()

        bg.async {
            let profile = DeviceInfo.systemProfile()
            DispatchQueue.main.async { self.profileCache = profile }
        }

        notch.onPresent = { [weak self] event in self?.playSound(for: event) }
        monitor.onChange = { [weak self] device, connected in self?.handle(device, connected: connected) }
        monitor.start()

        if CommandLine.arguments.contains("--preview") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.testConnect() }
        }
        if CommandLine.arguments.contains("--show-connected") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.showConnected() }
        }
    }

    // MARK: - Events

    private func handle(_ device: BTDevice, connected: Bool) {
        guard !paused else { return }
        show(device, connected: connected)
    }

    private func show(_ device: BTDevice, connected: Bool) {
        var event = NotchEvent(name: device.name, connected: connected, date: Date(),
                               symbol: symbol(for: device), battery: nil)
        if connected { event.battery = DeviceInfo.ioBluetoothBattery(rawAddress: device.rawAddress) }
        notch.show(event)
        refreshInfo(for: device, eventID: event.id, connected: connected, attempt: 0)
    }

    private func symbol(for device: BTDevice) -> String {
        DeviceInfo.symbol(name: device.name, major: device.majorClass, minor: device.minorClass,
                          minorType: profileCache[device.key]?.minorType)
    }

    /// Battery levels often show up a second or two after the link comes up, so retry a few times.
    private func refreshInfo(for device: BTDevice, eventID: UUID, connected: Bool, attempt: Int) {
        let delays: [TimeInterval] = [0.1, 1.0, 2.2]
        guard attempt < delays.count else { return }
        bg.asyncAfter(deadline: .now() + delays[attempt]) {
            let profile = DeviceInfo.systemProfile()
            let hid = connected ? DeviceInfo.hidBattery(address: device.key, name: device.name) : nil
            DispatchQueue.main.async {
                self.profileCache.merge(profile) { _, new in new }
                var battery: BatteryInfo? = nil
                if connected {
                    battery = DeviceInfo.ioBluetoothBattery(rawAddress: device.rawAddress)
                    if battery == nil, let b = profile[device.key]?.battery, !b.isEmpty { battery = b }
                    if battery == nil, let h = hid { battery = BatteryInfo(main: h) }
                }
                let symbol = self.symbol(for: device)
                self.notch.update(id: eventID) { e in
                    e.symbol = symbol
                    if let battery { e.battery = battery }
                }
                guard connected && battery == nil else { return }

                // Last resort: read the BLE Battery Service directly (third-party mice/keyboards).
                self.bleBattery.read(name: device.name) { pct in
                    if let pct {
                        self.notch.update(id: eventID) { $0.battery = BatteryInfo(main: pct) }
                    } else {
                        self.refreshInfo(for: device, eventID: eventID, connected: connected, attempt: attempt + 1)
                    }
                }
            }
        }
    }

    // MARK: - Menu bar

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "dot.radiowaves.left.and.right",
                                           accessibilityDescription: "BlueNotch")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    @objc private func testConnect() {
        notch.show(NotchEvent(name: "AirPods Pro", connected: true, date: Date(),
                              symbol: DeviceInfo.symbol(name: "AirPods Pro", major: 4, minor: 1, minorType: nil),
                              battery: BatteryInfo(left: 82, right: 85, caseLevel: 60)))
    }

    @objc private func testDisconnect() {
        notch.show(NotchEvent(name: "Toad 8", connected: false, date: Date(),
                              symbol: DeviceInfo.symbol(name: "Toad 8", major: 0, minor: 0, minorType: "Mouse"),
                              battery: nil))
    }

    /// Shows a notification (with battery) for every device that's connected right now.
    @objc private func showConnected() {
        let devices = monitor.connectedDevices
        guard !devices.isEmpty else {
            notch.show(NotchEvent(name: "No devices connected", connected: false, date: Date(),
                                  symbol: "dot.radiowaves.left.and.right", battery: nil))
            return
        }
        devices.forEach { show($0, connected: true) }
    }

    @objc private func togglePause() { paused.toggle() }

    // MARK: - Sound

    static let connectSound = "Glass"      // any name from /System/Library/Sounds
    static let disconnectSound = "Bottle"

    /// Stored inverted so the default (key absent) is "sound on".
    private var soundEnabled: Bool {
        get { !UserDefaults.standard.bool(forKey: "soundMuted") }
        set { UserDefaults.standard.set(!newValue, forKey: "soundMuted") }
    }

    @objc private func toggleSound() { soundEnabled.toggle() }

    private func playSound(for event: NotchEvent) {
        guard soundEnabled else { return }
        let name = event.connected ? Self.connectSound : Self.disconnectSound
        // Copy so overlapping events can each play instead of being dropped.
        (NSSound(named: name)?.copy() as? NSSound)?.play()
    }

    @objc private func toggleLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't change Launch at Login"
            alert.informativeText = "\(error.localizedDescription)\n\nMove BlueNotch to your Applications folder and try again."
            alert.runModal()
        }
    }

    private func registerLoginItemOnFirstRun() {
        guard !UserDefaults.standard.bool(forKey: "didRegisterLogin") else { return }
        if (try? SMAppService.mainApp.register()) != nil {
            UserDefaults.standard.set(true, forKey: "didRegisterLogin")
        }
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(withTitle: "BlueNotch", action: nil, keyEquivalent: "").isEnabled = false
        menu.addItem(.separator())
        menu.addItem(withTitle: "Show Connected Devices", action: #selector(showConnected), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Preview Connect", action: #selector(testConnect), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Preview Disconnect", action: #selector(testDisconnect), keyEquivalent: "").target = self
        menu.addItem(.separator())
        let pause = menu.addItem(withTitle: "Pause Notifications", action: #selector(togglePause), keyEquivalent: "")
        pause.target = self
        pause.state = paused ? .on : .off
        let sound = menu.addItem(withTitle: "Play Sound", action: #selector(toggleSound), keyEquivalent: "")
        sound.target = self
        sound.state = soundEnabled ? .on : .off
        let login = menu.addItem(withTitle: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit BlueNotch", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
