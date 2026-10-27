import CoreAudio

struct AudioDevice {
    let id: AudioDeviceID
    let uid: String
    let name: String
}

enum AudioDevices {
    private static let system = AudioObjectID(kAudioObjectSystemObject)

    static func outputDevices() -> [AudioDevice] {
        var address = globalAddress(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }

        return ids.filter { outputChannelCount($0) > 0 }.compactMap { id in
            guard let uid = stringProperty(id, kAudioDevicePropertyDeviceUID),
                  let name = stringProperty(id, kAudioObjectPropertyName) else { return nil }
            return AudioDevice(id: id, uid: uid, name: name)
        }
    }

    static func defaultOutputDeviceID() -> AudioDeviceID? {
        var address = globalAddress(kAudioHardwarePropertyDefaultOutputDevice)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &id) == noErr else { return nil }
        return id
    }

    /// Calls `handler` on the main queue whenever the default output device changes, or devices are added or removed.
    static func observeOutputChanges(_ handler: @escaping @Sendable () -> Void) {
        for selector in [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDevices] {
            var address = globalAddress(selector)
            AudioObjectAddPropertyListenerBlock(system, &address, .main) { _, _ in handler() }
        }
    }

    static func setDefaultOutput(_ id: AudioDeviceID) -> Bool {
        var address = globalAddress(kAudioHardwarePropertyDefaultOutputDevice)
        var deviceID = id
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        return AudioObjectSetPropertyData(system, &address, 0, nil, size, &deviceID) == noErr
    }

    /// Sets output volume on the main element, or on each channel if the device has no main volume control.
    /// Returns false if the device exposes no settable volume (e.g. most HDMI/DisplayPort outputs).
    static func setVolume(_ id: AudioDeviceID, _ volume: Float32) -> Bool {
        if setOutputProperty(id, kAudioDevicePropertyVolumeScalar, element: kAudioObjectPropertyElementMain, value: volume) {
            return true
        }
        let channels = outputChannelCount(id)
        guard channels > 0 else { return false }
        var any = false
        for channel in 1...channels {
            if setOutputProperty(id, kAudioDevicePropertyVolumeScalar, element: UInt32(channel), value: volume) {
                any = true
            }
        }
        return any
    }

    static func unmute(_ id: AudioDeviceID) {
        _ = setOutputProperty(id, kAudioDevicePropertyMute, element: kAudioObjectPropertyElementMain, value: UInt32(0))
    }

    // MARK: - Helpers

    private static func globalAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static func outputChannelCount(_ id: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
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

    private static func setOutputProperty<T: BitwiseCopyable>(
        _ id: AudioDeviceID,
        _ selector: AudioObjectPropertySelector,
        element: AudioObjectPropertyElement,
        value: T
    ) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: element
        )
        guard AudioObjectHasProperty(id, &address) else { return false }
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(id, &address, &settable) == noErr, settable.boolValue else { return false }
        var data = value
        return AudioObjectSetPropertyData(id, &address, 0, nil, UInt32(MemoryLayout<T>.size), &data) == noErr
    }
}
