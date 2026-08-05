import Foundation

/// Settings tab secondary navigation (vNext UI structure):
/// General / Security / Diagnostics / Advanced.
enum SettingsSubTab: String, CaseIterable, Identifiable, Sendable {
    case general
    case security
    case diagnostics
    case advanced

    var id: String { rawValue }

    var label: String {
        switch self {
        case .general: return L10n.tr("settings.subtab.general")
        case .security: return L10n.tr("settings.subtab.security")
        case .diagnostics: return L10n.tr("settings.subtab.diagnostics")
        case .advanced: return L10n.tr("settings.subtab.advanced")
        }
    }
}
