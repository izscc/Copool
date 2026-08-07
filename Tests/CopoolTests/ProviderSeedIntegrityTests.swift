import XCTest
@testable import Copool

/// TST-01：内置供应商种子的构建期完整性校验。
///
/// 种子是随包发布的只读常量，它坏掉的表现是"用户打开供应商页，一家都没有"，
/// 而且现场没有任何线索。所以这里把它当构建产物来测：数量、唯一性、
/// 交叉引用是否闭合，全部在 CI 上拦。
final class ProviderSeedIntegrityTests: XCTestCase {

    private func loadSeed() throws -> ProviderRegistrySeedLoader.Seed {
        try ProviderRegistrySeedLoader.load()
    }

    // MARK: - definitions

    func testSeedDecodesExpectedDefinitionCount() throws {
        let seed = try loadSeed()
        XCTAssertEqual(seed.definitions.count, 23, "内置供应商数量与 07 章 DM-01 不一致")
    }

    func testDefinitionIDsAreGloballyUnique() throws {
        let seed = try loadSeed()
        let ids = seed.definitions.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "provider definition id 重复：\(duplicates(in: ids))")
    }

    func testDefinitionIDsAreNonEmpty() throws {
        let seed = try loadSeed()
        for definition in seed.definitions {
            XCTAssertFalse(definition.id.isEmpty, "存在空 id 的 definition：\(definition.displayName)")
            XCTAssertFalse(definition.displayName.isEmpty, "\(definition.id) 缺少 displayName")
        }
    }

    /// OAuth 登录态类供应商的 baseURL 由外部 CLI 的会话决定，种子里留空是有意的；
    /// 其余每一家都必须是 https——明文 http 会让 Key 走裸传输。
    func testDefaultBaseURLsAreHTTPSExceptExternalSessionProviders() throws {
        let seed = try loadSeed()
        let exempt: Set<String> = ["kimi-oauth", "grok-oauth"]
        for definition in seed.definitions where !exempt.contains(definition.id) {
            XCTAssertTrue(
                definition.defaultBaseURL.hasPrefix("https://"),
                "\(definition.id) 的 defaultBaseURL 不是 https：\(definition.defaultBaseURL)"
            )
        }
        for id in exempt {
            let definition = seed.definitions.first { $0.id == id }
            XCTAssertNotNil(definition, "豁免名单里的 \(id) 不在种子中——名单该更新了")
            XCTAssertTrue(
                definition?.defaultBaseURL.isEmpty ?? false,
                "\(id) 既然走外部 CLI 会话，defaultBaseURL 就该留空"
            )
        }
    }

    /// SEC-08：复用第三方本机登录态必须经过明确同意，且要能说清读的是什么。
    func testExternalSessionProvidersDeclareDisclosureAndConsent() throws {
        let seed = try loadSeed()
        for definition in seed.definitions where definition.credentialKinds.contains(.externalCLISession) {
            let session = try XCTUnwrap(
                definition.externalSession,
                "\(definition.id) 声明了 externalCLISession，却没有 externalSession 说明"
            )
            XCTAssertFalse(session.cliName.isEmpty, "\(definition.id) 的 externalSession 缺少 cliName")
            XCTAssertFalse(session.disclosure.isEmpty, "\(definition.id) 缺少来源披露文案")
            XCTAssertTrue(session.requiresExplicitConsent, "\(definition.id) 绕过了显式同意门")
        }
    }

    // MARK: - catalog

    /// 逐家清点，而不是只断言总数。总数相等掩盖得了"A 家掉了 2 条、B 家多了
    /// 2 条"，而这正是编辑种子时最容易犯的错。
    ///
    /// 这张表与 02 章 FR-CAT-02 的分布表一一对应。改动种子时同步改两处，
    /// 让增删模型成为一次显式决定。
    private static let expectedCatalogCounts: [String: Int] = [
        "kimi-oauth": 3,
        "kimi-api": 1,
        "deepseek": 4,
        "grok-oauth": 1,
        "grok-api": 1,
        "anthropic-api": 1,
        "zai-coding": 2,
        "qwen-plan": 8,
        "ollama-cloud": 4,
        "minimax-token-plan": 1,
        "opencode-go": 11,
        "opencode-go-messages": 6,
        "opencode-go-responses": 1
    ]

    func testSeedDecodesExpectedCatalogCountPerProvider() throws {
        let seed = try loadSeed()
        var actual: [String: Int] = [:]
        for entry in seed.catalog {
            actual[entry.provider, default: 0] += 1
        }

        XCTAssertEqual(actual, Self.expectedCatalogCounts, "内置模型条目的逐家分布发生了变化")
        XCTAssertEqual(seed.catalog.count, Self.expectedCatalogCounts.values.reduce(0, +))
    }

    /// `catalogOnly` 的含义是"不带内置模型条目，模型全部来自实时发现"
    /// （FR-PRV-01）。给它塞种子条目会让实时发现的合并结果掺进永远刷不掉的
    /// 硬编码；反过来，非 catalogOnly 却一条模型都没有，用户配好凭据后
    /// 会看到空目录。
    func testCatalogOnlyProvidersCarryNoSeedModels() throws {
        let seed = try loadSeed()
        let providersWithModels = Set(seed.catalog.map(\.provider))

        for definition in seed.definitions {
            if definition.catalogOnly {
                XCTAssertFalse(
                    providersWithModels.contains(definition.id),
                    "\(definition.id) 标了 catalogOnly，却带了内置模型条目"
                )
            } else {
                XCTAssertTrue(
                    providersWithModels.contains(definition.id),
                    "\(definition.id) 不是 catalogOnly，却一条内置模型都没有"
                )
            }
        }
    }

    /// 目录条目的身份是 (provider, backendModelID)。同一个 provider 下重复的
    /// backendModelID 会让路由选到哪一条变成看排序运气。
    func testCatalogEntriesAreGloballyUnique() throws {
        let seed = try loadSeed()
        let keys = seed.catalog.map { "\($0.provider)/\($0.backendModelID)" }
        XCTAssertEqual(Set(keys).count, keys.count, "catalog 条目重复：\(duplicates(in: keys))")
    }

    func testEveryCatalogEntryResolvesToADefinition() throws {
        let seed = try loadSeed()
        let definitionIDs = Set(seed.definitions.map(\.id))
        for entry in seed.catalog {
            XCTAssertTrue(
                definitionIDs.contains(entry.provider),
                "catalog 条目 \(entry.backendModelID) 指向不存在的 provider：\(entry.provider)"
            )
        }
    }

    /// autoCompact 是"该压缩上下文了"的触发点，必须严格小于窗口本身，
    /// 否则永远触发不到，长会话会直接撞上游 400。
    func testAutoCompactThresholdIsBelowContextWindow() throws {
        let seed = try loadSeed()
        for entry in seed.catalog {
            guard let autoCompact = entry.autoCompact, let window = entry.contextWindow else { continue }
            XCTAssertLessThan(
                autoCompact,
                window,
                "\(entry.provider)/\(entry.backendModelID) 的 autoCompact(\(autoCompact)) 不小于 contextWindow(\(window))"
            )
            XCTAssertGreaterThan(autoCompact, 0, "\(entry.backendModelID) 的 autoCompact 必须为正")
        }
    }

    /// nil 表示"未探测过"，[] 表示"上游明确不支持"——两者语义不同。
    /// 但只要声明了默认档位，它就必须在候选集合里，否则发出去必被拒。
    func testDefaultReasoningEffortIsWithinSupportedSet() throws {
        let seed = try loadSeed()
        for entry in seed.catalog {
            guard let fallback = entry.defaultReasoningEffort else { continue }
            let supported = try XCTUnwrap(
                entry.reasoningEfforts,
                "\(entry.backendModelID) 声明了 defaultReasoningEffort 却没有 reasoningEfforts"
            )
            XCTAssertTrue(
                supported.contains(fallback),
                "\(entry.backendModelID) 的默认档位 \(fallback) 不在 \(supported) 中"
            )
        }
    }

    // MARK: - request profiles

    func testEveryReferencedRequestProfileExists() throws {
        let seed = try loadSeed()
        let available = Set(seed.requestProfiles.keys)

        for definition in seed.definitions {
            guard let id = definition.requestProfileID else { continue }
            XCTAssertTrue(available.contains(id), "definition \(definition.id) 引用了不存在的 requestProfile：\(id)")
        }
        for entry in seed.catalog {
            guard let id = entry.requestProfile else { continue }
            XCTAssertTrue(
                available.contains(id),
                "catalog 条目 \(entry.backendModelID) 引用了不存在的 requestProfile：\(id)"
            )
        }
    }

    /// 定义了却没人引用的 profile 是死数据——它通常意味着某处的 id 拼错了。
    func testEveryRequestProfileIsReferenced() throws {
        let seed = try loadSeed()
        var referenced = Set(seed.definitions.compactMap(\.requestProfileID))
        referenced.formUnion(seed.catalog.compactMap(\.requestProfile))
        let orphans = Set(seed.requestProfiles.keys).subtracting(referenced)
        XCTAssertTrue(orphans.isEmpty, "存在无人引用的 requestProfile：\(orphans.sorted())")
    }

    /// FR-PRO-05：`forcedEffort` 必须是引用该 profile 的模型确实支持的档位，
    /// 否则强制出去的值必被上游拒。
    ///
    /// 注意 `forcedEffort` 与 `reasoningParameter: none` **不矛盾**——规格
    /// 举的正是 `kimi-k3`：上游不接受显式推理参数，但它恒在 max 档运行。
    /// 前者说的是"线上怎么发"，后者说的是"实际生效的档位"，用于本地展示
    /// 与路由排序。把两者判成冲突反而会逼着数据说谎。
    func testForcedEffortIsSupportedByEveryModelUsingTheProfile() throws {
        let seed = try loadSeed()

        for entry in seed.catalog {
            guard let profileID = entry.requestProfile,
                  let forced = seed.requestProfiles[profileID]?.forcedEffort else { continue }
            // reasoningEfforts 为 nil 表示"未探测过"，无从校验，跳过。
            guard let supported = entry.reasoningEfforts else { continue }
            XCTAssertTrue(
                supported.contains(forced),
                "\(entry.provider)/\(entry.backendModelID) 用的 profile \(profileID) 强制 \(forced) 档，但该模型只支持 \(supported)"
            )
        }
    }

    // MARK: - materialize

    /// 种子按 definition id 归属，落库按 instance id 归属。这一步桥接不能丢信息，
    /// 也不能把"未知"伪装成"已知"。
    func testMaterializePreservesProvenanceAndOrigin() throws {
        let seed = try loadSeed()
        let entry = try XCTUnwrap(seed.catalog.first { $0.contextWindow != nil })
        let materialized = entry.materialize(instanceID: "instance-1")

        XCTAssertEqual(materialized.providerInstanceID, "instance-1")
        XCTAssertEqual(materialized.backendModelID, entry.backendModelID)
        XCTAssertEqual(materialized.origin, .seed)
        XCTAssertEqual(materialized.capabilities.contextWindow, entry.contextWindow)
        XCTAssertEqual(materialized.metadataSources["contextWindow"], .registry)

        if entry.reasoningEfforts == nil {
            XCTAssertNil(
                materialized.metadataSources["reasoningEfforts"],
                "种子没声明档位时不该标注来源——那会把未知伪装成已知"
            )
        }
    }

    // MARK: - helpers

    private func duplicates(in values: [String]) -> [String] {
        var seen: Set<String> = []
        var repeated: Set<String> = []
        for value in values where !seen.insert(value).inserted {
            repeated.insert(value)
        }
        return repeated.sorted()
    }
}
