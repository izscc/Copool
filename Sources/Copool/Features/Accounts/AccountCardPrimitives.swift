import SwiftUI

private enum AccountCardOverlayLayout {
    static let actionReservationWidth = LayoutRules.accountCardActionReservationWidth
    static let compactActionControlHeight = LayoutRules.compactActionControlHeight
}

enum AccountCardMorphRules {
    static let response = 0.34
    static let dampingFraction = 0.84
    static let titleExpansionProgress = 0.68
    static let animation = Animation.spring(response: response, dampingFraction: dampingFraction)
    static let contentAnimation = Animation.easeInOut(duration: 0.12)

    static var titleExpansionDelay: Duration {
        .seconds(response * titleExpansionProgress)
    }
}

enum AccountCardSwitchButtonLabelStyle {
    case iconOnly
    case expanded
}

struct AccountCardPalette {
    let toneColor: Color
    let surfaceTint: Color?
    let selectionBorderAccent: AccountCardAccent?

    init(accent: AccountCardAccent, isCurrent: Bool) {
        toneColor = Self.color(for: accent)
        selectionBorderAccent = isCurrent ? accent : nil
        surfaceTint = selectionBorderAccent.map { Self.color(for: $0).opacity(0.14) }
    }

    var selectionBorderColor: Color? {
        selectionBorderAccent.map { Self.color(for: $0).opacity(0.45) }
    }

    private static func color(for accent: AccountCardAccent) -> Color {
        switch accent {
        case .orange:
            .orange
        case .pink:
            .pink
        case .gray:
            .gray
        case .indigo:
            .indigo
        case .teal:
            .teal
        }
    }
}

private struct AccountCardSurfaceModifier: ViewModifier {
    let cornerRadius: CGFloat
    let tint: Color?

    func body(content: Content) -> some View {
        content.cardSurface(cornerRadius: cornerRadius, tint: tint)
    }
}

extension View {
    func accountCardSurface(
        cornerRadius: CGFloat = LayoutRules.accountCardRadius,
        tint: Color? = nil
    ) -> some View {
        modifier(AccountCardSurfaceModifier(cornerRadius: cornerRadius, tint: tint))
    }
}

struct AccountCardHeaderSection: View {
    let presentation: AccountCardPresentation
    let isCollapsed: Bool
    let isCurrent: Bool
    let palette: AccountCardPalette
    let onDelete: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: LayoutRules.accountCardItemSpacing) {
                HStack(spacing: LayoutRules.accountCardItemSpacing) {
                    AccountTagView(
                        text: presentation.planLabel,
                        backgroundColor: palette.toneColor.opacity(0.18),
                        foregroundColor: palette.toneColor
                    )
                    if let teamNameTag = presentation.teamNameTag {
                        AccountTagView(
                            text: teamNameTag,
                            backgroundColor: palette.toneColor.opacity(0.18),
                            foregroundColor: palette.toneColor,
                            allowsCompression: true
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let statusLabel = presentation.statusLabel {
                        AccountTagView(
                            text: statusLabel,
                            backgroundColor: Color.red.opacity(0.16),
                            foregroundColor: .red
                        )
                    }
                    Spacer(minLength: 0)
                }
            }

            if !isCollapsed {
                AccountDeleteButton(action: onDelete)
            }
        }
    }
}

struct AccountDeleteButton: View {
    let action: () -> Void
    var isDisabled: Bool = false

    var body: some View {
        Button(role: .destructive, action: action) {
            Image(systemName: "trash")
        }
        .copoolActionButtonStyle(
            prominent: true,
            tint: .red,
            density: .compact,
            iOSStyle: .liquidGlass
        )
        .tint(.red)
        .disabled(isDisabled)
    }
}

