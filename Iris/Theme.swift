import SwiftUI

/// Direction « Contraste » : clair = maquette 2a, sombre = 2b. Couleurs adaptatives en code
/// (le projet n'a pas d'Asset Catalog de couleurs, seulement l'icône).
enum Theme {
    static let background = adaptive(0xF3F3F1, 0x000000)
    static let sheetBackground = adaptive(0xF3F3F1, 0x0C0C0C)
    static let surface = adaptive(0xFFFFFF, 0x121212)
    /// Boutons ronds, bouton Réglages.
    static let surface2 = adaptive(0xFFFFFF, 0x1C1C1E)
    /// Tuiles Photo / Guide.
    static let tile = adaptive(0xFFFFFF, 0x161616)
    static let ink = adaptive(0x0A0A0A, 0xFFFFFF)
    static let muted = adaptive(0x6B6B6B, 0x8A8A8A)
    static let separator = adaptive(0xECECE9, 0x1F1F1F)
    static let track = adaptive(0xECECE9, 0x262626)
    /// Pastille d'état.
    static let chip = adaptive(0xECECE9, 0x1F1F1F)
    /// Contour de la ligne de transcription.
    static let outline = adaptive(0xDADAD6, 0x222222)
    static let accent = Color(hex: 0xFF5B1F)
    static let onAccent = adaptive(0x0A0A0A, 0x000000)
    /// Remplissage de la batterie : encre en clair, accent en sombre.
    static let batteryFill = adaptive(0x0A0A0A, 0xFF5B1F)
    /// Carré des glyphes de gestes.
    static let glyphBox = adaptive(0x0A0A0A, 0x1F1F1F)

    static let margin: CGFloat = 14
    static let gap: CGFloat = 10

    /// Métadonnées : mono, majuscules, interlettrage ≈ 1.1. Suit Dynamic Type via le style de texte.
    static func mono(_ style: Font.TextStyle = .caption2, weight: Font.Weight = .regular) -> Font {
        .system(style, design: .monospaced, weight: weight)
    }

    private static func adaptive(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) })
    }
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

extension Color {
    init(hex: UInt32) { self.init(uiColor: UIColor(hex: hex)) }
}

/// Libellé de métadonnée : mono, majuscules, `muted`.
struct Meta: View {
    let text: String
    var color = Theme.muted
    init(_ text: String, color: Color = Theme.muted) { self.text = text; self.color = color }

    var body: some View {
        Text(text.uppercased()).font(Theme.mono()).tracking(1.1).foregroundStyle(color)
    }
}
