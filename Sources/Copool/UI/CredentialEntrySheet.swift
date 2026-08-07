import SwiftUI

/// 凭据录入面板（CMP-04）。
///
/// 五种 `CredentialKind` 的输入形态完全不同，但用户面对的是同一件事——
/// "让这条通道能用起来"。所以是一个面板按 kind 切换正文，而不是五个入口：
/// 分成五个会逼用户先搞懂自己该走哪种认证，那是实现细节。
///
/// 面板**只收集输入**，不写 Keychain、不改注册表。落盘全部交给
/// `CredentialCoordinator`——SEC-01 的"写失败即中止"只有集中在一处才守得住。
struct CredentialEntrySheet: View {
    /// 界面上暴露的录入方式。`externalCLISession` 与 `subscriptionImport`
    /// 不在这里，它们走 `DisclosureConsentSheet`——那两类要先过披露门禁。
    enum Mode: String, CaseIterable, Identifiable {
        case apiKey
        case environmentReference
        case oauthDeviceFlow

        var id: String { rawValue }
        var labelKey: String { "credentials.mode.\(rawValue)" }
    }

    let providerDisplayName: String
    /// 该 provider 支持的录入方式，来自 `ProviderDefinition.credentialKinds`。
    let availableModes: [Mode]
    /// 种子里给的提示（"在 xx 控制台的 API Keys 页面创建"）。
    var credentialPrompt: String?
    /// 种子声明的候选环境变量名，用作输入框的占位与快捷填充。
    var environmentVariableCandidates: [String] = []
    /// 共用同一把凭据的其他通道名（FR-PRV-02）。非空时面板必须明示影响面：
    /// 用户以为在配置一条通道，实际同时配置了三条。
    var sharedChannelNames: [String] = []
    /// 该 provider 是否真的支持设备码流；不支持时按钮不该出现。
    var onStartDeviceFlow: (() -> Void)?
    let onSaveAPIKey: (String) -> Void
    let onBindEnvironment: (String) -> Void
    let onCancel: () -> Void

    @State private var mode: Mode
    @State private var secret = ""
    @State private var environmentName = ""
    @State private var revealSecret = false

    init(
        providerDisplayName: String,
        availableModes: [Mode],
        credentialPrompt: String? = nil,
        environmentVariableCandidates: [String] = [],
        sharedChannelNames: [String] = [],
        onStartDeviceFlow: (() -> Void)? = nil,
        onSaveAPIKey: @escaping (String) -> Void,
        onBindEnvironment: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.providerDisplayName = providerDisplayName
        self.availableModes = availableModes.isEmpty ? [.apiKey] : availableModes
        self.credentialPrompt = credentialPrompt
        self.environmentVariableCandidates = environmentVariableCandidates
        self.sharedChannelNames = sharedChannelNames
        self.onStartDeviceFlow = onStartDeviceFlow
        self.onSaveAPIKey = onSaveAPIKey
        self.onBindEnvironment = onBindEnvironment
        self.onCancel = onCancel
        _mode = State(initialValue: availableModes.first ?? .apiKey)
        _environmentName = State(initialValue: environmentVariableCandidates.first ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if availableModes.count > 1 {
                CapsuleSubTabBar(
                    selection: $mode,
                    tabs: availableModes.map { ($0, L10n.tr($0.labelKey)) }
                )
            }

            switch mode {
            case .apiKey: apiKeyForm
            case .environmentReference: environmentForm
            case .oauthDeviceFlow: deviceFlowForm
            }

            if !sharedChannelNames.isEmpty {
                sharedCredentialWarning
            }

            Spacer(minLength: 0)
            footer
        }
        .padding(18)
        .frame(width: 420)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.tr("credentials.entry.title"))
                .font(.headline)
            Text(providerDisplayName)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - API Key

