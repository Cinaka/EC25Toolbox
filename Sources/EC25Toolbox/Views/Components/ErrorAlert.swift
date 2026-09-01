import SwiftUI

/// Presents a localized error alert while the bound message is non-nil.
/// macOS 27 drives presentation from the optional itself (item-based alert);
/// the macOS 26 fallback synthesizes the Bool form from the same state.
private struct ErrorAlertModifier: ViewModifier {
    @Binding var message: String?

    func body(content: Content) -> some View {
        Group {
            if #available(macOS 27, *) {
                content.alert(
                    localized("common.error"),
                    item: $message
                ) { _ in
                    Button(localized("common.ok")) { message = nil }
                } message: { text in
                    Text(text)
                }
            } else {
                content.alert(
                    localized("common.error"),
                    isPresented: Binding(
                        get: { message != nil },
                        set: { if !$0 { message = nil } }
                    )
                ) {
                    Button(localized("common.ok")) { message = nil }
                } message: {
                    Text(message ?? "")
                }
            }
        }
    }
}

extension View {
    /// Presents a localized error alert while the bound message is non-nil.
    /// Cancellation is handled by the caller (never setting the message).
    func errorAlert(message: Binding<String?>) -> some View {
        modifier(ErrorAlertModifier(message: message))
    }
}
