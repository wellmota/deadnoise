import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation
import Synchronization

/// "Cancelar meu ruído": lê o microfone real, passa pelo isolamento de voz da Apple
/// (AUSoundIsolation, roda no aparelho) e toca o resultado no dispositivo oculto do driver
/// do DeadNoise. O driver devolve esse áudio no "DeadNoise Microphone", que os apps de chamada usam.
///
/// No macOS um único AVAudioEngine não aceita dispositivos diferentes na entrada e na saída
/// (o segundo setDeviceID falha com -10851). Por isso são dois motores ligados por um buffer circular:
///   captura: microfone real -> AVAudioSinkNode -> buffer
///   saída:   buffer -> AVAudioSourceNode -> (mono vira estéreo) -> isolamento de voz -> App IO
///
/// O atraso total fica em torno de 0,1 s.
final class MicDenoiser {
    /// Devem bater com Driver/VolMixAudio.c.
    static let micUID = "VolMixMic_UID"
    static let appIOUID = "VolMixAppIO_UID"
    /// Nome usado só enquanto o dispositivo não foi encontrado; com o driver instalado, vale o nome real.
    static let micName = "DeadNoise Microphone"

    private let captureEngine = AVAudioEngine()
    private let outputEngine = AVAudioEngine()
    private let ring: SampleRing
    private var observers: [NSObjectProtocol] = []
    var onConfigurationChange: (() -> Void)?

    init(inputDevice: AudioDeviceID, outputDevice: AudioDeviceID) throws {
        // Saída primeiro, num motor que nunca toca no inputNode.
        try outputEngine.outputNode.auAudioUnit.setDeviceID(outputDevice)
        try captureEngine.inputNode.auAudioUnit.setDeviceID(inputDevice)

        let inFormat = captureEngine.inputNode.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else {
            throw CoreAudioError(status: kAudioHardwareBadDeviceError, context: "O microfone não está entregando áudio")
        }
        guard let mono = AVAudioFormat(standardFormatWithSampleRate: inFormat.sampleRate, channels: 1) else {
            throw CoreAudioError(status: kAudioFormatUnsupportedDataFormatError, context: "Formato do microfone não suportado")
        }

        let ring = SampleRing(capacity: 1 << 16, sampleRate: inFormat.sampleRate)
        self.ring = ring

        // Captura: só o primeiro canal do microfone (é o que os microfones de notebook e fones entregam).
        let sink = AVAudioSinkNode { _, frames, abl in
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: abl))
            guard let first = buffers.first, let data = first.mData else { return noErr }
            let channels = Int(max(1, first.mNumberChannels)) // >1 quando vem intercalado
            ring.write(data.assumingMemoryBound(to: Float.self), frames: Int(frames), stride: channels)
            return noErr
        }
        captureEngine.attach(sink)
        captureEngine.connect(captureEngine.inputNode, to: sink, format: inFormat)

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
        try Self.buildChain(in: outputEngine, from: source, format: mono)

        outputEngine.prepare()
        captureEngine.prepare()
        try outputEngine.start()
        do {
            try captureEngine.start()
        } catch {
            outputEngine.stop()
            throw error
        }

        for engine in [captureEngine, outputEngine] {
            observers.append(NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                                                    object: engine, queue: .main) { [weak self] _ in
                self?.onConfigurationChange?()
            })
        }
    }

    deinit { stop() }

    func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        captureEngine.stop()
        outputEngine.stop()
    }

    /// fonte -> (mono vira estéreo) -> isolamento de voz -> mixer principal -> saída.
    static func buildChain(in engine: AVAudioEngine, from source: AVAudioNode, format: AVAudioFormat) throws {
        guard let stereo = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: 2) else {
            throw CoreAudioError(status: kAudioFormatUnsupportedDataFormatError, context: "Formato do microfone não suportado")
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
                  "Isolamento de voz indisponível neste macOS")
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
    private let target: Int      // atraso de equilíbrio
    private let maxBacklog: Int  // acima disso, descarta o excesso

    init(capacity: Int, sampleRate: Double) {
        precondition(capacity & (capacity - 1) == 0)
        storage = .allocate(capacity: capacity)
        storage.initialize(repeating: 0, count: capacity)
        mask = capacity - 1
        target = Int(sampleRate * 0.03)
        maxBacklog = min(Int(sampleRate * 0.12), capacity / 2)
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
        if w - r > maxBacklog { r = w - target }
        let available = min(frames, max(0, w - r))
        for i in 0..<available { dst[i] = storage[(r + i) & mask] }
        for i in available..<frames { dst[i] = 0 }
        readPos.store(r + available, ordering: .relaxed)
    }
}
