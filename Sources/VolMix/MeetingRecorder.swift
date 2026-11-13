import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

/// Grava uma reunião em duas trilhas separadas: o que os outros falam (áudio do sistema)
/// e o que você fala (microfone). Trilhas separadas dão a atribuição "Eu" / "Outros"
/// na transcrição sem precisar de um modelo de diarização.
///
/// Trocar de fone no meio da chamada muda o formato do áudio, então cada troca abre um
/// novo segmento de arquivo, com o deslocamento em relação ao início da gravação.
final class MeetingRecorder {
    struct Segment: Codable {
        let file: String
        let speaker: String
        let offset: Double
    }

    static let me = String(localized: "Eu", comment: "Quem fala na transcrição: você")
    static let others = String(localized: "Outros", comment: "Quem fala na transcrição: os outros participantes")

    let folder: URL
    let startDate = Date()
    private(set) var segments: [Segment] = []
    /// Motivo de o microfone não estar sendo gravado, se houver.
    private(set) var micError: String?

    private var system: SystemCapture?
    private var mic: MicCapture?
    private var counter = 0
    /// Chamado (na main) quando o microfone muda de configuração e precisa de novo segmento.
    var onMicConfigurationChange: (() -> Void)?

    init(folder: URL) throws {
        self.folder = folder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    private func nextSegment(prefix: String, speaker: String) -> URL {
        counter += 1
        let name = "\(prefix)-\(counter).m4a"
        segments.append(Segment(file: name, speaker: speaker, offset: Date().timeIntervalSince(startDate)))
        return folder.appendingPathComponent(name)
    }

    /// (Re)inicia a captura do áudio do sistema no dispositivo de saída atual.
    func startSystem(outputUID: String, excluding: [AudioObjectID]) throws {
        system?.stop()
        system = nil
        let url = nextSegment(prefix: "sistema", speaker: Self.others)
        do {
            system = try SystemCapture(url: url, outputUID: outputUID, excluding: excluding)
        } catch {
            segments.removeLast()
            throw error
        }
    }

    /// (Re)inicia a captura do microfone. Falha aqui não interrompe a gravação do sistema.
    func startMic() {
        mic?.stop()
        mic = nil
        let url = nextSegment(prefix: "mic", speaker: Self.me)
        do {
            let capture = try MicCapture(url: url)
            capture.onConfigurationChange = { [weak self] in self?.onMicConfigurationChange?() }
            mic = capture
            micError = nil
        } catch {
            segments.removeLast()
            micError = error.localizedDescription
        }
    }

    func stop() {
        system?.stop()
        mic?.stop()
        system = nil
        mic = nil
    }
}

private func aacSettings(for format: AVAudioFormat) -> [String: Any] {
    [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: format.sampleRate,
        AVNumberOfChannelsKey: Int(format.channelCount),
    ]
}

/// Tap global (tudo o que toca no Mac, menos o próprio DeadNoise) gravado em arquivo.
/// O tap não silencia nada: os apps continuam tocando normalmente.
private final class SystemCapture {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "volmix.rec.io", qos: .userInitiated)
    private var file: AVAudioFile?
    private var buffer: AVAudioPCMBuffer?
    private var bytesPerFrame = 0

    init(url: URL, outputUID: String, excluding: [AudioObjectID]) throws {
        do {
            try start(url: url, outputUID: outputUID, excluding: excluding)
        } catch {
            stop()
            throw error
        }
    }

    deinit { stop() }

    private func start(url: URL, outputUID: String, excluding: [AudioObjectID]) throws {
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: excluding)
        desc.uuid = UUID()
        desc.name = "DeadNoise gravação"
        desc.isPrivate = true
        desc.muteBehavior = .unmuted
        try check(AudioHardwareCreateProcessTap(desc, &tapID), String(localized: "Falha ao criar o tap de gravação"))

