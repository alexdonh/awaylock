import SwiftUI

extension Color {
    /// Grouped-card fill from the design: white on light, a faint lift on dark.
    static let card = Color(nsColor: NSColor(name: nil) {
        $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .white.withAlphaComponent(0.06) : .white
    })
    static let accentSoft = Color.accentColor.opacity(0.2)
}

/// Rounded card holding rows separated by inset dividers.
struct Card<Content: View>: View {
    var dividerInset: CGFloat = 0
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            Group(subviews: content) { rows in
                ForEach(rows.indices, id: \.self) { i in
                    if i > 0 { Divider().padding(.leading, dividerInset) }
                    rows[i]
                }
            }
        }
        .background(Color.card, in: .rect(cornerRadius: 18))
        .clipShape(.rect(cornerRadius: 18))
    }
}

/// Glyph from the design (template asset in Icons/), sized like a symbol.
struct Icon: View {
    let name: ImageResource
    var size: CGFloat

    var body: some View {
        Image(name).resizable().scaledToFit().frame(width: size, height: size)
    }
}

/// Design glyph (Icons/ asset) for a device, from its advertised name.
func deviceIcon(for name: String) -> ImageResource {
    let n = name.lowercased()
    if n.contains("watch") { return .deviceWatch }
    if n.contains("iphone") || n.contains("ipad") { return .devicePhone }
    if n.contains("airpods") || n.contains("buds") { return .deviceEarbuds }
    if n.contains("band") { return .deviceBand }
    return .antenna
}

