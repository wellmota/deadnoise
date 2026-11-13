import AppKit
import AVFoundation
import CoreAudio
import Foundation
import os
import UserNotifications

/// Detecção de chamada, mudo do microfone e gravação/transcrição de reuniões.
@MainActor
final class MeetingController: ObservableObject {
    enum Phase: Equatable {
        case idle
        case recording(since: Date)
        case processing
    }

    static let languages: [(id: String, name: String)] = [
        ("pt-BR", "Português (Brasil)"),
        ("en-US", "English (US)"),
        ("es-ES", "Español"),
    ]

    @Published private(set) var phase: Phase = .idle
    /// Apps usando o microfone agora (sinal de chamada em andamento).
    @Published private(set) var callApps: [String] = []
    /// nil quando o microfone atual não expõe controle de mudo.
    @Published private(set) var micMuted: Bool?
    @Published private(set) var status: String?
    @Published private(set) var lastNote: URL?
    @Published var autoRecord: Bool { didSet { defaults.set(autoRecord, forKey: "autoRecord") } }
    @Published var language: String { didSet { defaults.set(language, forKey: "language") } }

    /// "Cancelar meu ruído": microfone real -> isolamento de voz -> microfone virtual do DeadNoise.
    @Published var cleanMic: Bool {
        didSet {
            defaults.set(cleanMic, forKey: "cleanMic")
            failedRoute = nil
            syncCleanMic()
        }
    }
    @Published private(set) var cleanMicActive = false
    /// O driver do microfone virtual não está instalado (a interface oferece instalar).
    @Published private(set) var driverMissing = false
    /// O driver instalado é de uma versão anterior à que vem no app (a interface oferece atualizar).
    @Published private(set) var driverOutdated = false
    /// Definido pelo MixerModel: recarrega a lista de dispositivos de áudio.
    var requestDeviceRefresh: (() -> Void)?
    @Published private(set) var cleanMicNote: String?

    /// Mantidos pelo MixerModel.
    var outputUID: String?
    var ownProcessObject: AudioObjectID?
    /// Microfone virtual, se o driver estiver instalado.
    var virtualMic: AudioDeviceID?

    private var denoiser: MicDenoiser?
    private var denoiserRoute: [AudioDeviceID] = []
    /// Rota que falhou ao iniciar: não tenta de novo até algo mudar.
    private var failedRoute: [AudioDeviceID]?
    private var askedMicAccess = false

    private let defaults = UserDefaults.standard
    private var recorder: MeetingRecorder?
    private var recordingTitle = ""
    private var isStarting = false
    private var autoStarted = false
    private var lastCallSeen = Date.distantPast
    private var inputDevice = AudioDeviceID(kAudioObjectUnknown)