    private var apiKeyForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let credentialPrompt, !credentialPrompt.isEmpty {
                Text(credentialPrompt)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                // 默认遮蔽，可临时显形。粘贴出错是最常见的失败原因，
                // 完全不给看会让用户只能靠删掉重来。
                Group {
                    if revealSecret {
                        TextField(L10n.tr("credentials.entry.api_key_placeholder"), text: $secret)
                    } else {
                        SecureField(L10n.tr("credentials.entry.api_key_placeholder"), text: $secret)
                    }
                }
                .textFieldStyle(.roundedBorder)

                Button {
                    revealSecret.toggle()
                } label: {
                    Image(systemName: revealSecret ? "eye.slash" : "eye")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel(L10n.tr(revealSecret ? "credentials.entry.hide" : "credentials.entry.reveal"))
            }

            Text(L10n.tr("credentials.entry.keychain_note"))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 环境变量（FR-IDT-03）

    private var environmentForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.tr("credentials.entry.env_explainer"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField(L10n.tr("credentials.entry.env_placeholder"), text: $environmentName)
                .textFieldStyle(.roundedBorder)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                #endif

            if !environmentVariableCandidates.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.tr("credentials.entry.env_candidates"))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    // 种子声明的候选名一键填入：手打环境变量名很容易差一个
                    // 下划线，而错了之后的症状只是"没生效"，极难自查。
                    HStack(spacing: 6) {
                        ForEach(environmentVariableCandidates.prefix(3), id: \.self) { name in
                            Button(name) { environmentName = name }
                                .buttonStyle(.frostedCapsule(prominent: false))
                                .font(.caption2)
                        }
                    }
                }
            }

            Text(L10n.tr("credentials.entry.env_note"))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 设备码流（FR-IDT-02）

    private var deviceFlowForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.tr("credentials.entry.oauth_explainer"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let onStartDeviceFlow {
                Button(L10n.tr("credentials.entry.oauth_start")) {
                    onStartDeviceFlow()
                }
                .copoolActionButtonStyle(prominent: true, tint: .indigo, density: .compact, iOSStyle: .liquidGlass)
            } else {
                Text(L10n.tr("credentials.entry.oauth_unavailable"))
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - 共用凭据影响面（FR-PRV-02）

    private var sharedCredentialWarning: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(
                L10n.tr("credentials.entry.shared_warning_format", String(sharedChannelNames.count)),
                systemImage: "link"
            )
            .font(.caption.weight(.medium))
            .foregroundStyle(.orange)

            Text(sharedChannelNames.joined(separator: " · "))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .frostedRoundedSurface(cornerRadius: 10, prominent: false, tint: .orange.opacity(0.12))
    }

    // MARK: - 底部动作

    private var footer: some View {
        HStack {
            Spacer(minLength: 0)
            Button(L10n.tr("common.cancel"), action: onCancel)
                .keyboardShortcut(.cancelAction)
            if mode != .oauthDeviceFlow {
                Button(L10n.tr("common.save"), action: save)
                    .copoolActionButtonStyle(prominent: true, tint: .indigo, density: .compact, iOSStyle: .liquidGlass)
                    .disabled(!canSave)
            }
        }
    }

    private var canSave: Bool {
        switch mode {
        case .apiKey:
            return !secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .environmentReference:
            return !environmentName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .oauthDeviceFlow:
            return false
        }
    }

    private func save() {
        switch mode {
        case .apiKey:
            onSaveAPIKey(secret.trimmingCharacters(in: .whitespacesAndNewlines))
        case .environmentReference:
            onBindEnvironment(environmentName.trimmingCharacters(in: .whitespacesAndNewlines))
        case .oauthDeviceFlow:
            break
        }
    }
}

extension CredentialEntrySheet.Mode {
    /// 只映射面板真正承载的三种；另两种走披露门禁，不在这里出现。
    init?(kind: CredentialKind) {
        switch kind {
        case .apiKey: self = .apiKey
        case .environmentReference: self = .environmentReference
        case .oauthDeviceFlow: self = .oauthDeviceFlow
        case .externalCLISession, .subscriptionImport: return nil
        }
    }

    /// 顺序固定，不随 `Set` 的遍历顺序变化——面板每次打开标签页顺序都不同
    /// 会让人以为点错了地方。
    static func modes(for kinds: Set<CredentialKind>) -> [CredentialEntrySheet.Mode] {
        CredentialEntrySheet.Mode.allCases.filter { mode in
            kinds.contains { CredentialEntrySheet.Mode(kind: $0) == mode }
        }
    }
}
