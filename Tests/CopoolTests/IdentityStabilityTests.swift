import XCTest
@testable import Copool

/// TST-03：id 与 displayName 完全解耦（AC-005、INV-2）。
///
/// 路由、目标应用配置、Keychain 账号名都以 id 为键。只要改个显示名就会
/// 换 id，用户重命名一次就会导致路由断掉、配置块指向不存在的 provider，
/// 而现场看起来只是"改了个名字"。这类回归靠人眼 review 抓不住，
/// 只能靠测试钉住。
final class IdentityStabilityTests: XCTestCase {

    private let renamed = "彻底不同的显示名 ✦ Renamed"

    // MARK: - ProviderDefinition

    func testProviderDefinitionIDSurvivesRename() {
        var definition = ProviderDefinition(
            id: "deepseek",
            displayName: "DeepSeek API",
            ownership: "deepseek",
            supportedProtocols: [.chat],
            defaultBaseURL: "https://api.deepseek.com",
            credentialKinds: [.apiKey],
            isBuiltIn: true
        )
        let originalID = definition.id

        definition.displayName = renamed

        XCTAssertEqual(definition.id, originalID, "改 displayName 不得改变 definition id")
        XCTAssertEqual(definition.id, "deepseek")
    }

    // MARK: - ProviderInstance

    func testProviderInstanceIDSurvivesRename() {
        var instance = ProviderInstance(
            id: "3F2504E0-4F89-11D3-9A0C-0305E82C3301",
            definitionID: "deepseek",
            displayName: "我的 DeepSeek",
            endpoint: "https://api.deepseek.com",
            credentialID: "cred-1",
            protocolBindings: ["chat": .chat],
            defaultProtocol: .chat,
            enabled: true,
            addedAt: 1_700_000_000
        )
        let originalID = instance.id

        instance.displayName = renamed

        XCTAssertEqual(instance.id, originalID, "改 displayName 不得改变 instance id")
        XCTAssertEqual(instance.id, "3F2504E0-4F89-11D3-9A0C-0305E82C3301", "v1 继承来的 UUID 必须原样保留")
    }

    /// definitionID 是实例挂靠的 provider。它跟着显示名走同样是灾难，
    /// 只是表现为"这个实例突然不属于任何 provider 了"。
    func testProviderInstanceDefinitionLinkSurvivesRename() {
        var instance = ProviderInstance(
            id: "instance-1",
            definitionID: "deepseek",
            displayName: "我的 DeepSeek",
            endpoint: "https://api.deepseek.com",
            credentialID: "cred-1",
            protocolBindings: ["chat": .chat],
            defaultProtocol: .chat,
            enabled: true,
            addedAt: 1_700_000_000
        )

        instance.displayName = renamed

        XCTAssertEqual(instance.definitionID, "deepseek")
        XCTAssertEqual(instance.credentialID, "cred-1", "改名不得动凭据绑定")
    }

    // MARK: - CredentialIdentity

    /// 凭据没有 displayName，但它的 id 与 Keychain 账号名是两件事——
    /// 后者变了会导致取不回凭据。这里钉住两者互不影响。
    func testCredentialIdentityIDAndKeychainAccountAreIndependent() {
        var credential = CredentialIdentity(
            id: "cred-1",
            kind: .apiKey,
            secureReference: SecureReference(storage: .keychainAccount, name: "copool.deepseek.default"),
            source: .userEntered,
            healthState: .ready
        )
        let originalID = credential.id

        // 换一把 Keychain 账号（例如用户重新填了 Key）不改变凭据身份。
        credential.secureReference = SecureReference(storage: .keychainAccount, name: "copool.deepseek.rotated")

        XCTAssertEqual(credential.id, originalID)
        XCTAssertEqual(credential.secureReference?.name, "copool.deepseek.rotated")
    }

    /// 健康状态每次校验都在变，它绝不能参与身份。
    func testCredentialIdentityIDSurvivesHealthTransitions() {
        var credential = CredentialIdentity(
            id: "cred-1",
            kind: .apiKey,
            secureReference: SecureReference(storage: .keychainAccount, name: "copool.deepseek.default"),
            source: .userEntered,
            healthState: .ready
        )
        let originalID = credential.id

        for state in CredentialHealthState.allCases {
            credential.healthState = state
            credential.lastFailureReason = state == .ready ? nil : "上游返回错误"
            XCTAssertEqual(credential.id, originalID, "healthState=\(state) 时 id 发生了变化")
        }
    }

