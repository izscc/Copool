import Foundation

/// Agents tab secondary navigation (vNext UI structure):
/// Profiles / Sessions / Tools / Live.
enum AgentSubTab: String, CaseIterable, Identifiable, Sendable {
    case profiles
    case sessions
    case tools
    case live

    var id: String { rawValue }

    var label: String {
        switch self {
        case .profiles: return L10n.tr("agents.subtab.profiles")
        case .sessions: return L10n.tr("agents.subtab.sessions")
        case .tools: return L10n.tr("agents.subtab.tools")
        case .live: return L10n.tr("agents.subtab.live")
        }
    }
}
