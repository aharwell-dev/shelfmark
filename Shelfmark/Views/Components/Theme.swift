import SwiftUI

/// Shelfmark's graphic language: near-black ground, a single signal orange for "here it is",
/// heavy condensed headings, and monospaced shelf addresses and call numbers.
enum Theme {
    static let ground = Color(red: 0.055, green: 0.055, blue: 0.063)
    static let panel = Color(red: 0.11, green: 0.11, blue: 0.125)
    static let panelRaised = Color(red: 0.16, green: 0.16, blue: 0.18)
    static let line = Color.white.opacity(0.12)
    static let signal = Color(red: 1.0, green: 0.353, blue: 0.122)     // #FF5A1F
    static let signalSoft = signal.opacity(0.18)
    static let ink = Color.white
    static let inkMuted = Color.white.opacity(0.6)
    static let wood = Color(red: 0.23, green: 0.20, blue: 0.17)

    static func display(_ size: CGFloat) -> Font { .system(size: size, weight: .black, design: .default).width(.condensed) }
    static func mono(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font { .system(size: size, weight: weight, design: .monospaced) }
}

extension Color {
    init(hex: String, fallback: Color = .gray) {
        if let ui = UIColor(hex: hex) { self.init(uiColor: ui) } else { self = fallback }
    }

    /// Black or white, whichever reads better on this color.
    static func readable(onHex hex: String) -> Color {
        guard let ui = UIColor(hex: hex) else { return .white }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        return (0.299 * r + 0.587 * g + 0.114 * b) > 0.6 ? .black : .white
    }
}

/// The shelf address rendered as a bold tag: [B | 3 | 07].
struct AddressBadge: View {
    let address: String
    var large = false

    var body: some View {
        let parts = address.split(separator: "-").map(String.init)
        HStack(spacing: 0) {
            ForEach(Array(parts.enumerated()), id: \.offset) { i, p in
                Text(p)
                    .font(Theme.mono(large ? 22 : 13, weight: .bold))
                    .padding(.horizontal, large ? 12 : 7)
                    .padding(.vertical, large ? 8 : 4)
                    .background(i == 0 ? Theme.signal : Theme.panelRaised)
                    .foregroundStyle(i == 0 ? Color.black : Theme.ink)
                if i < parts.count - 1 { Rectangle().fill(Theme.ground).frame(width: 2) }
            }
        }
        .fixedSize()
        .clipShape(RoundedRectangle(cornerRadius: large ? 8 : 5))
        .accessibilityLabel("Shelf address \(address)")
    }
}

/// A miniature book spine drawn from the colors captured at scan time.
struct SpineSwatch: View {
    let colorHex: String
    let accentHex: String
    var title: String = ""
    var width: CGFloat = 26
    var height: CGFloat = 96

    var body: some View {
        let base = Color(hex: colorHex, fallback: Theme.panelRaised)
        let accent = Color(hex: accentHex, fallback: Color.readable(onHex: colorHex))
        RoundedRectangle(cornerRadius: 3)
            .fill(base.gradient)
            .overlay(alignment: .top) { Rectangle().fill(accent.opacity(0.85)).frame(height: 3).padding(.top, height * 0.12) }
            .overlay(alignment: .bottom) { Rectangle().fill(accent.opacity(0.85)).frame(height: 3).padding(.bottom, height * 0.12) }
            .overlay {
                if !title.isEmpty && width >= 18 {
                    Text(title)
                        .font(.system(size: min(width * 0.42, 12), weight: .bold))
                        .foregroundStyle(accent)
                        .lineLimit(1)
                        .fixedSize()
                        .frame(width: height * 0.7)
                        .rotationEffect(.degrees(-90))
                }
            }
            .frame(width: width, height: height)
            .shadow(color: .black.opacity(0.4), radius: 1, x: 1, y: 0)
    }
}

struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(Theme.mono(11, weight: .bold))
            .tracking(1.5)
            .foregroundStyle(Theme.inkMuted)
    }
}

struct SignalButtonStyle: ButtonStyle {
    var filled = true
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .bold))
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .background(filled ? Theme.signal : Theme.panelRaised)
            .foregroundStyle(filled ? Color.black : Theme.ink)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(duration: 0.2), value: configuration.isPressed)
    }
}