    // MARK: - ModelCatalogEntry

    /// 目录条目的 id 是计算属性 `instance/backendModelID`。displayName 与
    /// aliases 都是展示层的东西，改它们不能动路由键。
    func testModelCatalogEntryIDSurvivesRenameAndAliasEdits() {
        var entry = ModelCatalogEntry(
            providerInstanceID: "instance-1",
            backendModelID: "deepseek-chat",
            displayName: "DeepSeek Chat",
            aliases: ["ds-chat"],
            capabilities: ModelCapabilitiesV2(contextWindow: 128_000),
            origin: .seed
        )
        let originalID = entry.id
        XCTAssertEqual(originalID, "instance-1/deepseek-chat")

        entry.displayName = renamed
        entry.aliases = ["完全不同的别名", "another-alias"]
        entry.visibility = .hidden
        entry.upstreamAvailable = false

        XCTAssertEqual(entry.id, originalID, "改名 / 改别名 / 改可见性都不得改变目录条目 id")
    }

    /// 反向确认 id 确实由那两个字段构成——否则上面的测试可能只是因为
    /// id 是个常量而通过。
    func testModelCatalogEntryIDTracksRoutingFields() {
        let base = ModelCatalogEntry(providerInstanceID: "instance-1", backendModelID: "deepseek-chat")
        var moved = base
        moved.providerInstanceID = "instance-2"
        var upgraded = base
        upgraded.backendModelID = "deepseek-reasoner"

        XCTAssertNotEqual(moved.id, base.id, "换实例后应当是另一个路由键")
        XCTAssertNotEqual(upgraded.id, base.id, "换后端模型后应当是另一个路由键")
    }

    // MARK: - 编解码往返

    /// 落盘再读回来，四类 id 必须逐一不变。序列化是最容易悄悄丢字段的一环。
    func testAllIdentitiesSurviveCodableRoundTrip() throws {
        let definition = ProviderDefinition(
            id: "deepseek",
            displayName: "DeepSeek API",
            ownership: "deepseek",
            supportedProtocols: [.chat],
            defaultBaseURL: "https://api.deepseek.com",
            credentialKinds: [.apiKey],
            isBuiltIn: true
        )
        let credential = CredentialIdentity(
            id: "cred-1",
            kind: .apiKey,
            secureReference: SecureReference(storage: .keychainAccount, name: "copool.deepseek.default"),
            source: .userEntered,
            healthState: .ready
        )
        let instance = ProviderInstance(
            id: "instance-1",
            definitionID: definition.id,
            displayName: "我的 DeepSeek",
            endpoint: "https://api.deepseek.com",
            credentialID: credential.id,
            protocolBindings: ["chat": .chat],
            defaultProtocol: .chat,
            enabled: true,
            addedAt: 1_700_000_000,
            credentialIdentityIDs: [credential.id]
        )
        let entry = ModelCatalogEntry(
            providerInstanceID: instance.id,
            backendModelID: "deepseek-chat",
            displayName: "DeepSeek Chat",
            capabilities: ModelCapabilitiesV2(contextWindow: 128_000),
            origin: .seed
        )

        let registry = ProviderRegistryV2(
            definitions: [definition],
            instances: [instance],
            credentials: [credential],
            catalog: [entry]
        )

        let data = try JSONEncoder().encode(registry)
        let restored = try JSONDecoder().decode(ProviderRegistryV2.self, from: data)

        XCTAssertEqual(restored.definitions.first?.id, definition.id)
        XCTAssertEqual(restored.instances.first?.id, instance.id)
        XCTAssertEqual(restored.credentials.first?.id, credential.id)
        XCTAssertEqual(restored.catalog.first?.id, entry.id)

        // 交叉引用也要闭合：id 一致但指向断了，等于没保住身份。
        XCTAssertEqual(restored.instances.first?.definitionID, definition.id)
        XCTAssertEqual(restored.instances.first?.credentialID, credential.id)
        XCTAssertEqual(restored.catalog.first?.providerInstanceID, instance.id)
        XCTAssertNotNil(restored.definition(id: definition.id))
        XCTAssertNotNil(restored.instance(id: instance.id))
        XCTAssertNotNil(restored.credential(id: credential.id))
    }
}
