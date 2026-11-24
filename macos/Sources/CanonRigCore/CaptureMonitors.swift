import AppKit
import AVFoundation
import CoreAudio
import CoreMediaIO
import Foundation

public struct CaptureSnapshot: Equatable, Sendable {
    public let microphoneApps: [String]
    public let activeCameras: [String]
    public let runningMeetingApps: [String]

    public init(microphoneApps: [String], activeCameras: [String],
                runningMeetingApps: [String]) {
        self.microphoneApps = microphoneApps
        self.activeCameras = activeCameras
        self.runningMeetingApps = runningMeetingApps
    }

    public var camLinkActive: Bool {
        activeCameras.contains { $0.localizedCaseInsensitiveContains("Cam Link") }
    }

    public var rawCallActive: Bool {
        !activeCameras.isEmpty
    }
}

private struct MicProcess {
    let pid: pid_t
    let bundleID: String?
}

private final class AudioProcessMonitor {
    func processesUsingMic() -> [MicProcess] {
        let systemID = AudioObjectID(kAudioObjectSystemObject)
        var address = propertyAddress(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(systemID, &address, 0, nil, &size) == noErr,
              size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0,
            count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(systemID, &address, 0, nil, &size, &objects) == noErr
        else { return [] }
        return objects.compactMap { object in
            guard object != kAudioObjectUnknown,
                  (readUInt32(object, kAudioProcessPropertyIsRunningInput) ?? 0) != 0,
                  let pid = readPID(object), pid > 0 else { return nil }
            return MicProcess(pid: pid, bundleID: readString(object, kAudioProcessPropertyBundleID))
        }
    }

    private func propertyAddress(_ selector: AudioObjectPropertySelector)
    -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
    }

    private func readUInt32(_ object: AudioObjectID,
                            _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = propertyAddress(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr
            ? value : nil
    }

    private func readPID(_ object: AudioObjectID) -> pid_t? {
        var address = propertyAddress(kAudioProcessPropertyPID)
        var value: pid_t = -1
        var size = UInt32(MemoryLayout<pid_t>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr
            ? value : nil
    }

    private func readString(_ object: AudioObjectID,
                            _ selector: AudioObjectPropertySelector) -> String? {
        var address = propertyAddress(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr
        else { return nil }
        return value?.takeRetainedValue() as String?
    }
}

private final class CameraMonitor {
    func camerasInUse() -> [String] {
        let system = CMIOObjectID(kCMIOObjectSystemObject)
        var address = propertyAddress(kCMIOHardwarePropertyDevices)
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(system, &address, 0, nil, &size) == 0,
              size > 0 else { return [] }
        var devices = [CMIOObjectID](repeating: 0,
            count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(system, &address, 0, nil, size, &used, &devices) == 0
        else { return [] }
        return devices.filter(isRunning).compactMap { device -> String? in
            guard let uid = stringProperty(device, kCMIODevicePropertyDeviceUID),
                  let camera = AVCaptureDevice(uniqueID: uid), camera.hasMediaType(.video) else { return nil }
            return camera.localizedName
        }.sorted()
    }

    private func propertyAddress(_ selector: Int) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(selector),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    }

    private func isRunning(_ device: CMIOObjectID) -> Bool {
        var address = propertyAddress(kCMIODevicePropertyDeviceIsRunningSomewhere)
        var value: UInt32 = 0
        var used: UInt32 = 0
        let size = UInt32(MemoryLayout<UInt32>.size)
        return CMIOObjectGetPropertyData(device, &address, 0, nil, size, &used, &value) == 0
            && value != 0
    }

    private func stringProperty(_ device: CMIOObjectID, _ selector: Int) -> String? {
        var address = propertyAddress(selector)
        var value: Unmanaged<CFString>?
        var used: UInt32 = 0
        let size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard CMIOObjectGetPropertyData(device, &address, 0, nil, size, &used, &value) == 0
        else { return nil }
        return value?.takeRetainedValue() as String?
    }
}

@MainActor
public final class CallDetector {
    private let audio = AudioProcessMonitor()
    private let camera = CameraMonitor()

    public static let meetingBundlePrefixes = [
        "us.zoom.xos", "com.microsoft.teams", "com.tinyspeck.slackmacgap",
        "com.hnc.Discord", "com.apple.FaceTime", "com.google.Chrome",
        "com.apple.Safari", "com.microsoft.edgemac", "company.thebrowser.Browser",
        "org.mozilla.firefox", "com.operasoftware.Opera",
    ]

    public init() {}

    public func sample() -> CaptureSnapshot {
        let running = NSWorkspace.shared.runningApplications
        let meetingApps = running.filter { app in
            guard let bundle = app.bundleIdentifier else { return false }
            return Self.meetingBundlePrefixes.contains { bundle.hasPrefix($0) }
        }
        let recordingApps = audio.processesUsingMic().compactMap { process -> String? in
            let direct = NSRunningApplication(processIdentifier: process.pid)
            let bundle = process.bundleID ?? direct?.bundleIdentifier
            let host = meetingApps.first { app in
                guard let appBundle = app.bundleIdentifier, let bundle else { return false }
                return bundle == appBundle || bundle.hasPrefix(appBundle + ".") ||
                    (bundle.hasPrefix("com.apple.WebKit.") && appBundle == "com.apple.Safari")
            }
            guard let app = host ?? direct,
                  let appBundle = app.bundleIdentifier,
                  Self.meetingBundlePrefixes.contains(where: { appBundle.hasPrefix($0) })
            else { return nil }
            return app.localizedName ?? appBundle
        }
        return CaptureSnapshot(
            microphoneApps: Array(Set(recordingApps)).sorted(),
            activeCameras: camera.camerasInUse(),
            runningMeetingApps: meetingApps.compactMap { $0.localizedName }.sorted())
    }
}
