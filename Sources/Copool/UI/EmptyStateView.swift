import SwiftUI

struct EmptyStateView: View {
    let title: String
    let message: String
    // B1-3: optional trailing action. Rendered only when both are non-nil so
    // existing call sites (title + message only) are unaffected.
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 10) {
            Text(title)
                .font(.title3.weight(.semibold))
            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .copoolActionButtonStyle(prominent: true, density: .regular, iOSStyle: .liquidGlass)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 180)
        .padding()
    }
}
