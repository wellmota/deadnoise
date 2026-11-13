import CoreAudio
import Darwin
import Foundation

struct CoreAudioError: LocalizedError {
    let status: OSStatus
    let context: String
    var errorDescription: String? { "\(context) (OSStatus \(status))" }
}

@inline(__always)
func check(_ status: OSStatus, _ context: @autoclosure () -> String) throws {
    guard status == noErr else { throw CoreAudioError(status: status, context: context()) }
}

/// Wrappers finos sobre a API de propriedades do Core Audio.
enum CA {
    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func read<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, as initial: T) throws -> T {
        var addr = address(selector, scope: scope)
        var size = UInt32(MemoryLayout<T>.size)
        var value = initial
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &addr, 0, nil, &size, UnsafeMutableRawPointer($0))
        }
        try check(status, "read \(selector)")
        return value
    }

    static func readString(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr,
              let str = value?.takeRetainedValue() else { return nil }
        let s = str as String
        return s.isEmpty ? nil : s
    }

    static func readObjectList(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                               scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
        var addr = address(selector, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var list = [AudioObjectID](repeating: kAudioObjectUnknown, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &list) == noErr else { return [] }
        return list
    }

    // MARK: Dispositivo de saída

    static func defaultOutputDevice() throws -> AudioDeviceID {
        try read(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice,
                 as: AudioDeviceID(kAudioObjectUnknown))
    }

    static func deviceUID(_ device: AudioDeviceID) -> String? {
        readString(device, kAudioDevicePropertyDeviceUID)
    }

    static func deviceName(_ device: AudioDeviceID) -> String? {
        readString(device, kAudioObjectPropertyName)
    }

    static func defaultInputDevice() throws -> AudioDeviceID {
        try read(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice,
                 as: AudioDeviceID(kAudioObjectUnknown))
    }

    struct Device: Identifiable, Hashable {
        let id: AudioDeviceID
        let name: String
    }

    /// Dispositivos que têm streams no escopo pedido (entrada ou saída).
    static func devices(scope: AudioObjectPropertyScope) -> [Device] {
        readObjectList(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices).compactMap { dev in
            var addr = address(kAudioDevicePropertyStreams, scope: scope)
            var size: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(dev, &addr, 0, nil, &size) == noErr, size > 0,
                  let name = deviceName(dev) else { return nil }
            return Device(id: dev, name: name)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func setDefault(_ selector: AudioObjectPropertySelector, to device: AudioDeviceID) throws {
        var addr = address(selector)
        var dev = device
        try check(AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil,
                                             UInt32(MemoryLayout<AudioDeviceID>.size), &dev),
                  String(localized: "Não foi possível trocar o dispositivo"))
    }

    // MARK: Mudo do microfone

    /// Estado de mudo do dispositivo de entrada; nil se o dispositivo não expõe esse controle.
    static func inputMuted(_ device: AudioDeviceID) -> Bool? {
        (try? read(device, kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeInput, as: UInt32(0))).map { $0 != 0 }
    }

    static func setInputMuted(_ muted: Bool, device: AudioDeviceID) throws {
        var addr = address(kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeInput)
        var value: UInt32 = muted ? 1 : 0
        try check(AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value),
                  String(localized: "Este microfone não permite silenciar pelo sistema"))
    }

    static func isRunningSomewhere(_ device: AudioDeviceID) -> Bool {
        ((try? read(device, kAudioDevicePropertyDeviceIsRunningSomewhere, as: UInt32(0))) ?? 0) != 0
    }

    /// Encontra um dispositivo pelo UID, inclusive os ocultos (que não aparecem na lista de dispositivos).
    static func device(forUID uid: String) -> AudioDeviceID? {
        var addr = address(kAudioHardwarePropertyTranslateUIDToDevice)
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var qualifier = uid as CFString
        let status = withUnsafePointer(to: &qualifier) {
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                       UInt32(MemoryLayout<CFString>.size), $0, &size, &device)
        }
        return status == noErr && device != kAudioObjectUnknown ? device : nil
    }

    // MARK: Processos de áudio

    struct AudioProcess {
        let objectID: AudioObjectID
        let pid: pid_t
        let bundleID: String?
        let isRunningOutput: Bool
        /// O processo está capturando áudio (microfone em uso): sinal de chamada em andamento.
        let isRunningInput: Bool
    }

    static func audioProcesses() -> [AudioProcess] {
        readObjectList(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList).compactMap { obj in
            guard let pid = try? read(obj, kAudioProcessPropertyPID, as: pid_t(-1)), pid > 0 else { return nil }
            let running = (try? read(obj, kAudioProcessPropertyIsRunningOutput, as: UInt32(0))) ?? 0
            let capturing = (try? read(obj, kAudioProcessPropertyIsRunningInput, as: UInt32(0))) ?? 0
            return AudioProcess(objectID: obj,
                                pid: pid,
                                bundleID: readString(obj, kAudioProcessPropertyBundleID),
                                isRunningOutput: running != 0,
                                isRunningInput: capturing != 0)
        }
    }

    static func parentPID(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let ppid = info.kp_eproc.e_ppid
        return ppid > 1 ? ppid : nil
    }
}
