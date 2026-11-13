import AudioToolbox
import CoreAudio
import Foundation
import os

/// Lê um microfone direto do Core Audio (IOProc), sem AVAudioEngine.
///
/// O AVAudioEngine lança exceções de Objective-C quando o formato do microfone muda no meio do caminho
/// (ex.: AirPods mudando para o modo de chamada ao abrir o microfone, de 48 para 24 kHz). Essas exceções
/// atravessam o código Swift sem tratamento, deixam o app num estado corrompido e terminam em crash.
/// Aqui qualquer problema vira um OSStatus, e o formato é conferido a cada bloco de áudio.
///
/// Entrega o primeiro canal do microfone, em Float32, na thread de IO do Core Audio (tempo real:
/// o handler não deve alocar memória nem travar). Quando o formato muda, o dispositivo some ou
/// (com `followsDefaultInput`) o microfone padrão do sistema muda, chama `onChange` na main.
final class InputCapture {
    /// Amostras do primeiro canal: `samples[i * stride]` para i em 0..<frames.
    typealias Handler = (_ samples: UnsafePointer<Float>, _ frames: Int, _ stride: Int) -> Void

    let device: AudioDeviceID
    let sampleRate: Double
    var onChange: (() -> Void)?

    private var procID: AudioDeviceIOProcID?
    private var listeners: [(object: AudioObjectID, address: AudioObjectPropertyAddress, block: AudioObjectPropertyListenerBlock)] = []
    private var changed = false

    init(device: AudioDeviceID, followsDefaultInput: Bool = false, handler: @escaping Handler) throws {
        self.device = device

        // Formato que o Core Audio entrega para este processo no primeiro stream de entrada.
        guard let stream = CA.readObjectList(device, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput).first else {
            throw CoreAudioError(status: kAudioHardwareBadDeviceError, context: String(localized: "Nenhum microfone disponível"))
        }
        let format = try CA.read(stream, kAudioStreamPropertyVirtualFormat, as: AudioStreamBasicDescription())
        guard format.mFormatID == kAudioFormatLinearPCM, format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mBitsPerChannel == 32, format.mSampleRate > 0 else {
            throw CoreAudioError(status: kAudioFormatUnsupportedDataFormatError, context: String(localized: "Formato do microfone não suportado"))
        }
        sampleRate = format.mSampleRate

        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, device, nil) { _, input, _, _, _ in
            let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            guard let first = list.first, let data = first.mData else { return }
            let stride = Int(max(first.mNumberChannels, 1))
            let frames = Int(first.mDataByteSize) / (MemoryLayout<Float>.size * stride)
            guard frames > 0 else { return }
            handler(data.assumingMemoryBound(to: Float.self), frames, stride)
        }, String(localized: "Não foi possível abrir o microfone"))

        // Qualquer mudança de formato, de streams ou de disponibilidade pede uma nova captura.
        listen(device, kAudioDevicePropertyNominalSampleRate)
        listen(device, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput)
        listen(device, kAudioDevicePropertyDeviceIsAlive)
        listen(stream, kAudioStreamPropertyVirtualFormat)
        if followsDefaultInput {
            listen(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice)
        }

        let status = AudioDeviceStart(device, procID)
        if status != noErr {
            stop()
            throw CoreAudioError(status: status, context: String(localized: "Não foi possível abrir o microfone"))
        }
    }

    deinit { stop() }

    func stop() {
        for l in listeners {
            var address = l.address
            AudioObjectRemovePropertyListenerBlock(l.object, &address, .main, l.block)
        }
        listeners = []
        if let procID {
            AudioDeviceStop(device, procID)
            AudioDeviceDestroyIOProcID(device, procID)
        }
        procID = nil
    }

    private static let log = Logger(subsystem: "com.wellingtonmota.volmix", category: "input")

    private func listen(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) {
        var address = CA.address(selector, scope: scope)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            // Avisa uma vez só: quem usa recria a captura (e esta é descartada).
            guard let self, !self.changed else { return }
            Self.log.notice("microfone mudou: \(fourCC(selector), privacy: .public)")
            self.changed = true
            self.onChange?()
        }
        if AudioObjectAddPropertyListenerBlock(object, &address, .main, block) == noErr {
            listeners.append((object, address, block))
        }
    }
}

/// "nsrt", "stmf"…: nome legível de um seletor do Core Audio, para o log.
func fourCC(_ value: UInt32) -> String {
    let bytes = [24, 16, 8, 0].map { UInt8((value >> $0) & 0xFF) }
    return String(bytes: bytes, encoding: .ascii) ?? String(value)
}
