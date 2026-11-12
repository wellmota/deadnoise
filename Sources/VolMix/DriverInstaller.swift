import Foundation

/// Instala o driver do microfone virtual que vem dentro do app (Contents/Resources).
/// Usado quando o app foi arrastado para Aplicativos pelo .dmg, sem passar pelo instalador .pkg.
enum DriverInstaller {
    static let destination = "/Library/Audio/Plug-Ins/HAL/VolMixAudio.driver"

    enum Failure: LocalizedError {
        case notBundled
        case cancelled
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .notBundled: return "Esta cópia do app não traz o driver. Use o instalador do site."
            case .cancelled: return "Instalação cancelada."
            case .failed(let message): return "Não foi possível instalar o microfone virtual: \(message)"
            }
        }
    }

    static var bundledDriver: URL? {
        Bundle.main.url(forResource: "VolMixAudio", withExtension: "driver")
    }

    /// Copia o driver para a pasta de drivers de áudio do sistema e reinicia o serviço de áudio.
    /// Mostra o pedido de senha de administrador do macOS. Chamar na thread principal.
    static func install() throws {
        guard let source = bundledDriver else { throw Failure.notBundled }
        let command = [
            "/bin/rm -rf \(quoted(destination))",
            "/bin/cp -R \(quoted(source.path)) \(quoted(destination))",
            "/usr/sbin/chown -R root:wheel \(quoted(destination))",
            "(/usr/bin/killall coreaudiod || true)",
        ].joined(separator: " && ")

        let script = "do shell script \"\(appleScriptEscaped(command))\" "
            + "with prompt \"O DeadNoise precisa instalar o microfone virtual.\" with administrator privileges"
        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)
        if let error {
            // -128: a pessoa clicou em Cancelar no pedido de senha.
            if (error[NSAppleScript.errorNumber] as? Int) == -128 { throw Failure.cancelled }
            throw Failure.failed((error[NSAppleScript.errorMessage] as? String) ?? "erro desconhecido")
        }
    }

    /// Aspas simples de shell, com escape de aspas internas.
    static func quoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func appleScriptEscaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
