import XCTest
@testable import Copool

/// TST-02：可落盘 / 可外传的结构体一律不得携带凭据明文（INV-1、SEC-01）。
///
/// 类型层面已经做了隔离——`CredentialIdentity` 只持有 `SecureReference`，
/// 没有存放值的字段。但"类型上装不下"要靠人读代码才能确认，而一次疏忽的
/// 字段新增就能悄悄打破它。这里改用编码后的字节说话：编出来的 JSON 里
/// 只要出现 key 的形状，测试就红。
final class SecretLeakageTests: XCTestCase {

    /// 故意长得像真 key。断言的是"这些字符串不会出现在编码产物里"，
    /// 所以它们越像真的越有价值。
    private enum Fixture {
        static let openAIKey = "sk-proj-AAAABBBBCCCCDDDDEEEEFFFFGGGGHHHH"
        static let anthropicKey = "sk-ant-api03-ZZZZYYYYXXXXWWWWVVVVUUUU"
        static let bearerToken = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.payload.signature"
        static let refreshToken = "1//0gRefreshTokenLooksLikeThis-0000"

        static let all = [openAIKey, anthropicKey, bearerToken, refreshToken]
    }

    private func encode<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(value)
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }

    /// 三类断言：字面量、`sk-` 前缀、`Bearer ` 后跟非空内容。
    /// 后两条是形状匹配——它能抓到测试夹具没预料到的新 key。
    private func assertNoSecrets(
        in encoded: String,
        _ label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for secret in Fixture.all {
            XCTAssertFalse(
                encoded.contains(secret),
                "\(label) 的编码产物里出现了凭据明文：\(secret.prefix(12))…",
                file: file,
                line: line
            )
        }
        XCTAssertFalse(encoded.contains("sk-"), "\(label) 的编码产物里出现了 sk- 前缀", file: file, line: line)
        XCTAssertNil(
            bearerPayload(in: encoded),
            "\(label) 的编码产物里出现了 Bearer 令牌",
            file: file,
            line: line
        )
    }

    /// 返回 `Bearer ` 之后的第一段非空内容；没有则返回 nil。
    private func bearerPayload(in text: String) -> String? {
        var searchRange = text.startIndex..<text.endIndex
        while let range = text.range(of: "Bearer ", range: searchRange) {
            let rest = text[range.upperBound...]
            let payload = rest.prefix { !$0.isWhitespace && $0 != "\"" }
            if !payload.isEmpty {
                return String(payload)
            }
            searchRange = range.upperBound..<text.endIndex
        }
        return nil
    }

    // MARK: - 注册表

    /// 构造一份"什么都有"的注册表：五种凭据类型各一把，实例挂满，目录非空。
    private func makePopulatedRegistry() -> ProviderRegistryV2 {
        let credentials = [
            CredentialIdentity(
                id: "cred-api-key",
                kind: .apiKey,
                secureReference: SecureReference(storage: .keychainAccount, name: "copool.deepseek.default"),
                source: .userEntered,
                lastVerifiedAt: 1_700_000_000,
                healthState: .ready
            ),
            CredentialIdentity(
                id: "cred-env",
                kind: .environmentReference,
                secureReference: SecureReference(storage: .environmentVariable, name: "DEEPSEEK_API_KEY"),
                source: .environment,
                healthState: .ready
            ),
            CredentialIdentity(
                id: "cred-oauth",
                kind: .oauthDeviceFlow,
                secureReference: SecureReference(storage: .keychainAccount, name: "copool.oauth.refresh"),
                source: .importedFromApp,
                scopes: ["openid", "profile"],
                expiresAt: 1_700_003_600,
                healthState: .expired,
                lastFailureReason: "令牌已过期，请重新登录"
            ),
            CredentialIdentity(
                id: "cred-cli",
                kind: .externalCLISession,
                secureReference: SecureReference(storage: .keychainAccount, name: "copool.grok.session"),
                source: .importedFromApp,
                healthState: .unauthorized,
                lastFailureReason: "上游返回 401，凭据无权限"
            ),
            CredentialIdentity(
                id: "cred-subscription",
                kind: .subscriptionImport,
                secureReference: SecureReference(storage: .keychainAccount, name: "copool.chatgpt.session"),
                source: .keychainMigrated,
                healthState: .verifying
            )
        ]

        let instance = ProviderInstance(
            id: "instance-deepseek",
            definitionID: "deepseek",
            displayName: "DeepSeek",
            endpoint: "https://api.deepseek.com",
            credentialID: "cred-api-key",
            protocolBindings: ["chat": .chat],
            defaultProtocol: .chat,
            enabled: true,
            addedAt: 1_700_000_000,
            credentialIdentityIDs: credentials.map(\.id)
        )

        let definition = ProviderDefinition(
            id: "deepseek",
            displayName: "DeepSeek API",
            ownership: "deepseek",
            supportedProtocols: [.chat],
            defaultBaseURL: "https://api.deepseek.com",
            credentialKinds: [.apiKey, .environmentReference],
            isBuiltIn: true,
            baseURLEnvironmentVariable: "DEEPSEEK_API_BASE_URL",
            environmentVariables: ["DEEPSEEK_API_KEY"],
            credentialPrompt: "DeepSeek API key"
        )

        let entry = ModelCatalogEntry(
            providerInstanceID: instance.id,
            backendModelID: "deepseek-chat",
            displayName: "DeepSeek Chat",
            capabilities: ModelCapabilitiesV2(contextWindow: 128_000),
            origin: .seed
        )

        return ProviderRegistryV2(
            definitions: [definition],
            instances: [instance],
            credentials: credentials,
            catalog: [entry],
            requestProfiles: ["deepseek-chat": RequestProfile(reasoningParameter: .none)]
        )
    }

    func testRegistryEncodingCarriesNoSecrets() throws {
        let encoded = try encode(makePopulatedRegistry())
        assertNoSecrets(in: encoded, "ProviderRegistryV2")
    }

    /// 反过来确认这份夹具不是"因为编码产物是空的"才通过——引用信息必须在，
    /// 只是不能带值。
    func testRegistryEncodingKeepsReferencesUsable() throws {
        let encoded = try encode(makePopulatedRegistry())
        XCTAssertTrue(encoded.contains("copool.deepseek.default"), "Keychain 账号名应保留，否则凭据取不回来")
        XCTAssertTrue(encoded.contains("DEEPSEEK_API_KEY"), "环境变量名应保留——它是名字，不是值")
        XCTAssertTrue(encoded.contains("cred-oauth"), "凭据 id 应保留")
    }

    /// 单把凭据单独编码也要干净：它会随实例卡片、诊断导出单独走。
    func testCredentialIdentityHasNoFieldThatCouldHoldAValue() throws {
        let credential = CredentialIdentity(
            id: "cred-api-key",
            kind: .apiKey,
            secureReference: SecureReference(storage: .keychainAccount, name: "copool.deepseek.default"),
            source: .userEntered,
            healthState: .ready
        )
        let encoded = try encode(credential)
        assertNoSecrets(in: encoded, "CredentialIdentity")

        // 编码产物的键集合是白名单：新增字段必须在这里显式过一遍人眼。
        let object = try JSONSerialization.jsonObject(with: try XCTUnwrap(encoded.data(using: .utf8)))
        let keys = Set((object as? [String: Any])?.keys.map(String.init) ?? [])
        let allowed: Set<String> = [
            "id", "kind", "secureReference", "source", "scopes",
            "expiresAt", "lastVerifiedAt", "healthState", "lastFailureReason"
        ]
        XCTAssertTrue(
            keys.isSubset(of: allowed),
            "CredentialIdentity 出现了未经审阅的新字段：\(keys.subtracting(allowed).sorted())"
        )
    }

    // MARK: - 路由决策轨迹

    func testRouteDecisionTraceCarriesNoSecrets() throws {
        let trace = RouteDecisionTrace(
            id: "trace-1",
            at: 1_700_000_000,
            requestID: "req-1",
            selectionKind: .auto,
            requestedModel: "deepseek-chat",
            resolvedModel: "deepseek-chat",
            constraints: RouteHardConstraints(
                allowedProviderInstanceIDs: ["instance-deepseek"],
                requiredDialects: [.chat],
                minContextWindow: 32_000
            ),
            candidates: [
                RouteCandidateScore(
                    modelEntryID: "instance-deepseek/deepseek-chat",
                    providerInstanceID: "instance-deepseek",
                    dialect: .chat,
                    score: 0.91,
                    reasons: ["contextFit=1.0", "health=ready"],
                    rejectedReason: nil
                )
            ],
            selectedEntryID: "instance-deepseek/deepseek-chat",
            fallbackAttempts: ["instance-kimi/kimi-k2"],
            // 失败链最容易出事：上游错误体常把 key 片段回显在消息里。
            failureChain: ["instance-kimi: 401 unauthorized"]
        )
        assertNoSecrets(in: try encode(trace), "RouteDecisionTrace")
    }

    // MARK: - 用量事件

    func testUsageEventCarriesNoSecrets() throws {
        let event = UsageEvent(
            model: "deepseek-chat",
            providerID: "instance-deepseek",
            providerName: "DeepSeek",
            status: 200,
            durationMs: 1_234,
            inputTokens: 900,
            outputTokens: 120,
            totalTokens: 1_020
        )
        assertNoSecrets(in: try encode(event), "UsageEvent")
    }

    /// 用量账本按模型名建索引，而模型名来自请求体——调用方可以把任意字符串
    /// 塞进去。它会被原样落盘，所以长度必须有上界。
    func testUsageEventTruncatesCallerControlledStrings() {
        let event = UsageEvent(
            model: String(repeating: "m", count: 5_000),
            providerID: "instance-deepseek",
            providerName: String(repeating: "p", count: 5_000),
            status: 200,
            durationMs: 10
        )
        XCTAssertLessThanOrEqual(event.model.count, 160)
        XCTAssertLessThanOrEqual(event.providerName.count, 160)
    }

    // MARK: - 自检

    /// 确认断言本身是有效的：把凭据塞进一个可编码结构，测试必须能看见它。
    /// 否则前面所有的"通过"都可能只是匹配器写坏了。
    func testDetectorActuallyCatchesSecrets() throws {
        struct Leaky: Encodable {
            var authorization: String
            var apiKey: String
        }
        let encoded = try encode(Leaky(
            authorization: "Bearer \(Fixture.bearerToken)",
            apiKey: Fixture.openAIKey
        ))

        XCTAssertTrue(encoded.contains(Fixture.openAIKey), "自检夹具本身应当含有明文")
        XCTAssertTrue(encoded.contains("sk-"))
        XCTAssertNotNil(bearerPayload(in: encoded), "Bearer 形状匹配器失效了")
    }
}
