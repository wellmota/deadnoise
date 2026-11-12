import AppKit
import CoreAudio
import Foundation
import ServiceManagement

@MainActor
final class MixerModel: ObservableObject {
    struct AppEntry: Identifiable, Equatable {
        let id: String            // bundle ID do app "dono" (ou pid:N)
        let name: String
        let icon: NSImage?
        let processObjectIDs: [AudioObjectID]
        let isPlaying: Bool

        static func == (a: AppEntry, b: AppEntry) -> Bool {
            a.id == b.id && a.name == b.name && a.processObjectIDs == b.processObjectIDs && a.isPlaying == b.isPlaying
        }
    }

    @Published private(set) var apps: [AppEntry] = []
    @Published private(set) var gains: [String: Float] = [:]
    @Published private(set) var muted: Set<String> = []
    @Published private(set) var outputName = ""
    @Published private(set) var outputDevices: [CA.Device] = []
    @Published private(set) var inputDevices: [CA.Device] = []
    @Published private(set) var currentOutputID = AudioDeviceID(kAudioObjectUnknown)
    @Published private(set) var currentInputID = AudioDeviceID(kAudioObjectUnknown)
    /// Fones Bluetooth pareados que não estão no Core Audio (ex.: AirPods ligados ao iPhone).
    @Published private(set) var bluetoothHeadsets: [BluetoothAudio.Headset] = []
    @Published private(set) var connectingAddress: String?
    @Published var lastError: String?
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled

    /// Chamada, mudo do microfone e gravação/transcrição.
    let meeting = MeetingController()

    private var taps: [String: ProcessTap] = [:]
    private var pendingTeardown: [String: Task<Void, Never>] = [:]
    private var outputUID: String?
    private var timer: Timer?
    private let defaults = UserDefaults.standard
    private let ownPID = ProcessInfo.processInfo.processIdentifier

