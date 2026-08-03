import Foundation

enum AppTab: String, CaseIterable, Identifiable {
    case accounts
    case proxy
    case providers
    case settings

    var id: String { rawValue }
}

enum EditorAppID: String, Codable, CaseIterable, Identifiable {
    case vscode
    case vscodeInsiders
    case cursor
    case antigravity
    case kiro
    case trae
    case qoder

    var id: String { rawValue }
}

struct InstalledEditorApp: Equatable, Identifiable {
    var id: EditorAppID
    var label: String
}

struct SwitchAccountExecutionResult: Equatable {
    var didLaunchChatGPTApp: Bool
    var chatGPTLaunchError: String?
    var opencodeSynced: Bool
    var opencodeSyncError: String?
    var restartedEditorApps: [EditorAppID]
    var editorRestartError: String?

    static let idle = SwitchAccountExecutionResult(
        didLaunchChatGPTApp: false,
        chatGPTLaunchError: nil,
        opencodeSynced: false,
        opencodeSyncError: nil,
        restartedEditorApps: [],
        editorRestartError: nil
    )
}
