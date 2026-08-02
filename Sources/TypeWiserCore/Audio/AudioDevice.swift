import CoreAudio
import Foundation

/// The microphone macOS will hand `AVAudioEngine`, identified well enough to
/// name it in an error message.
public struct InputDevice: Sendable, Equatable {
    public let name: String
    /// Bluetooth mics (AirPods and friends) are the single most common cause of
    /// audio that has healthy amplitude but cannot be transcribed: opening the
    /// mic drops the headset into a low-quality bidirectional mode. Worth
    /// calling out by name when recognition finds no speech.
    public let isBluetooth: Bool

    public init(name: String, isBluetooth: Bool) {
        self.name = name
        self.isBluetooth = isBluetooth
    }
}

public enum AudioDevice {
    /// Reads the system default input device. Returns nil if CoreAudio has no
    /// default input (no mic attached) or any query fails — callers degrade to
    /// a generic message rather than guessing.
    public static func currentInput() -> InputDevice? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)

        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &size, &deviceID) == noErr,
              deviceID != AudioDeviceID(kAudioObjectUnknown)
        else { return nil }

        return InputDevice(name: name(of: deviceID) ?? "Unknown microphone",
                           isBluetooth: isBluetooth(deviceID))
    }

    private static func name(of deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr
        else { return nil }
        let s = value as String
        return s.isEmpty ? nil : s
    }

    private static func isBluetooth(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var transport = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &transport) == noErr
        else { return false }
        return transport == kAudioDeviceTransportTypeBluetooth
            || transport == kAudioDeviceTransportTypeBluetoothLE
    }
}
