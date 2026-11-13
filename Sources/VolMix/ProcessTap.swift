import AudioToolbox
import CoreAudio
import Foundation

/// Ganho compartilhado com a thread de áudio. Leitura/escrita de Float é atômica em arm64/x86_64,
/// e uma leitura "atrasada" só atrasa a rampa em um buffer, então dispensamos locks no IO.
final class GainBox: @unchecked Sendable {
    var target: Float
    var current: Float
    init(_ value: Float) { target = value; current = value }
}

/// Captura o áudio de um conjunto de processos (silenciando o original),
/// aplica ganho e toca no dispositivo de saída atual.
///
/// Fluxo: CATapDescription -> process tap -> aggregate device (saída real + tap) -> IOProc com ganho.
final class ProcessTap {
    let processObjectIDs: Set<AudioObjectID>
    let outputUID: String

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private let gainBox: GainBox
    private let queue = DispatchQueue(label: "volmix.tap.io", qos: .userInteractive)

    var gain: Float {
        get { gainBox.target }
        set { gainBox.target = newValue }
    }

    init(processObjectIDs: [AudioObjectID], outputUID: String, name: String, gain: Float) throws {
        self.processObjectIDs = Set(processObjectIDs)
        self.outputUID = outputUID
        self.gainBox = GainBox(gain)

        do {
            try start(name: name)
        } catch {
            invalidate()
            throw error
        }
    }

    deinit { invalidate() }

    private func start(name: String) throws {
        // 1. Tap dos processos. `.mutedWhenTapped`: o som original some só enquanto lemos o tap;
        //    se o DeadNoise travar/fechar, o app volta a tocar normalmente.
        let desc = CATapDescription(stereoMixdownOfProcesses: Array(processObjectIDs))
        desc.uuid = UUID()
        desc.name = "DeadNoise \(name)"
        desc.isPrivate = true
        desc.muteBehavior = .mutedWhenTapped
        try check(AudioHardwareCreateProcessTap(desc, &tapID), String(localized: "Falha ao criar o tap de \(name)"))

        let tapFormat = try CA.read(tapID, kAudioTapPropertyFormat, as: AudioStreamBasicDescription())
        let tapNonInterleaved = tapFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        let tapBufferCount = tapNonInterleaved ? max(Int(tapFormat.mChannelsPerFrame), 1) : 1

        // 2. Aggregate device privado: saída real como sub-device + o tap como entrada.
        let aggregateDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "DeadNoise \(name)",
            kAudioAggregateDeviceUIDKey: "volmix-\(UUID().uuidString)",
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
                  String(localized: "Falha ao criar o dispositivo agregado de \(name)"))

        // 3. IOProc: copia tap -> saída aplicando ganho.
        let box = gainBox
        try check(AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, queue) { _, input, _, output, _ in
            ProcessTap.render(input: input, output: output, tapBufferCount: tapBufferCount, box: box)
        }, String(localized: "Falha ao criar o IOProc de \(name)"))

        try check(AudioDeviceStart(aggregateID, ioProcID), String(localized: "Falha ao iniciar o áudio de \(name)"))
    }

    func invalidate() {
        if aggregateID != kAudioObjectUnknown {
            if let ioProcID {
                AudioDeviceStop(aggregateID, ioProcID)
                AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
        ioProcID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    // MARK: Render (thread de áudio — sem alocação, sem locks)

    private static func render(input: UnsafePointer<AudioBufferList>,
                               output: UnsafeMutablePointer<AudioBufferList>,
                               tapBufferCount: Int,
                               box: GainBox) {
        let inList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outList = UnsafeMutableAudioBufferListPointer(output)

        for buf in outList {
            if let data = buf.mData { memset(data, 0, Int(buf.mDataByteSize)) }
        }

        // O tap é sempre o último stream de entrada do agregado
        // (se a saída tiver microfone, os streams dele vêm antes).
        guard inList.count >= tapBufferCount else { return }
        let firstTap = inList.count - tapBufferCount
        let interleaved = tapBufferCount == 1
        let inChannels = interleaved ? max(Int(inList[firstTap].mNumberChannels), 1) : tapBufferCount
        let inFrames = Int(inList[firstTap].mDataByteSize) / (MemoryLayout<Float>.size * (interleaved ? inChannels : 1))
        guard inFrames > 0 else { return }

        let start = box.current
        let target = box.target
        box.current = target

        var channelBase = 0
        for buf in outList {
            guard let outData = buf.mData else { continue }
            let outChannels = max(Int(buf.mNumberChannels), 1)
            let frames = min(inFrames, Int(buf.mDataByteSize) / (MemoryLayout<Float>.size * outChannels))
            let dst = outData.assumingMemoryBound(to: Float.self)

            for c in 0..<outChannels {
                let global = channelBase + c
                let srcChannel: Int
                if global < inChannels { srcChannel = global }
                else if inChannels == 1 && global < 2 { srcChannel = 0 } // mono -> estéreo
                else { continue }

                let src: UnsafeMutablePointer<Float>
                let srcStride: Int
                let srcOffset: Int
                if interleaved {
                    guard let d = inList[firstTap].mData else { continue }
                    src = d.assumingMemoryBound(to: Float.self)
                    srcStride = inChannels
                    srcOffset = srcChannel
                } else {
                    guard let d = inList[firstTap + srcChannel].mData else { continue }
                    src = d.assumingMemoryBound(to: Float.self)
                    srcStride = 1
                    srcOffset = 0
                }

                let step = frames > 1 ? (target - start) / Float(frames - 1) : 0
                var g = frames > 1 ? start : target
                for f in 0..<frames {
                    let s = src[f * srcStride + srcOffset] * g
                    dst[f * outChannels + c] = min(max(s, -1), 1)
                    g += step
                }
            }
            channelBase += outChannels
        }
    }
}
