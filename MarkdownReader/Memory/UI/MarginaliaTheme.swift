import SwiftUI

enum MarginaliaAppearance: Equatable, Sendable {
    case automatic
    case light
    case dark
    case sepia
}

private struct MarginaliaAppearanceKey: EnvironmentKey {
    static let defaultValue: MarginaliaAppearance = .automatic
}

extension EnvironmentValues {
    var marginaliaAppearance: MarginaliaAppearance {
        get { self[MarginaliaAppearanceKey.self] }
        set { self[MarginaliaAppearanceKey.self] = newValue }
    }
}

extension View {
    func marginaliaAppearance(_ appearance: MarginaliaAppearance) -> some View {
        environment(\.marginaliaAppearance, appearance)
    }
}

struct MarginaliaPalette: Equatable {
    let paper: Color
    let sidebar: Color
    let ink: Color
    let secondaryInk: Color
    let metadataInk: Color
    let accent: Color
    let accentLabel: Color
    let selectedFill: Color
    let hairline: Color

    static func resolve(
        appearance: MarginaliaAppearance,
        systemColorScheme: ColorScheme,
        increasedContrast: Bool
    ) -> MarginaliaPalette {
        let resolvedAppearance: MarginaliaAppearance = appearance == .automatic
            ? (systemColorScheme == .dark ? .dark : .light)
            : appearance

        let base: MarginaliaPalette
        switch resolvedAppearance {
        case .automatic, .light:
            base = MarginaliaPalette(
                paper: Color(hex: 0xFDFAF4),
                sidebar: Color(hex: 0xF4EFE5),
                ink: Color(hex: 0x221E1A),
                secondaryInk: Color(hex: 0x433D34),
                metadataInk: Color(hex: 0x6B6459),
                accent: Color(hex: 0x97402F),
                accentLabel: Color(hex: 0x8A3A2A),
                selectedFill: Color(hex: 0xFBF4EA),
                hairline: Color(hex: 0x221E1A).opacity(0.12)
            )
        case .sepia:
            base = MarginaliaPalette(
                paper: Color(hex: 0xF3E7D2),
                sidebar: Color(hex: 0xEADCC1),
                ink: Color(hex: 0x33291B),
                secondaryInk: Color(hex: 0x56472F),
                metadataInk: Color(hex: 0x7A6A50),
                accent: Color(hex: 0x96422A),
                accentLabel: Color(hex: 0x8A3C24),
                selectedFill: Color(hex: 0xEFE0C8),
                hairline: Color(hex: 0x33291B).opacity(0.14)
            )
        case .dark:
            base = MarginaliaPalette(
                paper: Color(hex: 0x201D1A),
                sidebar: Color(hex: 0x2A2622),
                ink: Color(hex: 0xE9E2D6),
                secondaryInk: Color(hex: 0xC4BCAF),
                metadataInk: Color(hex: 0x9A9184),
                accent: Color(hex: 0xE08A6C),
                accentLabel: Color(hex: 0xEFA184),
                selectedFill: Color(hex: 0x302824),
                hairline: Color.white.opacity(0.10)
            )
        }

        guard increasedContrast else { return base }

        if resolvedAppearance == .dark {
            return MarginaliaPalette(
                paper: base.paper,
                sidebar: base.sidebar,
                ink: Color(hex: 0xFFFDF8),
                secondaryInk: Color(hex: 0xF2ECE2),
                metadataInk: Color(hex: 0xD6CEC2),
                accent: Color(hex: 0xFFB091),
                accentLabel: Color(hex: 0xFFC1A8),
                selectedFill: base.selectedFill,
                hairline: Color.white.opacity(0.72)
            )
        }

        return MarginaliaPalette(
            paper: base.paper,
            sidebar: base.sidebar,
            ink: .black,
            secondaryInk: Color(hex: 0x211A15),
            metadataInk: Color(hex: 0x3F352D),
            accent: Color(hex: 0x7A2A18),
            accentLabel: Color(hex: 0x6E2313),
            selectedFill: base.selectedFill,
            hairline: .black
        )
    }
}

private extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}