    init() {
        if let stored = defaults.dictionary(forKey: "gains") as? [String: Double] {
            gains = stored.mapValues { Float($0) }
        }
        muted = Set(defaults.stringArray(forKey: "muted") ?? [])

        meeting.requestDeviceRefresh = { [weak self] in
            self?.refreshDevices()
            self?.refresh()
        }
        updateOutputDevice()
        refreshDevices()
        refresh()
        installListeners()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    // MARK: API para a UI

    func gain(for id: String) -> Float { gains[id] ?? 1 }
    func isMuted(_ id: String) -> Bool { muted.contains(id) }

    func setGain(_ value: Float, for id: String) {
        var g = (value * 100).rounded() / 100
        if abs(g - 1) < 0.03 { g = 1 } // "imã" em 100%
        if g == 1 { gains.removeValue(forKey: id) } else { gains[id] = g }
        persist()
        sync(id)
    }

    func toggleMute(_ id: String) {
        if muted.contains(id) { muted.remove(id) } else { muted.insert(id) }
        persist()
        sync(id)
    }

    func resetAll() {
        gains.removeAll()
        muted.removeAll()
        persist()
        for id in Array(taps.keys) { destroyTap(id) }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            lastError = "Abrir ao iniciar sessão: \(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: Descoberta de apps

    func refresh() {
        let running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        var groups: [String: (app: NSRunningApplication?, objects: [AudioObjectID], playing: Bool, capturing: Bool, fallbackName: String)] = [:]

        let processes = CA.audioProcesses()
        for proc in processes where proc.pid != ownPID {
            let owner = ownerApp(for: proc, running: running)
            let key = owner?.bundleIdentifier ?? proc.bundleID ?? "pid:\(proc.pid)"
            var g = groups[key] ?? (owner, [], false, false, proc.bundleID ?? "PID \(proc.pid)")
            g.objects.append(proc.objectID)
            g.playing = g.playing || proc.isRunningOutput
            g.capturing = g.capturing || proc.isRunningInput
            groups[key] = g
        }

        // Chamada em andamento = algum app de usuário com o microfone aberto.
        meeting.ownProcessObject = processes.first { $0.pid == ownPID }?.objectID
        meeting.updateCall(apps: groups.values.compactMap { $0.capturing ? $0.app?.localizedName : nil }.sorted())
        meeting.refreshMic(device: currentInputID)

        let entries = groups.compactMap { key, g -> AppEntry? in
            let adjusted = gains[key] != nil || muted.contains(key)
            guard g.playing || adjusted else { return nil }
            return AppEntry(id: key,
                            name: g.app?.localizedName ?? g.fallbackName,
                            icon: g.app?.icon,
                            processObjectIDs: g.objects.sorted(),
                            isPlaying: g.playing)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        if entries != apps { apps = entries }

        // Aplica ganhos salvos a apps que apareceram e remove taps de apps que sumiram.
        let present = Set(entries.map(\.id))
        for id in taps.keys where !present.contains(id) { destroyTap(id) }
        for entry in entries { sync(entry.id) }
    }

    /// Helpers (ex.: "Google Chrome Helper", serviços XPC do Teams) são agrupados no app principal.
    private func ownerApp(for proc: CA.AudioProcess, running: [NSRunningApplication]) -> NSRunningApplication? {
        var pid: pid_t? = proc.pid
        for _ in 0..<6 {
            guard let p = pid else { break }
            if let app = running.first(where: { $0.processIdentifier == p }) { return app }
            pid = CA.parentPID(of: p)
        }
        if let bid = proc.bundleID {
            return running
                .filter { app in app.bundleIdentifier.map { bid.hasPrefix($0) } ?? false }
                .max { ($0.bundleIdentifier?.count ?? 0) < ($1.bundleIdentifier?.count ?? 0) }
        }
        return nil
    }

    // MARK: Taps

    private func effectiveGain(_ id: String) -> Float { muted.contains(id) ? 0 : (gains[id] ?? 1) }

    private func sync(_ id: String) {
        guard let entry = apps.first(where: { $0.id == id }) else { return }
        let g = effectiveGain(id)

        if g == 1 {
            // Desfaz o tap com atraso para não recriar a cada passagem do slider por 100%.
            guard taps[id] != nil, pendingTeardown[id] == nil else { return }
            pendingTeardown[id] = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(1.5))
                guard let self, !Task.isCancelled else { return }
                self.pendingTeardown[id] = nil
                if self.effectiveGain(id) == 1 { self.destroyTap(id) }
            }
            taps[id]?.gain = 1
            return
        }

        pendingTeardown.removeValue(forKey: id)?.cancel()

        if let tap = taps[id], tap.processObjectIDs == Set(entry.processObjectIDs), tap.outputUID == outputUID {
            tap.gain = g
            return
        }

        taps.removeValue(forKey: id)?.invalidate()
        guard let outputUID else { lastError = "Nenhum dispositivo de saída encontrado."; return }
        do {
            taps[id] = try ProcessTap(processObjectIDs: entry.processObjectIDs, outputUID: outputUID, name: entry.name, gain: g)
            lastError = nil
        } catch {
            lastError = "\(error.localizedDescription). Verifique Ajustes > Privacidade e Segurança > Gravação de Tela e Áudio do Sistema."
        }
    }

    private func destroyTap(_ id: String) {
        pendingTeardown.removeValue(forKey: id)?.cancel()
        taps.removeValue(forKey: id)?.invalidate()
    }

    // MARK: Dispositivos

    func selectOutput(_ id: AudioDeviceID) {
        do {
            try CA.setDefault(kAudioHardwarePropertyDefaultOutputDevice, to: id)
            // Sons do sistema (alertas) acompanham a saída escolhida.
            try? CA.setDefault(kAudioHardwarePropertyDefaultSystemOutputDevice, to: id)
        } catch { lastError = error.localizedDescription }
    }

    func selectInput(_ id: AudioDeviceID) {
        do { try CA.setDefault(kAudioHardwarePropertyDefaultInputDevice, to: id) }
        catch { lastError = error.localizedDescription }
    }

    func refreshDevices() {
        outputDevices = CA.devices(scope: kAudioObjectPropertyScopeOutput)
        inputDevices = CA.devices(scope: kAudioObjectPropertyScopeInput)
        currentInputID = (try? CA.defaultInputDevice()) ?? AudioDeviceID(kAudioObjectUnknown)
        let virtualMic = inputDevices.first { CA.deviceUID($0.id) == MicDenoiser.micUID }?.id
        watchVirtualMic(virtualMic)
        meeting.virtualMic = virtualMic
        meeting.refreshMic(device: currentInputID)
        let present = Set(outputDevices.compactMap { CA.deviceUID($0.id).flatMap(BluetoothAudio.address(fromUID:)) })
        bluetoothHeadsets = BluetoothAudio.pairedHeadsets(excluding: present)
    }

    /// Conecta um fone Bluetooth pareado e, quando ele aparecer no Core Audio, vira a saída padrão.
    func connectBluetooth(_ headset: BluetoothAudio.Headset) {
        guard connectingAddress == nil else { return }
        connectingAddress = headset.address
        lastError = nil
        Task { @MainActor in
            defer { connectingAddress = nil; refreshDevices() }
            // 1ª tentativa: só abre a conexão. 2ª: se já havia link sem áudio, reconecta.
            for reconnect in [false, true] {
                let address = headset.address
                _ = await Task.detached { BluetoothAudio.connect(address: address, reconnect: reconnect) }.value
                if let device = await waitForOutputDevice(address: address, timeout: 8) {
                    selectOutput(device)
                    return
                }
            }
            lastError = "Não foi possível conectar \(headset.name)."
        }
    }

    private func waitForOutputDevice(address: String, timeout: TimeInterval) async -> AudioDeviceID? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let match = CA.devices(scope: kAudioObjectPropertyScopeOutput).first {
                CA.deviceUID($0.id).flatMap(BluetoothAudio.address(fromUID:)) == address
            }
            if let match { return match.id }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return nil
    }