struct AccountCardExpandedUsageSection: View {
    let presentation: AccountCardPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: LayoutRules.accountCardContentSpacing) {
            AccountWindowSection(presentation: presentation.oneWeekWindow, tint: .teal)

            HStack(spacing: LayoutRules.accountCardContentSpacing) {
                Text(L10n.tr("accounts.card.credits_format", presentation.creditsText))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.trailing, AccountCardOverlayLayout.actionReservationWidth)
                Spacer(minLength: 0)
            }
        }
    }
}

struct AccountCardCompactUsageSection: View {
    let presentation: AccountCardPresentation

    var body: some View {
        AccountCompactUsageRow(
            rings: [
                AccountCompactRingDescriptor(
                    id: "one-week",
                    valueText: compactPercentText(presentation.compactUsage.oneWeekDisplayPercent),
                    subtitleText: L10n.tr("accounts.window.one_week"),
                    progress: compactProgress(presentation.compactUsage.oneWeekDisplayPercent),
                    tint: .teal
                ),
            ]
        )
    }

    private func compactProgress(_ usedPercent: Double?) -> Double {
        guard let usedPercent else { return 0 }
        return max(0, min(1, usedPercent / 100))
    }

    private func compactPercentText(_ usedPercent: Double?) -> String {
        guard let usedPercent else { return "--" }
        return "\(Int(usedPercent.rounded()))%"
    }
}

struct AccountCardBottomOverlay: View {
    let isCollapsed: Bool
    let isCurrent: Bool
    let switching: Bool
    let refreshing: Bool
    let showsRefreshButton: Bool
    let showsReauthenticateButton: Bool
    let isRefreshEnabled: Bool
    let usageError: String?
    let palette: AccountCardPalette
    let onSwitch: () -> Void
    let onRefresh: () -> Void
    let onReauthenticate: () -> Void

    var body: some View {
        if !isCollapsed {
            HStack(alignment: .bottom, spacing: LayoutRules.listRowSpacing) {
                if let usageError, !usageError.isEmpty {
                    AccountUsageErrorOverlay(text: usageError)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Spacer(minLength: 0)
                }

                AccountTrailingActionCluster(
                    isCurrent: isCurrent,
                    switching: switching,
                    refreshing: refreshing,
                    showsRefreshButton: showsRefreshButton,
                    showsReauthenticateButton: showsReauthenticateButton,
                    isRefreshEnabled: isRefreshEnabled,
                    palette: palette,
                    onSwitch: onSwitch,
                    onRefresh: onRefresh,
                    onReauthenticate: onReauthenticate
                )
            }
            .padding(LayoutRules.accountCardContentSpacing)
        }
    }
}

struct AccountCollapsedSwitchOverlay: View {
    let isVisible: Bool
    let switching: Bool
    let onDismiss: () -> Void
    let onSwitch: () -> Void

    var body: some View {
        if isVisible {
            ZStack {
                RoundedRectangle(cornerRadius: LayoutRules.accountCardRadius, style: .continuous)
                    .fill(.regularMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: LayoutRules.accountCardRadius, style: .continuous)
                            .strokeBorder(Color.secondary.opacity(0.22), lineWidth: 1)
                    }
                    .onTapGesture {
                        onDismiss()
                    }

                AccountSwitchButton(
                    switching: switching,
                    labelStyle: .expanded,
                    onSwitch: onSwitch
                )
            }
            .transition(.opacity)
        }
    }
}

