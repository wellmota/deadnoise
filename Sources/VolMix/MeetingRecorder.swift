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

/// Microfone padrão gravado em arquivo. Lê pelo Core Audio direto (InputCapture), sem AVAudioEngine,
/// para uma troca de formato no meio da gravação (ex.: AirPods) não derrubar o app.
private final class MicCapture {
    private var capture: InputCapture?
    private let queue = DispatchQueue(label: "volmix.rec.mic", qos: .userInitiated)
    private var file: AVAudioFile?
    var onConfigurationChange: (() -> Void)?

    init(url: URL) throws {
        let device = (try? CA.defaultInputDevice()) ?? AudioDeviceID(kAudioObjectUnknown)
        guard device != kAudioObjectUnknown else {
            throw CoreAudioError(status: kAudioHardwareBadDeviceError, context: String(localized: "Nenhum microfone disponível"))
        }
        // Abre a captura primeiro para saber a taxa do microfone; as amostras só são gravadas depois que o arquivo existe.
        var writer: ((UnsafePointer<Float>, Int, Int) -> Void)?
        let lock = NSLock()
        let capture = try InputCapture(device: device, followsDefaultInput: true) { samples, frames, stride in
            lock.lock(); let write = writer; lock.unlock()
            write?(samples, frames, stride)
        }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: capture.sampleRate, channels: 1) else {
            capture.stop()
            throw CoreAudioError(status: kAudioFormatUnsupportedDataFormatError, context: String(localized: "Formato do microfone não suportado"))
        }
        do {
            file = try AVAudioFile(forWriting: url, settings: aacSettings(for: format),
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch {
            capture.stop()
            throw error
        }
        let queue = self.queue
        lock.lock()
        writer = { [weak self] samples, frames, stride in
            // Copia o bloco e grava fora da thread de áudio.
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
                  let channel = buffer.floatChannelData?[0] else { return }
            for i in 0..<frames { channel[i] = samples[i * stride] }
            buffer.frameLength = AVAudioFrameCount(frames)
            queue.async { try? self?.file?.write(from: buffer) }
        }
        lock.unlock()
        capture.onChange = { [weak self] in self?.onConfigurationChange?() }
        self.capture = capture
    }

    deinit { stop() }

    func stop() {
        capture?.stop()
        capture = nil
        // Fecha o arquivo depois de gravar o que ainda estava na fila (fechar finaliza o .m4a).
        queue.sync { file = nil }
    }
}
