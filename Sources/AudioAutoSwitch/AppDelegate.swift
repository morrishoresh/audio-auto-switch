import AppKit
import ServiceManagement
import os

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private static let targetVolumeKey = "targetVolume"
    private static let volumeChoices = stride(from: 10, through: 100, by: 10).map { $0 }
    /// Input devices are always set to full volume.
    private static let inputVolume = 100
    /// Bluetooth devices often reconnect a few seconds after wake/login, so keep looking for a while.
    private static let retryInterval: TimeInterval = 1
    private static let maxAttempts = 20

    /// Menu item payload for picking a target device; `uid == nil` clears the target.
    private struct Choice {
        let direction: Direction
        let uid: String?
    }

    private let log = Logger(subsystem: "com.morrishoresh.AudioAutoSwitch", category: "switch")
    private let defaults = UserDefaults.standard
    private var statusItem: NSStatusItem!
    private var retryTimer: Timer?
    private var attempts = 0
    private var pending: [Direction] = []

    /// Volume percentage (10–100) applied to the target output device, or nil to leave volume and mute unchanged.
    /// Defaults to 100. Stored as 0 for nil.
    private var targetVolume: Int? {
        get {
            let stored = defaults.object(forKey: Self.targetVolumeKey) as? Int ?? 100
            return stored == 0 ? nil : stored
        }
        set { defaults.set(newValue ?? 0, forKey: Self.targetVolumeKey) }
    }

    private var targetVolumeLabel: String {
        targetVolume.map { "\($0)%" } ?? "Don't Change"
    }

    private func uidKey(_ direction: Direction) -> String {
        direction == .output ? "targetDeviceUID" : "targetInputUID"
    }

    private func nameKey(_ direction: Direction) -> String {
        direction == .output ? "targetDeviceName" : "targetInputName"
    }

    private func targetUID(_ direction: Direction) -> String? {
        defaults.string(forKey: uidKey(direction))
    }

    private func targetName(_ direction: Direction) -> String? {
        defaults.string(forKey: nameKey(direction))
    }

    private func setTarget(_ direction: Direction, uid: String?, name: String?) {
        defaults.set(uid, forKey: uidKey(direction))
        defaults.set(name, forKey: nameKey(direction))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateIcon()

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil
        )
        AudioDevices.observeChanges { [weak self] in
            MainActor.assumeIsolated { self?.updateIcon() }
        }

        log.info("Launched")
        applyWithRetry()
    }

    @objc private func didWake() {
        log.info("Woke from sleep")
        applyWithRetry()
    }

    // MARK: - Switching

    private func applyWithRetry() {
        retryTimer?.invalidate()
        attempts = 0
        pending = Direction.allCases.filter { targetUID($0) != nil }
        if applyPending() { return }
        retryTimer = Timer.scheduledTimer(withTimeInterval: Self.retryInterval, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { return timer.invalidate() }
                if self.applyPending() {
                    timer.invalidate()
                }
            }
        }
    }

    /// Applies each pending target that is connected. Returns true when nothing is left to retry.
    private func applyPending() -> Bool {
        attempts += 1
        pending = pending.filter { !apply($0) }
        guard !pending.isEmpty else { return true }
        guard attempts >= Self.maxAttempts else { return false }
        for direction in pending {
            let target = targetName(direction) ?? targetUID(direction) ?? "none"
            log.info("\(direction.label, privacy: .public) target \(target, privacy: .public) not connected, doing nothing")
        }
        pending = []
        return true
    }

    /// Returns true if the target device was found (whether or not every step succeeded).
    private func apply(_ direction: Direction) -> Bool {
        guard let uid = targetUID(direction) else { return true }
        guard let device = AudioDevices.devices(direction).first(where: { $0.uid == uid }) else { return false }

        if AudioDevices.defaultDeviceID(direction) != device.id, !AudioDevices.setDefault(device.id, direction) {
            log.error("Failed to set default \(direction.label, privacy: .public) to \(device.name, privacy: .public)")
        }
        guard let volume = direction == .output ? targetVolume : Self.inputVolume else {
            log.info("\(direction.label, privacy: .public) switched to \(device.name, privacy: .public), volume unchanged")
            return true
        }
        if !AudioDevices.setVolume(device.id, direction, Float32(volume) / 100) {
            log.error("\(device.name, privacy: .public) has no settable \(direction.label, privacy: .public) volume")
        }
        AudioDevices.unmute(device.id, direction)
        log.info("\(direction.label, privacy: .public) switched to \(device.name, privacy: .public) at \(volume)%")
        return true
    }

    // MARK: - Icon

    /// Normal speaker when every configured target is the current device, warning badge otherwise.
    private func updateIcon() {
        var onTarget = true
        var lines: [String] = []
        for direction in Direction.allCases {
            let currentID = AudioDevices.defaultDeviceID(direction)
            let current = AudioDevices.devices(direction).first { $0.id == currentID }
            if let uid = targetUID(direction), current?.uid != uid {
                onTarget = false
            }
            lines.append("\(direction.label): \(current?.name ?? "unknown")")
        }
        let symbol = onTarget ? "speaker.wave.3" : "speaker.badge.exclamationmark"
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "AudioAutoSwitch")
        statusItem.button?.toolTip = lines.joined(separator: "\n")
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        var anyConnected = false
        for direction in Direction.allCases {
            if addTargetItems(to: menu, direction) {
                anyConnected = true
            }
            if direction == .output {
                addVolumeItem(to: menu)
            }
            menu.addItem(.separator())
        }

        let applyItem = NSMenuItem(title: "Apply Now", action: #selector(applyNow), keyEquivalent: "")
        applyItem.target = self
        applyItem.isEnabled = anyConnected
        menu.addItem(applyItem)

        menu.addItem(.separator())

        let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(loginItem)

        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    /// Adds the target status line and device picker for one direction. Returns true if its target is connected.
    private func addTargetItems(to menu: NSMenu, _ direction: Direction) -> Bool {
        let devices = AudioDevices.devices(direction)
        let uid = targetUID(direction)
        let connected = devices.contains { $0.uid == uid }
        let title = if let name = targetName(direction) {
            "Target \(direction.label): \(name)" + (connected ? "" : " (not connected)")
        } else {
            "Target \(direction.label): none"
        }
        menu.addItem(NSMenuItem(title: title, action: nil, keyEquivalent: ""))

        let deviceMenu = NSMenu()
        for device in devices {
            let item = NSMenuItem(title: device.name, action: #selector(selectTarget(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = Choice(direction: direction, uid: device.uid)
            item.state = device.uid == uid ? .on : .off
            deviceMenu.addItem(item)
        }
        if uid != nil {
            deviceMenu.addItem(.separator())
            let clear = NSMenuItem(title: "None", action: #selector(selectTarget(_:)), keyEquivalent: "")
            clear.target = self
            clear.representedObject = Choice(direction: direction, uid: nil)
            deviceMenu.addItem(clear)
        }
        let deviceItem = NSMenuItem(title: "Target \(direction.label) Device", action: nil, keyEquivalent: "")
        deviceItem.submenu = deviceMenu
        menu.addItem(deviceItem)
        return connected
    }

    private func addVolumeItem(to menu: NSMenu) {
        let volumeMenu = NSMenu()
        let unchanged = NSMenuItem(title: "Don't Change", action: #selector(selectVolume(_:)), keyEquivalent: "")
        unchanged.target = self
        unchanged.tag = 0
        unchanged.state = targetVolume == nil ? .on : .off
        volumeMenu.addItem(unchanged)
        volumeMenu.addItem(.separator())
        for percent in Self.volumeChoices {
            let item = NSMenuItem(title: "\(percent)%", action: #selector(selectVolume(_:)), keyEquivalent: "")
            item.target = self
            item.tag = percent
            item.state = percent == targetVolume ? .on : .off
            volumeMenu.addItem(item)
        }
        let volumeItem = NSMenuItem(title: "Target Output Volume: \(targetVolumeLabel)", action: nil, keyEquivalent: "")
        volumeItem.submenu = volumeMenu
        menu.addItem(volumeItem)
    }

    @objc private func selectTarget(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? Choice else { return }
        setTarget(choice.direction, uid: choice.uid, name: choice.uid == nil ? nil : sender.title)
        updateIcon()
        applyWithRetry()
    }

    @objc private func selectVolume(_ sender: NSMenuItem) {
        targetVolume = sender.tag == 0 ? nil : sender.tag
        applyWithRetry()
    }

    @objc private func applyNow() {
        applyWithRetry()
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not change Launch at Login"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }
}