    private func updateOutputDevice() {
        guard let device = try? CA.defaultOutputDevice(), device != kAudioObjectUnknown else {
            outputUID = nil; outputName = ""; currentOutputID = AudioDeviceID(kAudioObjectUnknown)
            meeting.outputChanged(uid: nil)
            return
        }
        currentOutputID = device
        outputUID = CA.deviceUID(device)
        outputName = CA.deviceName(device) ?? ""
        meeting.outputChanged(uid: outputUID)
    }

    /// Avisa na hora em que algum app abre ou fecha o microfone virtual, sem esperar o timer de 2 s.
    private var watchedVirtualMic: AudioDeviceID?
    private func watchVirtualMic(_ device: AudioDeviceID?) {
        guard let device, device != watchedVirtualMic else { return }
        watchedVirtualMic = device
        var addr = CA.address(kAudioDevicePropertyDeviceIsRunningSomewhere)
        AudioObjectAddPropertyListenerBlock(device, &addr, .main) { [weak self] _, _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    private func installListeners() {
        let system = AudioObjectID(kAudioObjectSystemObject)

        var outAddr = CA.address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectAddPropertyListenerBlock(system, &outAddr, .main) { [weak self] _, _ in
            Task { @MainActor in
                guard let self else { return }
                // Trocou fone/alto-falante: recria todos os taps no novo dispositivo.
                self.updateOutputDevice()
                self.refreshDevices()
                for id in Array(self.taps.keys) { self.taps.removeValue(forKey: id)?.invalidate() }
                self.refresh()
            }
        }

        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice] {
            var addr = CA.address(selector)
            AudioObjectAddPropertyListenerBlock(system, &addr, .main) { [weak self] _, _ in
                Task { @MainActor in self?.refreshDevices() }
            }
        }

        var procAddr = CA.address(kAudioHardwarePropertyProcessObjectList)
        AudioObjectAddPropertyListenerBlock(system, &procAddr, .main) { [weak self] _, _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    private func persist() {
        defaults.set(gains.mapValues { Double($0) }, forKey: "gains")
        defaults.set(Array(muted), forKey: "muted")
    }
}
