import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

/// "Cancelar meu ruído": lê o microfone real, passa pelo isolamento de voz da Apple
/// (AUSoundIsolation, roda no aparelho) e toca o resultado no dispositivo oculto do driver
/// do DeadNoise. O driver devolve esse áudio no "DeadNoise Microphone", que os apps de chamada usam.
///
/// O atraso total fica em torno de 0,1 s.
final class MicDenoiser {
    /// Devem bater com Driver/VolMixAudio.c.
    static let micUID = "VolMixMic_UID"
    static let appIOUID = "VolMixAppIO_UID"
    /// Nome usado só enquanto o dispositivo não foi encontrado; com o driver instalado, vale o nome real.
    static let micName = "DeadNoise Microphone"

    private let engine = AVAudioEngine()
    private var observer: NSObjectProtocol?
    var onConfigurationChange: (() -> Void)?

    init(inputDevice: AudioDeviceID, outputDevice: AudioDeviceID) throws {
        try engine.inputNode.auAudioUnit.setDeviceID(inputDevice)
        try engine.outputNode.auAudioUnit.setDeviceID(outputDevice)

        let format = engine.inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw CoreAudioError(status: kAudioHardwareBadDeviceError, context: "O microfone não está entregando áudio")
        }
        try Self.buildChain(in: engine, from: engine.inputNode, format: format)

        engine.prepare()
        try engine.start()

        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                                          object: engine, queue: .main) { [weak self] _ in
            self?.onConfigurationChange?()
        }
    }

    deinit { stop() }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        engine.stop()
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
