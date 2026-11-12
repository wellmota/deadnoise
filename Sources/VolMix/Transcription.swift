import AVFoundation
import Foundation
import FoundationModels
import Speech

/// Transcrição e resumo de reuniões, tudo no aparelho (nada sai do Mac).
/// Usa o SpeechAnalyzer e o modelo local da Apple, que exigem macOS 26.
enum Transcription {
    struct Line {
        let time: Double
        let speaker: String
        let text: String
    }

    enum Failure: LocalizedError {
        case needsNewerSystem
        case unsupportedLanguage(String)

        var errorDescription: String? {
            switch self {
            case .needsNewerSystem: return "A transcrição no aparelho exige o macOS 26 ou mais novo."
            case .unsupportedLanguage(let id): return "O idioma \(id) não é suportado pela transcrição no aparelho."
            }
        }
    }

    static var isSupported: Bool {
        if #available(macOS 26.0, *) { return SpeechTranscriber.isAvailable }
        return false
    }

    /// Transcreve um arquivo de áudio. Devolve trechos com o instante de início (em segundos no arquivo).
    static func transcribe(url: URL, locale: Locale) async throws -> [(start: Double, text: String)] {
        guard #available(macOS 26.0, *) else { throw Failure.needsNewerSystem }
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw Failure.unsupportedLanguage(locale.identifier)
        }

        let transcriber = SpeechTranscriber(locale: supported,
                                            transcriptionOptions: [],
                                            reportingOptions: [],
                                            attributeOptions: [.audioTimeRange])
        // Baixa o modelo do idioma na primeira vez.
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }

        let file = try AVAudioFile(forReading: url)
        guard file.length > 0 else { return [] }
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        async let collected: [(start: Double, text: String)] = {
            var out: [(start: Double, text: String)] = []
            for try await result in transcriber.results {
                let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { out.append((result.range.start.seconds, text)) }
            }
            return out
        }()

        if let last = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: last)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        return try await collected
    }

    /// Transcreve todos os segmentos de uma gravação e devolve as falas em ordem cronológica.
    /// Segmentos que falham (arquivo vazio/corrompido) são pulados e relatados em `skipped`.
    static func transcribe(segments: [MeetingRecorder.Segment], in folder: URL, locale: Locale) async throws
        -> (lines: [Line], skipped: [String]) {
        var lines: [Line] = []
        var skipped: [String] = []
        var firstError: Error?

        for segment in segments {
            do {
                let parts = try await transcribe(url: folder.appendingPathComponent(segment.file), locale: locale)
                lines += parts.map { Line(time: segment.offset + $0.start, speaker: segment.speaker, text: $0.text) }
            } catch let failure as Failure {
                throw failure // idioma/sistema: nenhum segmento vai funcionar
            } catch {
                skipped.append(segment.file)
                if firstError == nil { firstError = error }
            }
        }
        if lines.isEmpty, skipped.count == segments.count, let firstError { throw firstError }
        return (lines.sorted { $0.time < $1.time }, skipped)
    }

    /// Texto em Markdown: falas seguidas da mesma pessoa viram um parágrafo só.
    static func markdown(_ lines: [Line]) -> String {
        var out: [String] = []
        var index = 0
        while index < lines.count {
            let first = lines[index]
            var text = first.text
            var next = index + 1
            while next < lines.count, lines[next].speaker == first.speaker, lines[next].time - lines[next - 1].time < 30 {
                text += " " + lines[next].text
                next += 1
            }
            out.append("**[\(timestamp(first.time))] \(first.speaker):** \(text)")
            index = next
        }
        return out.joined(separator: "\n\n")
    }

    static func timestamp(_ seconds: Double) -> String {
        let s = max(Int(seconds), 0)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
                         : String(format: "%02d:%02d", s / 60, s % 60)
    }

    // MARK: Resumo

    /// Resumo da reunião com o modelo local da Apple (Apple Intelligence).
    /// Devolve nil se o modelo não estiver disponível ou recusar o conteúdo.
    static func summarize(_ lines: [Line], language: String) async -> String? {
        guard #available(macOS 26.0, *), SystemLanguageModel.default.isAvailable else { return nil }
        let plain = lines.map { "\($0.speaker): \($0.text)" }
        guard !plain.isEmpty else { return nil }

        // A janela de contexto do modelo local é pequena: resume por blocos e depois junta.
        var chunks: [String] = []
        var current = ""
        for line in plain {
            if current.count + line.count > 5000, !current.isEmpty {
                chunks.append(current)
                current = ""
            }
            current += line + "\n"
        }
        if !current.isEmpty { chunks.append(current) }

        let instructions = """
            Você resume transcrições de reuniões. Responda em \(language), em Markdown, com as seções \
            "Pontos principais", "Decisões" e "Próximos passos" (com responsável quando for dito). \
            Use apenas o que está na transcrição; se uma seção não tiver conteúdo, escreva "Nada registrado".
            """
        do {
            var partials: [String] = []
            for chunk in chunks {
                let session = LanguageModelSession(instructions: instructions)
                partials.append(try await session.respond(to: "Transcrição:\n\(chunk)").content)
            }
            guard partials.count > 1 else { return partials.first }
            let session = LanguageModelSession(instructions: instructions)
            let joined = String(partials.joined(separator: "\n\n").prefix(6000))
            return try await session.respond(to: "Junte estes resumos parciais da mesma reunião em um só:\n\(joined)").content
        } catch {
            return nil
        }
    }
}
