import AudioToolbox
import CoreAudio
import Foundation

protocol VolumeControlling: AnyObject {
    func currentOutput() throws -> AudioDeviceID
    func readVolume(for device: AudioDeviceID) throws -> Float
    func setVolume(_ value: Float, for device: AudioDeviceID) throws
}

enum AudioControllerError: LocalizedError {
    case noOutput
    case unavailable
    case changedOutput
    case operationFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .noOutput, .unavailable:
            "The current output device does not expose an adjustable main volume."
        case .changedOutput:
            "The output device changed. Start a new gesture."
        case .operationFailed:
            "The output volume could not be updated."
        }
    }
}

final class AudioController: VolumeControlling, @unchecked Sendable {
    func currentOutput() throws -> AudioDeviceID {
        var device: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device
        )
        guard status == noErr else { throw AudioControllerError.operationFailed(status) }
        guard device != 0 else { throw AudioControllerError.noOutput }
        return device
    }

    func readVolume(for device: AudioDeviceID) throws -> Float {
        var address = volumeAddress
        guard AudioObjectHasProperty(device, &address) else { throw AudioControllerError.unavailable }
        var value: Float = 0
        var size = UInt32(MemoryLayout<Float>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
        guard status == noErr, value.isFinite, (0...1).contains(value) else {
            throw AudioControllerError.unavailable
        }
        return value
    }

    func isVolumeSettable(for device: AudioDeviceID) -> Bool {
        var address = volumeAddress
        guard AudioObjectHasProperty(device, &address) else { return false }
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(device, &address, &settable) == noErr && settable.boolValue
    }

    func setVolume(_ value: Float, for device: AudioDeviceID) throws {
        guard value.isFinite else { throw AudioControllerError.unavailable }
        var address = volumeAddress
        guard isVolumeSettable(for: device) else { throw AudioControllerError.unavailable }
        var bounded = min(max(value, 0), 1)
        let status = AudioObjectSetPropertyData(
            device, &address, 0, nil, UInt32(MemoryLayout<Float>.size), &bounded
        )
        guard status == noErr else { throw AudioControllerError.operationFailed(status) }
    }

    func adjust(delta: Float, expectedDevice: AudioDeviceID) throws -> Float {
        guard delta.isFinite else { throw AudioControllerError.unavailable }
        guard try currentOutput() == expectedDevice else { throw AudioControllerError.changedOutput }
        let before = try readVolume(for: expectedDevice)
        guard try currentOutput() == expectedDevice else { throw AudioControllerError.changedOutput }
        try setVolume(before + delta, for: expectedDevice)
        return try readVolume(for: expectedDevice)
    }

    private var volumeAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
    }
}
