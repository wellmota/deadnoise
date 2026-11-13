import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation
import Synchronization
import os

/// "Cancelar meu ruído": lê o microfone real, passa pelo isolamento de voz da Apple
/// (AUSoundIsolation, roda no aparelho) e toca o resultado no dispositivo oculto do driver
/// do DeadNoise. O driver devolve esse áudio no "DeadNoise Microphone", que os apps de chamada usam.
///
/// No macOS um único AVAudioEngine não aceita dispositivos diferentes na entrada e na saída
/// (o segundo setDeviceID falha com -10851). Por isso a captura e a saída são separadas,
/// ligadas por um buffer circular:
///   captura: microfone real -> InputCapture (Core Audio direto, sem AVAudioEngine) -> buffer
///   saída:   buffer -> AVAudioSourceNode -> (mono vira estéreo) -> isolamento de voz -> App IO
///
/// O atraso total fica em torno de 0,1 s.
final class MicDenoiser {
    /// Devem bater com Driver/VolMixAudio.c.
    static let micUID = "VolMixMic_UID"
    static let appIOUID = "VolMixAppIO_UID"
    /// Nome usado só enquanto o dispositivo não foi encontrado; com o driver instalado, vale o nome real.
    static let micName = "DeadNoise Microphone"

    private var capture: InputCapture?
    private let outputEngine = AVAudioEngine()
    private let ring: SampleRing
    private var observers: [NSObjectProtocol] = []
    var onConfigurationChange: (() -> Void)?

    init(inputDevice: AudioDeviceID, outputDevice: AudioDeviceID) throws {
        // Saída num motor que nunca toca no inputNode.
        try outputEngine.outputNode.auAudioUnit.setDeviceID(outputDevice)

        // A capacidade do buffer é fixa; a taxa vem do microfone quando a captura abre.
        let ring = SampleRing(capacity: 1 << 16)
        self.ring = ring
        let capture = try InputCapture(device: inputDevice) { samples, frames, stride in
            ring.write(samples, frames: frames, stride: stride)
        }
        self.capture = capture
        ring.configure(sampleRate: capture.sampleRate)
        guard let mono = AVAudioFormat(standardFormatWithSampleRate: capture.sampleRate, channels: 1) else {
            capture.stop()
            throw CoreAudioError(status: kAudioFormatUnsupportedDataFormatError, context: String(localized: "Formato do microfone não suportado"))
        }

        // Saída: lê do buffer no ritmo do App IO.
        let source = AVAudioSourceNode(format: mono) { _, _, frames, abl in
            let buffers = UnsafeMutableAudioBufferListPointer(abl)
            for buffer in buffers {
                guard let data = buffer.mData else { continue }
                ring.read(into: data.assumingMemoryBound(to: Float.self), frames: Int(frames))
            }
            return noErr
        }
        outputEngine.attach(source)

        do {
            try Self.buildChain(in: outputEngine, from: source, format: mono)
            outputEngine.prepare()
            try outputEngine.start()
        } catch {
            capture.stop()
            throw error
        }

        capture.onChange = { [weak self] in self?.onConfigurationChange?() }
        observers.append(NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                                                object: outputEngine, queue: .main) { [weak self] _ in
            // O App IO tem formato fixo; o aviso vem de mudanças em volta (ex.: outro dispositivo trocando de
            // modo). Recriar tudo aqui fechava e reabria o microfone e entrava em laço. Basta religar a saída.
            guard let self, !self.outputEngine.isRunning, self.capture != nil else { return }
            do {
                try self.outputEngine.start()
            } catch {
                Logger(subsystem: "com.wellingtonmota.volmix", category: "input")
                    .error("saída (App IO) não religou: \(error.localizedDescription, privacy: .public)")
                self.onConfigurationChange?()
            }
        })
    }

    deinit { stop() }

    func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        capture?.stop()
        capture = nil
        outputEngine.stop()
    }

    /// fonte -> (mono vira estéreo) -> isolamento de voz -> mixer principal -> saída.
    static func buildChain(in engine: AVAudioEngine, from source: AVAudioNode, format: AVAudioFormat) throws {
        guard let stereo = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: 2) else {
            throw CoreAudioError(status: kAudioFormatUnsupportedDataFormatError, context: String(localized: "Formato do microfone não suportado"))
        }
        let isolation = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: kAudioUnitSubType_AUSoundIsolation,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0))
        let upmix = AVAudioMixerNode()

        engine.attach(upmix)
        engine.attach(isolation)
        engine.connect(source, to: upmix, format: format)
        engine.connect(upmix, to: isolation, format: stereo)
        engine.connect(isolation, to: engine.mainMixerNode, format: stereo)

        try check(AudioUnitSetParameter(isolation.audioUnit, kAUSoundIsolationParam_WetDryMixPercent,
                                        kAudioUnitScope_Global, 0, 100, 0),
                  String(localized: "Isolamento de voz indisponível neste macOS"))
    }
}

/// Buffer circular de um produtor (thread de captura) e um consumidor (thread de saída), sem trava.
/// Os dois relógios (microfone e App IO) andam um pouco diferentes: quando sobra áudio demais,
/// pula para perto do fim para o atraso não crescer; quando falta, entrega silêncio.
private final class SampleRing: @unchecked Sendable {
    private let storage: UnsafeMutablePointer<Float>
    private let mask: Int
    private let written = Atomic<Int>(0)
    private let readPos = Atomic<Int>(0)
    private let capacity: Int
    private let target = Atomic<Int>(1440)      // atraso de equilíbrio (30 ms)
    private let maxBacklog = Atomic<Int>(5760)  // acima disso, descarta o excesso (120 ms)

    init(capacity: Int) {
        precondition(capacity & (capacity - 1) == 0)
        self.capacity = capacity
        storage = .allocate(capacity: capacity)
        storage.initialize(repeating: 0, count: capacity)
        mask = capacity - 1
    }

    func configure(sampleRate: Double) {
        target.store(Int(sampleRate * 0.03), ordering: .relaxed)
        maxBacklog.store(min(Int(sampleRate * 0.12), capacity / 2), ordering: .relaxed)
    }

    deinit { storage.deallocate() }

    func write(_ src: UnsafePointer<Float>, frames: Int, stride: Int) {
        let w = written.load(ordering: .relaxed)
        for i in 0..<frames { storage[(w + i) & mask] = src[i * stride] }
        written.store(w + frames, ordering: .releasing)
    }

    func read(into dst: UnsafeMutablePointer<Float>, frames: Int) {
        let w = written.load(ordering: .acquiring)
        var r = readPos.load(ordering: .relaxed)
        if w - r > maxBacklog.load(ordering: .relaxed) { r = w - target.load(ordering: .relaxed) }
        let available = min(frames, max(0, w - r))
        for i in 0..<available { dst[i] = storage[(r + i) & mask] }
        for i in available..<frames { dst[i] = 0 }
        readPos.store(r + available, ordering: .relaxed)
    }
}
