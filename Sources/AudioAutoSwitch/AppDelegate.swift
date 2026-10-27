import AppKit
import ServiceManagement
import os

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private static let targetUIDKey = "targetDeviceUID"
    private static let targetNameKey = "targetDeviceName"
    private static let targetVolumeKey = "targetVolume"
    private static let volumeChoices = stride(from: 10, through: 100, by: 10).map { $0 }
    /// Bluetooth devices often reconnect a few seconds after wake/login, so keep looking for a while.
    private static let retryInterval: TimeInterval = 1
    private static let maxAttempts = 20

    private let log = Logger(subsystem: "com.morrish.AudioAutoSwitch", category: "switch")
    private let defaults = UserDefaults.standard
    private var statusItem: NSStatusItem!
    private var retryTimer: Timer?
    private var attempts = 0

    private var targetUID: String? {
        get { defaults.string(forKey: Self.targetUIDKey) }
        set { defaults.set(newValue, forKey: Self.targetUIDKey) }
    }

    private var targetName: String? {
        get { defaults.string(forKey: Self.targetNameKey) }
        set { defaults.set(newValue, forKey: Self.targetNameKey) }
    }

    /// Volume percentage (10–100) applied to the target device. Defaults to 100.
    private var targetVolume: Int {
        get { defaults.object(forKey: Self.targetVolumeKey) as? Int ?? 100 }
        set { defaults.set(newValue, forKey: Self.targetVolumeKey) }
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
        AudioDevices.observeOutputChanges { [weak self] in
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
        guard targetUID != nil else { return }
        if apply() { return }
        retryTimer = Timer.scheduledTimer(withTimeInterval: Self.retryInterval, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { return timer.invalidate() }
                if self.apply() || self.attempts >= Self.maxAttempts {
                    timer.invalidate()
                }
            }
        }
    }

    /// Returns true if the target device was found (whether or not every step succeeded).
    @discardableResult
    private func apply() -> Bool {
        attempts += 1
        guard let uid = targetUID else { return true }
        guard let device = AudioDevices.outputDevices().first(where: { $0.uid == uid }) else {
            if attempts >= Self.maxAttempts {
                log.info("Target \(self.targetName ?? uid, privacy: .public) not connected, doing nothing")
            }
            return false
        }

        if AudioDevices.defaultOutputDeviceID() != device.id, !AudioDevices.setDefaultOutput(device.id) {
            log.error("Failed to set default output to \(device.name, privacy: .public)")
        }
        let volume = targetVolume
        if !AudioDevices.setVolume(device.id, Float32(volume) / 100) {
            log.error("\(device.name, privacy: .public) has no settable volume")
        }
        AudioDevices.unmute(device.id)
        log.info("Switched to \(device.name, privacy: .public) at \(volume)%")
        return true
    }

    // MARK: - Icon

    /// Normal speaker when the target is the current output (or no target is set), warning badge otherwise.
    private func updateIcon() {
        let currentID = AudioDevices.defaultOutputDeviceID()
        let current = AudioDevices.outputDevices().first { $0.id == currentID }
        let onTarget = targetUID == nil || current?.uid == targetUID
        let symbol = onTarget ? "speaker.wave.3" : "speaker.badge.exclamationmark"
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "AudioAutoSwitch")
        statusItem.button?.toolTip = "Output: \(current?.name ?? "unknown")"
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let devices = AudioDevices.outputDevices()
        let connected = devices.contains { $0.uid == targetUID }
        let title: String
        if let name = targetName {
            title = "Target: \(name)" + (connected ? "" : " (not connected)")
        } else {
            title = "Target: none"
        }
        menu.addItem(NSMenuItem(title: title, action: nil, keyEquivalent: ""))

        let deviceMenu = NSMenu()
        for device in devices {
            let item = NSMenuItem(title: device.name, action: #selector(selectDevice(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = device.uid
            item.state = device.uid == targetUID ? .on : .off
            deviceMenu.addItem(item)
        }
        if targetUID != nil {
            deviceMenu.addItem(.separator())
            let clear = NSMenuItem(title: "None", action: #selector(clearDevice), keyEquivalent: "")
            clear.target = self
            deviceMenu.addItem(clear)
        }
        let deviceItem = NSMenuItem(title: "Target Device", action: nil, keyEquivalent: "")
        deviceItem.submenu = deviceMenu
        menu.addItem(deviceItem)

        let volumeMenu = NSMenu()
        for percent in Self.volumeChoices {
            let item = NSMenuItem(title: "\(percent)%", action: #selector(selectVolume(_:)), keyEquivalent: "")
            item.target = self
            item.tag = percent
            item.state = percent == targetVolume ? .on : .off
            volumeMenu.addItem(item)
        }
        let volumeItem = NSMenuItem(title: "Target Volume: \(targetVolume)%", action: nil, keyEquivalent: "")
        volumeItem.submenu = volumeMenu
        menu.addItem(volumeItem)

        let applyItem = NSMenuItem(title: "Apply Now", action: #selector(applyNow), keyEquivalent: "")
        applyItem.target = self
        applyItem.isEnabled = connected
        menu.addItem(applyItem)

        menu.addItem(.separator())

        let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(loginItem)

        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    @objc private func selectDevice(_ sender: NSMenuItem) {
        guard let uid = sender.representedObject as? String else { return }
        targetUID = uid
        targetName = sender.title
        updateIcon()
        applyWithRetry()
    }

    @objc private func selectVolume(_ sender: NSMenuItem) {
        targetVolume = sender.tag
        applyWithRetry()
    }

    @objc private func clearDevice() {
        retryTimer?.invalidate()
        targetUID = nil
        targetName = nil
        updateIcon()
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
