import SwiftUI

// iOS-only SwiftUI modifiers wrapped so the view layer can also be typechecked against
// the macOS SDK (no iOS SDK available before Xcode is installed). On iOS these are the
// real modifiers; on macOS they are no-ops or nearest equivalents.

enum DealKeyboard { case decimal, number, plain }

extension View {
    @ViewBuilder
    func dealInlineTitle() -> some View {
        #if os(iOS)
        self.navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }

    @ViewBuilder
    func dealKeyboard(_ kind: DealKeyboard) -> some View {
        #if os(iOS)
        switch kind {
        case .decimal: self.keyboardType(.decimalPad)
        case .number: self.keyboardType(.numberPad)
        case .plain: self.keyboardType(.default)
        }
        #else
        self
        #endif
    }

    @ViewBuilder
    func dealCodeEntry() -> some View {
        #if os(iOS)
        self.textInputAutocapitalization(.characters).autocorrectionDisabled()
        #else
        self.autocorrectionDisabled()
        #endif
    }

    @ViewBuilder
    func dealURLEntry() -> some View {
        #if os(iOS)
        self.textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
        #else
        self.autocorrectionDisabled()
        #endif
    }

    @ViewBuilder
    func dealFullScreenCover<Item: Identifiable, Content: View>(
        item: Binding<Item?>, @ViewBuilder content: @escaping (Item) -> Content
    ) -> some View {
        #if os(iOS)
        self.fullScreenCover(item: item, content: content)
        #else
        self.sheet(item: item, content: content)
        #endif
    }

    @ViewBuilder
    func dealFullScreenCover<Content: View>(
        isPresented: Binding<Bool>, @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        #if os(iOS)
        self.fullScreenCover(isPresented: isPresented, content: content)
        #else
        self.sheet(isPresented: isPresented, content: content)
        #endif
    }

    /// Keeps the screen awake while a negotiation / teleprompter is on screen.
    func dealKeepAwake(_ on: Bool = true) -> some View {
        self.onAppear { Platform.setIdleTimerDisabled(on) }
            .onDisappear { Platform.setIdleTimerDisabled(false) }
    }
}

enum Platform {
    @MainActor
    static func setIdleTimerDisabled(_ disabled: Bool) {
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = disabled
        #endif
    }

    @MainActor
    static func haptic(_ kind: HapticKind) {
        #if os(iOS)
        switch kind {
        case .success: UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .warning: UINotificationFeedbackGenerator().notificationOccurred(.warning)
        case .error: UINotificationFeedbackGenerator().notificationOccurred(.error)
        case .tap: UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
        #endif
    }

    enum HapticKind { case success, warning, error, tap }
}

extension ToolbarItemPlacement {
    static var dealTrailing: ToolbarItemPlacement {
        #if os(iOS)
        .topBarTrailing
        #else
        .automatic
        #endif
    }

    static var dealLeading: ToolbarItemPlacement {
        #if os(iOS)
        .topBarLeading
        #else
        .automatic
        #endif
    }
}
