import SwiftUI

// MARK: - Renk sistemi
//
// Bilinçli olarak SABİT: `Color.primary` / `Color.accentColor` gibi sistem
// varsayılanlarına güvenmek, önceki sürümde tüm panelin kullanıcının sistem
// vurgu rengine (sarı) boyanmasına yol açmıştı. Burada her renk açıkça
// tanımlı — her Mac'te aynı görünür.

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

enum Theme {
    // Zemin
    static let bgTop = Color(hex: 0x0E1116)
    static let bgBottom = Color(hex: 0x0A0C10)

    // Yüzeyler
    static let panel = Color.white.opacity(0.045)
    static let panel2 = Color.white.opacity(0.028)
    static let stroke = Color.white.opacity(0.085)
    static let stroke2 = Color.white.opacity(0.055)

    // Metin
    static let ink = Color(hex: 0xEEF2F7)
    static let ink2 = Color(hex: 0x9AA6B5)
    static let ink3 = Color(hex: 0x67727F)

    // Vurgu (tek aile: mavi → mor)
    static let accent = Color(hex: 0x4D9FFF)
    static let accent2 = Color(hex: 0x7C5CFF)
    static var accentGradient: LinearGradient {
        LinearGradient(colors: [accent, accent2],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    // Durum renkleri — başka renk kullanılmaz
    static let good = Color(hex: 0x39D98A)
    static let warn = Color(hex: 0xFFB020)
    static let bad = Color(hex: 0xFF5F57)

    // Ölçüler
    static let railWidth: CGFloat = 68
    static let topBarHeight: CGFloat = 52
    static let corner: CGFloat = 13
}

// MARK: - Tipografi

extension Font {
    /// Sayısal değerler için monospace — satır zıplamasın.
    static func metric(_ size: CGFloat = 12, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
    /// Bölüm etiketi: küçük, seyrek, büyük harf.
    static var moduleLabel: Font { .system(size: 9.5, weight: .semibold) }
    static var cardTitle: Font { .system(size: 16.5, weight: .semibold) }
}

// MARK: - Modül kutusu (kumanda güvertesindeki her grup)

struct ModuleBox<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title.uppercased())
                .font(.moduleLabel)
                .kerning(0.85)
                .foregroundStyle(Theme.ink3)
            content
        }
        .padding(11)
        .background(
            RoundedRectangle(cornerRadius: Theme.corner)
                .fill(Theme.panel2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.corner)
                .strokeBorder(Theme.stroke2, lineWidth: 1)
        )
    }
}

// MARK: - Dokunsal tuş
//
// Alt kenardan iç gölge + üstten parlaklık = "basılabilir" hissi. Amaç
// yanlış basmayı azaltmak, gözle daha hızlı taramak.

struct TactileKey: View {
    let icon: String
    var subtitle: String? = nil
    var prominent: Bool = false
    var wide: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(Theme.ink3)
                }
            }
            .frame(minWidth: wide ? 52 : 34, minHeight: 34)
            .padding(.horizontal, 9)
            .foregroundStyle(prominent ? Color(hex: 0xDCEAFF) : Theme.ink)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(prominent
                          ? AnyShapeStyle(Theme.accent.opacity(0.22))
                          : AnyShapeStyle(
                                LinearGradient(
                                    colors: [Color.white.opacity(0.085),
                                             Color.white.opacity(0.038)],
                                    startPoint: .top, endPoint: .bottom)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(prominent
                                  ? Theme.accent.opacity(0.42)
                                  : Theme.stroke, lineWidth: 1)
            )
            .overlay(
                // Üst iç parlaklık
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
                    .blendMode(.plusLighter)
                    .allowsHitTesting(false)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Rozet (durum pill'i)

struct Pill: View {
    enum Kind { case live, neutral, warn, bad, good }
    let kind: Kind
    let text: String

    private var fill: Color {
        switch kind {
        case .live, .good: return Theme.good.opacity(0.15)
        case .neutral: return Theme.panel
        case .warn: return Theme.warn.opacity(0.15)
        case .bad: return Theme.bad.opacity(0.16)
        }
    }
    private var ink: Color {
        switch kind {
        case .live, .good: return Theme.good
        case .neutral: return Theme.ink2
        case .warn: return Theme.warn
        case .bad: return Theme.bad
        }
    }

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .kerning(0.2)
            .foregroundStyle(ink)
            .padding(.horizontal, 9)
            .frame(height: 23)
            .background(Capsule().fill(fill))
            .overlay(Capsule().strokeBorder(ink.opacity(0.28), lineWidth: 1))
    }
}

// MARK: - İnce düğme (başlık satırındaki ikincil eylemler)

struct GhostButton: View {
    let icon: String
    let title: String
    var prominent: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 11.5, weight: .medium))
                Text(title).font(.system(size: 12, weight: .medium))
            }
            .padding(.horizontal, 11)
            .frame(height: 29)
            .foregroundStyle(prominent ? Color(hex: 0xB9D8FF) : Theme.ink2)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(prominent ? Theme.accent.opacity(0.18) : Theme.panel))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(prominent ? Theme.accent.opacity(0.36) : Theme.stroke,
                                  lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Değer göstergesi (telemetri için)

struct Metric: View {
    let label: String
    let value: String
    var detail: String? = nil
    var tone: Color = Theme.ink

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label.uppercased())
                .font(.system(size: 8.5, weight: .semibold))
                .kerning(0.7)
                .foregroundStyle(Theme.ink3)
            Text(value)
                .font(.metric(12.5))
                .foregroundStyle(tone)
            if let detail {
                Text(detail)
                    .font(.system(size: 9.5))
                    .foregroundStyle(Theme.ink3)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Zemin

struct StudioBackground: View {
    var body: some View {
        LinearGradient(colors: [Theme.bgTop, Theme.bgBottom],
                       startPoint: .top, endPoint: .bottom)
    }
}
