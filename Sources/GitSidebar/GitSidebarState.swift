import SwiftUI

/// Observable state for the git sidebar panel. One instance per window.
/// Mirrors the `SidebarState` pattern used for the left workspace sidebar.
@MainActor
final class GitSidebarState: ObservableObject {
    @Published var isVisible: Bool
    @Published var persistedWidth: CGFloat

    static let defaultWidth: CGFloat = 250
    static let minimumWidth: CGFloat = 180
    static let maximumWidth: CGFloat = 600

    init(isVisible: Bool = false, persistedWidth: CGFloat = 250) {
        self.isVisible = isVisible
        self.persistedWidth = Self.sanitizedWidth(persistedWidth)
    }

    func toggle() {
        isVisible.toggle()
    }

    static func sanitizedWidth(_ candidate: CGFloat) -> CGFloat {
        min(max(candidate, minimumWidth), maximumWidth)
    }
}