        var tapFormat = try CA.read(tapID, kAudioTapPropertyFormat, as: AudioStreamBasicDescription())
        guard let format = AVAudioFormat(streamDescription: &tapFormat) else {
            throw CoreAudioError(status: kAudioFormatUnsupportedDataFormatError, context: String(localized: "Formato de áudio do sistema não suportado"))
        }
        let file = try AVAudioFile(forWriting: url, settings: aacSettings(for: format),
                                   commonFormat: .pcmFormatFloat32, interleaved: format.isInterleaved)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 16384) else {
            throw CoreAudioError(status: kAudio_MemFullError, context: String(localized: "Sem memória para gravar"))
        }
        self.file = file
        self.buffer = buffer
        bytesPerFrame = Int(file.processingFormat.streamDescription.pointee.mBytesPerFrame)

        let aggregateDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "DeadNoise gravação",
            kAudioAggregateDeviceUIDKey: "volmix-rec-\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: desc.uuid.uuidString,
            ]],
        ]
        try check(AudioHardwareCreateAggregateDevice(aggregateDesc as CFDictionary, &aggregateID),
                  String(localized: "Falha ao criar o dispositivo de gravação"))

        try check(AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, queue) { [weak self] _, input, _, output, _ in
            // Não tocamos nada: a saída do agregado fica em silêncio.
            for buf in UnsafeMutableAudioBufferListPointer(output) {
                if let data = buf.mData { memset(data, 0, Int(buf.mDataByteSize)) }
            }
            self?.write(input)
        }, String(localized: "Falha ao criar o IOProc de gravação"))

        try check(AudioDeviceStart(aggregateID, ioProcID), String(localized: "Falha ao iniciar a gravação do áudio do sistema"))
    }

    /// Roda na fila de IO.
    private func write(_ input: UnsafePointer<AudioBufferList>) {
        guard let file, let buffer, bytesPerFrame > 0 else { return }
        let inList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let dst = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        // O tap é sempre o último grupo de streams de entrada do agregado.
        guard inList.count >= dst.count, dst.count > 0 else { return }
        let first = inList.count - dst.count
        let frames = min(Int(inList[first].mDataByteSize) / bytesPerFrame, Int(buffer.frameCapacity))
        guard frames > 0 else { return }

        buffer.frameLength = AVAudioFrameCount(frames)
        for i in 0..<dst.count {
            guard let from = inList[first + i].mData, let to = dst[i].mData else { return }
            memcpy(to, from, min(frames * bytesPerFrame, Int(inList[first + i].mDataByteSize)))
        }
        try? file.write(from: buffer)
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown {
            if let ioProcID {
                AudioDeviceStop(aggregateID, ioProcID)
                AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        ioProcID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
        // Fecha o arquivo depois que a fila de IO esvaziar (fechar finaliza o .m4a).
        queue.sync {
            file = nil
            buffer = nil
        }
    }
}

/// Microfone padrão gravado em arquivo.
private final class MicCapture {
    private let engine = AVAudioEngine()
    private var file: AVAudioFile?
    private let lock = NSLock()
    private var observer: NSObjectProtocol?
    var onConfigurationChange: (() -> Void)?

    init(url: URL) throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw CoreAudioError(status: kAudioHardwareBadDeviceError, context: String(localized: "Nenhum microfone disponível"))
        }
        file = try AVAudioFile(forWriting: url, settings: aacSettings(for: format),
                               commonFormat: .pcmFormatFloat32, interleaved: format.isInterleaved)

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            self.lock.lock()
            defer { self.lock.unlock() }
            try? self.file?.write(from: buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            file = nil
            throw error
        }

        // Trocar de microfone/fone para o engine: quem grava decide abrir novo segmento.
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                                          object: engine, queue: .main) { [weak self] _ in
            self?.onConfigurationChange?()
        }
    }

    deinit { stop() }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        lock.lock()
        file = nil
        lock.unlock()
    }
}