private struct AccountWindowSection: View {
    let presentation: AccountWindowPresentation
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: LayoutRules.accountCardTightSpacing) {
            HStack {
                Text(presentation.title)
                    .font(.caption.weight(.semibold))
                if let resetCountText = presentation.resetCountText {
                    AccountTagView(
                        text: resetCountText,
                        backgroundColor: Color.orange.opacity(0.16),
                        foregroundColor: .orange
                    )
                }
                Spacer(minLength: 0)
                Text(presentation.primaryText)
                    .font(.caption.weight(.semibold))
                Text(presentation.secondaryText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            LiquidProgressBar(progress: presentation.progressPercent / 100, tint: tint)

            Text(presentation.resetText)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

private struct AccountSwitchButton: View {
    let switching: Bool
    let labelStyle: AccountCardSwitchButtonLabelStyle
    let onSwitch: () -> Void

    var body: some View {
        Button {
            onSwitch()
        } label: {
            if switching {
                ProgressView()
                    .controlSize(.small)
            } else {
                switch labelStyle {
                case .iconOnly:
                    Image(systemName: "arrow.left.arrow.right.circle.fill")
                        .font(.system(size: 14, weight: .semibold))
                case .expanded:
                    Label(L10n.tr("accounts.card.switch_to_this"), systemImage: "arrow.left.arrow.right.circle.fill")
                        .lineLimit(1)
                }
            }
        }
        .copoolActionButtonStyle(
            prominent: true,
            tint: .mint,
            density: .compact,
            iOSStyle: .liquidGlass
        )
        .disabled(switching)
        .accessibilityLabel(Text(L10n.tr("accounts.card.switch_to_this")))
    }
}

private struct AccountRefreshButton: View {
    let refreshing: Bool
    let isEnabled: Bool
    let onRefresh: () -> Void

    var body: some View {
        Button {
            onRefresh()
        } label: {
            if refreshing {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 14, weight: .semibold))
            }
        }
        .copoolActionButtonStyle(
            prominent: true,
            tint: .teal,
            density: .compact,
            iOSStyle: .liquidGlass
        )
        .disabled(!isEnabled)
        .accessibilityLabel(Text(L10n.tr("common.refresh_usage")))
    }
}

private struct AccountReauthenticateButton: View {
    let onReauthenticate: () -> Void

    var body: some View {
        Button {
            onReauthenticate()
        } label: {
            Label(L10n.tr("accounts.card.sign_in_again"), systemImage: "person.crop.circle.badge.exclamationmark")
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .copoolActionButtonStyle(
            prominent: true,
            tint: .orange,
            density: .compact,
            iOSStyle: .liquidGlass
        )
        .accessibilityLabel(Text(L10n.tr("accounts.card.sign_in_again")))
    }
}

private struct AccountTrailingActionCluster: View {
    let isCurrent: Bool
    let switching: Bool
    let refreshing: Bool
    let showsRefreshButton: Bool
    let showsReauthenticateButton: Bool
    let isRefreshEnabled: Bool
    let palette: AccountCardPalette
    let onSwitch: () -> Void
    let onRefresh: () -> Void
    let onReauthenticate: () -> Void

    var body: some View {
        if showsReauthenticateButton {
            AccountReauthenticateButton(onReauthenticate: onReauthenticate)
        } else {
            HStack(spacing: LayoutRules.accountCardContentSpacing) {
                if isCurrent {
                    AccountTagView(
                        text: L10n.tr("accounts.card.current"),
                        backgroundColor: palette.toneColor.opacity(0.24),
                        foregroundColor: palette.toneColor
                    )
                    .frame(height: AccountCardOverlayLayout.compactActionControlHeight, alignment: .bottom)
                } else {
                    AccountSwitchButton(
                        switching: switching,
                        labelStyle: .iconOnly,
                        onSwitch: onSwitch
                    )
                }

                if showsRefreshButton {
                    AccountRefreshButton(
                        refreshing: refreshing,
                        isEnabled: isRefreshEnabled,
                        onRefresh: onRefresh
                    )
                }
            }
        }
    }
}

private struct AccountUsageErrorOverlay: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(.red)
            .multilineTextAlignment(.leading)
            .lineLimit(3)
            .padding(.horizontal, LayoutRules.accountCardChipHorizontalPadding)
            .padding(.vertical, LayoutRules.accountCardChipVerticalPadding)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: LayoutRules.accountCardCompactRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: LayoutRules.accountCardCompactRadius, style: .continuous)
                    .strokeBorder(.red.opacity(0.18), lineWidth: 1)
            }
    }
}
