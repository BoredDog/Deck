import SwiftUI
import AppKit

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xff) / 255,
                  green: Double((hex >> 8) & 0xff) / 255,
                  blue: Double(hex & 0xff) / 255)
    }
}

/// Fixed palette from the design brief. Lime is only for progress and wins.
enum C {
    static let bg = Color(hex: 0x000000)
    static let tile = Color(hex: 0x0c0c0c)
    static let border = Color(hex: 0x262626)
    static let borderHover = Color(hex: 0x4a4a4a)
    static let line = Color(hex: 0x1f1f1f)
    static let text = Color(hex: 0xededed)
    static let text2 = Color(hex: 0x888888)
    static let muted = Color(hex: 0x5e5e5e)
    static let lime = Color(hex: 0xc6ff3d)
    static let onLime = Color(hex: 0x1a2400)
    static let ok = Color(hex: 0x3fb950)
    static let warn = Color(hex: 0xf5a623)
}

/// The switchable secondary accent. Only these five values change between themes.
struct Accent: Identifiable, Equatable {
    let id: String
    let surface, border, soft, accent, fill: Color

    static let all: [Accent] = [
        Accent(id: "Deep teal", surface: Color(hex: 0x071a1a), border: Color(hex: 0x12302f), soft: Color(hex: 0x7fb3ab), accent: Color(hex: 0x4fc9b8), fill: Color(hex: 0x0c2524)),
        Accent(id: "Midnight", surface: Color(hex: 0x0a1022), border: Color(hex: 0x18213d), soft: Color(hex: 0x8796c4), accent: Color(hex: 0x6f86d6), fill: Color(hex: 0x111a33)),
        Accent(id: "Moss", surface: Color(hex: 0x0f1309), border: Color(hex: 0x222b12), soft: Color(hex: 0x9aa874), accent: Color(hex: 0xa8c95a), fill: Color(hex: 0x171e0c)),
        Accent(id: "Graphite", surface: Color(hex: 0x151515), border: Color(hex: 0x2b2b2b), soft: Color(hex: 0xa3a3a3), accent: Color(hex: 0xd4d4d4), fill: Color(hex: 0x1e1e1e)),
        Accent(id: "Plum", surface: Color(hex: 0x140e1c), border: Color(hex: 0x2a1e38), soft: Color(hex: 0xae9bc8), accent: Color(hex: 0xb08cf5), fill: Color(hex: 0x1d1428)),
    ]

    static func named(_ id: String) -> Accent { all.first { $0.id == id } ?? all[0] }
}

private struct AccentKey: EnvironmentKey { static let defaultValue = Accent.all[0] }
extension EnvironmentValues {
    var accent: Accent {
        get { self[AccentKey.self] }
        set { self[AccentKey.self] = newValue }
    }
}

/// Inter / JetBrains Mono when installed, otherwise the system equivalents. Only weights 400 and 500.
enum F {
    private static let hasInter = NSFont(name: "Inter", size: 12) != nil
    private static let hasMono = NSFont(name: "JetBrains Mono", size: 12) != nil

    static func ui(_ size: CGFloat, medium: Bool = false) -> Font {
        let base: Font = hasInter ? .custom("Inter", size: size) : .system(size: size)
        return base.weight(medium ? .medium : .regular)
    }

    static func mono(_ size: CGFloat) -> Font {
        hasMono ? .custom("JetBrains Mono", size: size) : .system(size: size, design: .monospaced)
    }

    static let big = ui(32, medium: true)
    static let label = ui(12)
    static let body = ui(13)
}
