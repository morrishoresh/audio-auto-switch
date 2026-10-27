import CoreAudio

struct AudioDevice {
    let id: AudioDeviceID
    let uid: String
    let name: String
}

enum Direction: CaseIterable {
    case output
    case input

    var label: String {
        switch self {
        case .output: "Output"
        case .input: "Input"
        }
    }

    fileprivate var scope: AudioObjectPropertyScope {
        switch self {
        case .output: kAudioDevicePropertyScopeOutput
        case .input: kAudioDevicePropertyScopeInput
        }
    }

    fileprivate var defaultDeviceSelector: AudioObjectPropertySelector {
        switch self {
        case .output: kAudioHardwarePropertyDefaultOutputDevice
        case .input: kAudioHardwarePropertyDefaultInputDevice
        }
    }
}

enum AudioDevices {
    private static let system = AudioObjectID(kAudioObjectSystemObject)

    static func devices(_ direction: Direction) -> [AudioDevice] {
        var address = globalAddress(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }

        return ids.filter { channelCount($0, direction) > 0 }.compactMap { id in
            guard let uid = stringProperty(id, kAudioDevicePropertyDeviceUID),
                  let name = stringProperty(id, kAudioObjectPropertyName) else { return nil }
            return AudioDevice(id: id, uid: uid, name: name)
        }
    }

    static func defaultDeviceID(_ direction: Direction) -> AudioDeviceID? {
        var address = globalAddress(direction.defaultDeviceSelector)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &id) == noErr else { return nil }
        return id
    }

    /// Calls `handler` on the main queue whenever the default output or input device changes, or devices are added or removed.
    static func observeChanges(_ handler: @escaping @Sendable () -> Void) {
        let selectors = Direction.allCases.map(\.defaultDeviceSelector) + [kAudioHardwarePropertyDevices]
        for selector in selectors {
            var address = globalAddress(selector)
            AudioObjectAddPropertyListenerBlock(system, &address, .main) { _, _ in handler() }
        }
    }

    static func setDefault(_ id: AudioDeviceID, _ direction: Direction) -> Bool {
        var address = globalAddress(direction.defaultDeviceSelector)
        var deviceID = id
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        return AudioObjectSetPropertyData(system, &address, 0, nil, size, &deviceID) == noErr
    }

    /// Sets volume on the main element, or on each channel if the device has no main volume control.
    /// Returns false if the device exposes no settable volume (e.g. most HDMI/DisplayPort outputs).
    static func setVolume(_ id: AudioDeviceID, _ direction: Direction, _ volume: Float32) -> Bool {
        if setProperty(id, direction, kAudioDevicePropertyVolumeScalar, element: kAudioObjectPropertyElementMain, value: volume) {
            return true
        }
        let channels = channelCount(id, direction)
        guard channels > 0 else { return false }
        var any = false
        for channel in 1...channels {
            if setProperty(id, direction, kAudioDevicePropertyVolumeScalar, element: UInt32(channel), value: volume) {
                any = true
            }
        }
        return any
    }

    static func unmute(_ id: AudioDeviceID, _ direction: Direction) {
        _ = setProperty(id, direction, kAudioDevicePropertyMute, element: kAudioObjectPropertyElementMain, value: UInt32(0))
    }

    // MARK: - Helpers

    private static func globalAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static func channelCount(_ id: AudioDeviceID, _ direction: Direction) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: direction.scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let buffers = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func stringProperty(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = globalAddress(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private static func setProperty<T: BitwiseCopyable>(
        _ id: AudioDeviceID,
        _ direction: Direction,
        _ selector: AudioObjectPropertySelector,
        element: AudioObjectPropertyElement,
        value: T
    ) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: direction.scope,
            mElement: element
        )
        guard AudioObjectHasProperty(id, &address) else { return false }
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(id, &address, &settable) == noErr, settable.boolValue else { return false }
        var data = value
        return AudioObjectSetPropertyData(id, &address, 0, nil, UInt32(MemoryLayout<T>.size), &data) == noErr
    }
}
