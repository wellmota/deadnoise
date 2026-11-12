import AppKit

/// Ícone da barra de menus: a caveira de barras de onda da logo, simplificada para 18 pt.
/// Desenhado em código (sem arquivo de recurso) e marcado como template, para o macOS
/// pintar de claro ou escuro conforme a barra.
enum MenuBarIcon {
    static let image: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { rect in
            NSColor.black.setFill()
            for bar in bars(in: rect) {
                NSBezierPath(roundedRect: bar, xRadius: bar.width / 2, yRadius: bar.width / 2).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "DeadNoise"
        return image
    }()

    /// Sete barras verticais; as órbitas e o nariz são os vãos.
    static func bars(in rect: CGRect) -> [CGRect] {
        let count = 7
        let half = rect.width / 2
        let width: CGFloat = rect.width * 0.105
        var out: [CGRect] = []
        for i in 0..<count {
            let x = -0.84 + CGFloat(i) * (1.68 / CGFloat(count - 1))
            let ax = abs(x)
            let top = -0.90 * sqrt(max(0, 1 - pow(ax / 0.98, 2)))          // crânio
            var segments: [(CGFloat, CGFloat)]
            switch i {
            case 0, 6: segments = [(top, 0.18)]                             // têmporas
            case 1, 5: segments = [(top, -0.22), (0.30, 0.62)]              // órbitas
            case 2, 4: segments = [(top, -0.10), (0.20, 0.90)]
            default:   segments = [(top, 0.16), (0.46, 0.78)]               // nariz
            }
            for (a, b) in segments where b - a > 0.05 {
                out.append(CGRect(x: rect.midX + x * half - width / 2, y: rect.midY + a * half * 0.98,
                                  width: width, height: (b - a) * half * 0.98))
            }
        }
        return out
    }
}
