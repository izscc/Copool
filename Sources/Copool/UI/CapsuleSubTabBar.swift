import SwiftUI

/// Width-safe segmented control for the fixed 532pt menu-bar panel.
///
/// A native `Picker(.segmented)` sizes each segment from its label's
/// intrinsic width; five labels can exceed the 500pt content area and push
/// the whole page wider than the fixed window, clipping the text. This
/// capsule bar instead distributes the available width evenly and scales
/// each label down (`minimumScaleFactor`) so it never truncates.
struct CapsuleSubTabBar<Value: Hashable>: View {
    @Binding var selection: Value
    let tabs: [(value: Value, label: String)]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(tabs, id: \.value) { tab in
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        selection = tab.value
                    }
                } label: {
                    Text(tab.label)
                        .font(.caption2.weight(selection == tab.value ? .semibold : .regular))
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                        .frame(maxWidth: .infinity, minHeight: 22)
                        .padding(.vertical, 3)
                        .padding(.horizontal, 2)
                        .contentShape(Rectangle())
                        .background {
                            if selection == tab.value {
                                Capsule()
                                    .fill(Color.accentColor.opacity(0.16))
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == tab.value ? .isSelected : [])
            }
        }
        .padding(3)
        .background {
            Capsule()
                .fill(Color.primary.opacity(0.05))
        }
        .overlay {
            Capsule()
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }
}
