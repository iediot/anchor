import SwiftUI

enum PanelStyle {
    static let previewRadius: CGFloat = 7
    static let controlRadius: CGFloat = 7
    static let actionHeight: CGFloat = 26
    static let actionInset: CGFloat = 8
    static let label = Font.system(size: 11)
}

struct PanelSurface: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(.ultraThinMaterial)
    }
}

struct PanelActionStyle: ButtonStyle {
    var prominent = false
    // a bar control wants less around it than one in a column of its own
    var height = PanelStyle.actionHeight
    var inset = PanelStyle.actionInset
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: prominent ? .medium : .regular))
            .padding(.horizontal, inset)
            .frame(height: height)
            .foregroundStyle(.primary)
            .background {
                RoundedRectangle(cornerRadius: PanelStyle.controlRadius, style: .continuous)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.16 : (prominent ? 0.10 : 0.045)))
            }
            .opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
            .contentShape(RoundedRectangle(cornerRadius: PanelStyle.controlRadius))
    }
}