    static var notesFolder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("DeadNoise", isDirectory: true)
    }

    /// Nome do microfone virtual como o sistema mostra (o driver instalado pode ser de uma versão anterior).
    private var virtualMicName: String {
        virtualMic.flatMap(CA.deviceName) ?? MicDenoiser.micName
    }

    init() {
        // O app se chamava VolMix: leva a pasta de gravações antiga para o nome novo, uma vez.
        let oldNotes = Self.notesFolder.deletingLastPathComponent().appendingPathComponent("VolMix", isDirectory: true)
        if FileManager.default.fileExists(atPath: oldNotes.path), !FileManager.default.fileExists(atPath: Self.notesFolder.path) {
            try? FileManager.default.moveItem(at: oldNotes, to: Self.notesFolder)
        }
        autoRecord = defaults.bool(forKey: "autoRecord")
        cleanMic = defaults.bool(forKey: "cleanMic")
        let preferred = Locale.current.language.languageCode?.identifier
        let fallback = Self.languages.first { $0.id.hasPrefix(preferred ?? "pt") }?.id ?? "pt-BR"
        language = defaults.string(forKey: "language") ?? fallback
    }

    var isRecording: Bool {
        if case .recording = phase { return true }
        return false
    }

    // MARK: Chamada

    /// Chamado a cada atualização do mixer com os apps que estão capturando o microfone.
    func updateCall(apps: [String]) {
        if apps.isEmpty {
            // Só considera a chamada encerrada depois de alguns segundos sem microfone em uso.
            guard !callApps.isEmpty, Date().timeIntervalSince(lastCallSeen) > 6 else { return }
            callApps = []
            if autoStarted, isRecording { stop() }
            return
        }

        lastCallSeen = Date()
        let started = callApps.isEmpty
        if apps != callApps { callApps = apps }
        guard started, phase == .idle, !isStarting else { return }

        if autoRecord {
            autoStarted = true
            start()
        } else {
            Notifier.post(title: String(localized: "Chamada detectada"),
                          body: String(localized: "\(apps[0]) está usando o microfone. Abra o DeadNoise para gravar e transcrever."))
        }
    }

    // MARK: Microfone

    func refreshMic(device: AudioDeviceID) {
        inputDevice = device
        let muted = device == kAudioObjectUnknown ? nil : CA.inputMuted(device)
        if muted != micMuted { micMuted = muted }
        syncCleanMic()
    }

    // MARK: Cancelar meu ruído

    /// Liga/desliga o processamento conforme o estado atual. Barato: pode ser chamado a cada atualização.
    private func syncCleanMic() {
        guard cleanMic else {
            if driverMissing { driverMissing = false }
            return setCleanMic(nil, note: nil)
        }
        guard let virtualMic, let appIO = CA.device(forUID: MicDenoiser.appIOUID) else {
            if !driverMissing { driverMissing = true }
            let canInstall = DriverInstaller.bundledDriver != nil
            return setCleanMic(nil, note: canInstall
                ? String(localized: "Falta o microfone virtual. A instalação pede a senha do Mac e reinicia o áudio por alguns segundos.")
                : String(localized: "Falta o microfone virtual. Instale pelo instalador do site ou com ./Driver/build.sh install."))
        }
        if driverMissing { driverMissing = false }
        let outdated = DriverInstaller.installedIsOutdated
        if driverOutdated != outdated { driverOutdated = outdated }
        guard inputDevice != kAudioObjectUnknown, inputDevice != virtualMic else {
            return setCleanMic(nil, note: String(localized: "Em Entrada, escolha o seu microfone de verdade. O “\(virtualMicName)” é para os apps de chamada."))
        }

        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: break
        case .notDetermined:
            guard !askedMicAccess else { return }
            askedMicAccess = true
            Task { @MainActor in
                _ = await AVCaptureDevice.requestAccess(for: .audio)
                syncCleanMic()
            }
            return
        default:
            return setCleanMic(nil, note: String(localized: "Sem permissão de microfone. Libere o DeadNoise em Ajustes > Privacidade e Segurança > Microfone."))
        }

        // Só processa enquanto algum app está lendo o microfone virtual (o DeadNoise nunca lê dele),
        // para não deixar o microfone real aberto o dia todo.
        guard CA.isRunningSomewhere(virtualMic) else {
            return setCleanMic(nil, note: String(localized: "Pronto. No app da chamada, escolha o microfone “\(virtualMicName)”."))
        }

        let route = [inputDevice, appIO]
        if denoiser != nil, denoiserRoute == route { return }
        guard failedRoute != route else { return }
        denoiser?.stop()
        denoiser = nil
        do {
            let new = try MicDenoiser(inputDevice: inputDevice, outputDevice: appIO)
            new.onConfigurationChange = { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    // O formato do microfone mudou (ex.: fone conectado): monta de novo.
                    self.denoiser?.stop()
                    self.denoiser = nil
                    self.syncCleanMic()
                }
            }
            denoiserRoute = route
            setCleanMic(new, note: String(localized: "Ativo: seu ruído não chega na chamada."))
        } catch {
            failedRoute = route
            setCleanMic(nil, note: String(localized: "Não foi possível iniciar o cancelamento de ruído: \(error.localizedDescription)"))
        }
    }

    /// Instala o driver que vem dentro do app. Mostra o pedido de senha do macOS.
    func installDriver() {
        do {
            try DriverInstaller.install()
            cleanMicNote = String(localized: "Microfone virtual instalado. Aguardando o áudio reiniciar…")
            driverOutdated = DriverInstaller.installedIsOutdated
            Task { @MainActor in
                // O serviço de áudio leva alguns segundos para voltar e publicar o dispositivo novo.
                for _ in 0..<6 {
                    try? await Task.sleep(for: .seconds(2))
                    requestDeviceRefresh?()
                    if virtualMic != nil { break }
                }
                syncCleanMic()
            }
        } catch DriverInstaller.Failure.cancelled {
            // Nada a fazer: a pessoa desistiu no pedido de senha.
        } catch {
            cleanMicNote = error.localizedDescription
        }
    }

    private func setCleanMic(_ new: MicDenoiser?, note: String?) {
        if new == nil { denoiser?.stop() }
        denoiser = new
        if cleanMicActive != (new != nil) { cleanMicActive = new != nil }
        if cleanMicNote != note {
            cleanMicNote = note
            Self.log.notice("Cancelar meu ruído: \(note ?? "desligado", privacy: .public)")
        }
    }

    private static let log = Logger(subsystem: "com.wellingtonmota.volmix", category: "cleanMic")

    func toggleMicMute() {
        guard let muted = micMuted else { return }
        do {
            try CA.setInputMuted(!muted, device: inputDevice)
            micMuted = CA.inputMuted(inputDevice)
        } catch {
            status = error.localizedDescription
        }
    }

    // MARK: Gravação

    func toggleRecording() {
        if isRecording { stop() } else { autoStarted = false; start() }
    }

    func outputChanged(uid: String?) {
        outputUID = uid
        guard isRecording, let recorder, let uid else { return }
        // Novo fone/alto-falante: abre outro segmento no novo dispositivo.
        do {
            try recorder.startSystem(outputUID: uid, excluding: excludedProcesses)
        } catch {
            status = String(localized: "A gravação do áudio dos outros parou: \(error.localizedDescription)")
        }
    }

    private var excludedProcesses: [AudioObjectID] { ownProcessObject.map { [$0] } ?? [] }

    private func start() {
        guard phase == .idle, !isStarting else { return }
        guard let outputUID else {
            status = String(localized: "Nenhum dispositivo de saída encontrado.")
            autoStarted = false
            return
        }
        isStarting = true
        let title = callApps.first ?? String(localized: "Gravação")

        Task { @MainActor in
            defer { isStarting = false }
            let micAllowed = await Self.requestMicAccess()
            do {
                let stamp = Date().formatted(.iso8601.year().month().day().dateSeparator(.dash))
                    + " " + Date().formatted(date: .omitted, time: .shortened).replacingOccurrences(of: ":", with: "h")
                let safeTitle = title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
                let folder = Self.notesFolder.appendingPathComponent("\(stamp) \(safeTitle)", isDirectory: true)

                let rec = try MeetingRecorder(folder: folder)
                try rec.startSystem(outputUID: outputUID, excluding: excludedProcesses)
                if micAllowed {
                    rec.onMicConfigurationChange = { [weak self] in
                        Task { @MainActor in
                            guard let self, self.isRecording else { return }
                            self.recorder?.startMic()
                        }
                    }
                    rec.startMic()
                }

                recorder = rec
                recordingTitle = title
                phase = .recording(since: rec.startDate)
                if !micAllowed {
                    status = String(localized: "Sem permissão de microfone: gravando só o áudio dos outros.")
                } else if let micError = rec.micError {
                    status = String(localized: "Microfone não gravado: \(micError)")
                } else {
                    status = nil
                }
            } catch {
                autoStarted = false
                status = String(localized: "\(error.localizedDescription). Verifique Ajustes > Privacidade e Segurança > Gravação de Tela e Áudio do Sistema.")
            }
        }
    }

    private func stop() {
        guard case .recording(let since) = phase, let rec = recorder else { return }
        rec.stop()
        recorder = nil
        autoStarted = false
        phase = .processing
        status = String(localized: "Transcrevendo…")

        let segments = rec.segments
        let folder = rec.folder
        let title = recordingTitle
        let duration = Date().timeIntervalSince(since)
        let languageID = language
        let languageName = Self.languages.first { $0.id == languageID }?.name ?? languageID

        Task { @MainActor in
            let result = await Self.process(segments: segments, folder: folder, title: title, started: since,
                                            duration: duration, languageID: languageID, languageName: languageName)
            phase = .idle
            status = result.message
            lastNote = result.note ?? folder
            Notifier.post(title: result.note == nil ? String(localized: "Gravação salva") : String(localized: "Notas da reunião prontas"),
                          body: result.message)
        }
    }

    /// Transcreve, resume e grava `transcricao.md` na pasta da reunião. Roda fora da main.
    nonisolated private static func process(segments: [MeetingRecorder.Segment], folder: URL, title: String,
                                            started: Date, duration: Double, languageID: String,
                                            languageName: String) async -> (note: URL?, message: String) {
        guard Transcription.isSupported else {
            return (nil, String(localized: "Áudio salvo. A transcrição no aparelho exige o macOS 26."))
        }
        do {
            let (lines, skipped) = try await Transcription.transcribe(segments: segments, in: folder,
                                                                      locale: Locale(identifier: languageID))
            guard !lines.isEmpty else { return (nil, String(localized: "Áudio salvo. Nenhuma fala foi reconhecida.")) }

            let summary = await Transcription.summarize(lines, language: languageName)
            var text = "# \(title) — \(started.formatted(date: .abbreviated, time: .shortened))\n\n"
            text += "- " + String(localized: "Duração: \(Transcription.timestamp(duration))") + "\n"
            text += "- " + String(localized: "Idioma: \(languageName)") + "\n"
            if !skipped.isEmpty { text += "- " + String(localized: "Trechos não transcritos: \(skipped.joined(separator: ", "))") + "\n" }
            if let summary { text += "\n## " + String(localized: "Resumo") + "\n\n\(summary)\n" }
            text += "\n## " + String(localized: "Transcrição") + "\n\n\(Transcription.markdown(lines))\n"

            let note = folder.appendingPathComponent("transcricao.md")
            try text.write(to: note, atomically: true, encoding: .utf8)
            var message = summary == nil
                ? String(localized: "Transcrição salva. Para ter o resumo, ative a Apple Intelligence nos Ajustes do Sistema.")
                : String(localized: "Transcrição e resumo salvos.")
            if !skipped.isEmpty { message += " " + String(localized: "\(skipped.count) trecho(s) não puderam ser transcritos.") }
            return (note, message)
        } catch {
            return (nil, String(localized: "Áudio salvo, mas a transcrição falhou: \(error.localizedDescription)"))
        }
    }

    private static func requestMicAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    // MARK: Notas

    func openNotes() {
        let target = lastNote ?? Self.notesFolder
        try? FileManager.default.createDirectory(at: Self.notesFolder, withIntermediateDirectories: true)
        if target.pathExtension == "md" {
            NSWorkspace.shared.open(target)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([target])
        }
    }
}

/// Notificações do sistema. Fora de um .app (ex.: `swift run`) não há central de notificações.
enum Notifier {
    static func post(title: String, body: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}
