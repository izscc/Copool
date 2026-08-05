import Foundation

/// Runtime tab secondary navigation (vNext UI structure):
/// Overview / Targets / Remote / Public / Logs.
enum ProxySubTab: String, CaseIterable, Identifiable, Sendable {
    case overview
    case targets
    case remote
    case publicAccess
    case logs

    var id: String { rawValue }

    var label: String {
        switch self {
        case .overview: return L10n.tr("proxy.subtab.overview")
        case .targets: return L10n.tr("proxy.subtab.targets")
        case .remote: return L10n.tr("proxy.subtab.remote")
        case .publicAccess: return L10n.tr("proxy.subtab.public")
        case .logs: return L10n.tr("proxy.subtab.logs")
        }
    }
}

/// Lightweight view-model for one target binding (AC-008): derived from the
/// provider store + v2 registry; never carries secret values.
struct ProxyTargetSnapshot: Identifiable, Equatable, Sendable {
    /// Stable v1-inherited UUID (AC-005) — never the displayName.
    let id: String
    let name: String
    let endpoint: String
    let dialect: String
    let modelCount: Int
    /// Whether a credential reference/keychain entry is available.
    let credentialed: Bool
    let enabled: Bool
}
