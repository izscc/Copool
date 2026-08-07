import Foundation

/// 内置供应商种子（`provider-registry-seed.json`）的只读加载器。
///
/// 种子随应用发布，**不写入 Application Support**——它是只读常量，写出去
/// 只会在升级时造成合并困扰（DM-09）。用户的改动落在 `userDefinitions`
/// 覆盖层，与种子分离保存。
///
/// 解码失败**不降级为空注册表**：静默返回空目录会让用户看到"一个供应商
/// 都没有"，却找不到原因。种子是构建产物，坏了就是构建坏了，应当在
/// `ProviderSeedIntegrityTests`（TST-01）拦下。
enum ProviderRegistrySeedLoader {
    enum SeedError: Error, LocalizedError, Equatable {
        case resourceMissing(String)
        case decodeFailed(String)

        var errorDescription: String? {
            switch self {
            case .resourceMissing(let name):
                return "内置供应商种子缺失：\(name)"
            case .decodeFailed(let reason):
                return "内置供应商种子解析失败：\(reason)"
            }
        }
    }

    struct Seed: Equatable, Sendable {
        var definitions: [ProviderDefinition]
        var catalog: [SeedCatalogEntry]
        var requestProfiles: [String: RequestProfile]

        /// 某个 definition 的种子条目，绑定到给定实例。
        ///
        /// `instanceID` 传空串时产出的是**预览条目**：用于在用户还没配置这家
        /// 之前就展示"配好之后能拿到什么"。它们不入库，`id` 也不具备唯一性，
        /// 只用于渲染（SCR-PRV-02 的「缺少凭据」分组）。
        func catalogEntries(definitionID: String, instanceID: String) -> [ModelCatalogEntry] {
            catalog
                .filter { $0.provider == definitionID }
                .map { $0.materialize(instanceID: instanceID) }
        }
    }

    /// 种子里的目录条目。它按 **provider definition id** 归属，而运行时的
    /// `ModelCatalogEntry` 按 **provider instance id** 归属——实例要用户配置
    /// 出来才存在，所以两者不能是同一个类型。
    struct SeedCatalogEntry: Codable, Equatable, Sendable {
        var provider: String
        var backendModelID: String
        var displayName: String?
        var contextWindow: Int?
        var autoCompact: Int?
        var reasoningEfforts: [String]?
        var defaultReasoningEffort: String?
        var inputModalities: [String]
        var requestProfile: String?
        var visibility: ModelVisibility
        var aliases: [String]

        private enum CodingKeys: String, CodingKey {
            case provider
            case backendModelID
            case displayName
            case contextWindow
            case autoCompact
            case reasoningEfforts
            case defaultReasoningEffort
            case inputModalities
            case requestProfile
            case visibility
            case aliases
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            provider = try container.decode(String.self, forKey: .provider)
            backendModelID = try container.decode(String.self, forKey: .backendModelID)
            displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
            contextWindow = try container.decodeIfPresent(Int.self, forKey: .contextWindow)
            autoCompact = try container.decodeIfPresent(Int.self, forKey: .autoCompact)
            // 缺省是 nil（未知），不是 []（明确不支持）——见 ModelCapabilitiesV2。
            reasoningEfforts = try container.decodeIfPresent([String].self, forKey: .reasoningEfforts)
            defaultReasoningEffort = try container.decodeIfPresent(String.self, forKey: .defaultReasoningEffort)
            inputModalities = try container.decodeIfPresent([String].self, forKey: .inputModalities) ?? []
            requestProfile = try container.decodeIfPresent(String.self, forKey: .requestProfile)
            visibility = try container.decodeIfPresent(ModelVisibility.self, forKey: .visibility) ?? .visible
            aliases = try container.decodeIfPresent([String].self, forKey: .aliases) ?? []
        }

        /// 绑定到一个具体实例，产出可入库的目录条目。
        func materialize(instanceID: String) -> ModelCatalogEntry {
            var sources: [String: MetadataSource] = [:]
            if contextWindow != nil {
                sources["contextWindow"] = .registry
            }
            if reasoningEfforts != nil {
                sources["reasoningEfforts"] = .registry
            }
            return ModelCatalogEntry(
                providerInstanceID: instanceID,
                backendModelID: backendModelID,
                displayName: displayName,
                aliases: aliases,
                capabilities: ModelCapabilitiesV2(
                    contextWindow: contextWindow,
                    supportedReasoningEfforts: reasoningEfforts,
                    defaultReasoningEffort: defaultReasoningEffort,
                    inputModalities: inputModalities,
                    supportsVision: inputModalities.isEmpty ? nil : inputModalities.contains("image")
                ),
                metadataSources: sources,
                visibility: visibility,
                requestProfileID: requestProfile,
                autoCompactThreshold: autoCompact,
                origin: .seed,
                upstreamAvailable: true
            )
        }
    }

    private struct SeedFile: Decodable {
        var definitions: [ProviderDefinition]
        var catalog: [SeedCatalogEntry]
        var requestProfiles: [String: RequestProfile]

        private enum CodingKeys: String, CodingKey {
            case definitions
            case catalog
            case requestProfiles
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            definitions = try container.decode([ProviderDefinition].self, forKey: .definitions)
            catalog = try container.decodeIfPresent([SeedCatalogEntry].self, forKey: .catalog) ?? []
            requestProfiles = try container.decodeIfPresent([String: RequestProfile].self, forKey: .requestProfiles) ?? [:]
        }
    }

    static let resourceName = "provider-registry-seed"

    private static var bundle: Bundle {
        #if SWIFT_PACKAGE
        return .module
        #else
        return .main
        #endif
    }

    /// 进程内只解码一次。种子是只读常量，重复解码没有意义。
    private static let cached: Result<Seed, SeedError> = {
        do {
            return .success(try decodeFromBundle())
        } catch let error as SeedError {
            return .failure(error)
        } catch {
            return .failure(.decodeFailed(String(describing: error)))
        }
    }()

    static func load() throws -> Seed {
        try cached.get()
    }

    private static func decodeFromBundle() throws -> Seed {
        guard let url = bundle.url(forResource: resourceName, withExtension: "json") else {
            throw SeedError.resourceMissing("\(resourceName).json")
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw SeedError.resourceMissing(url.lastPathComponent)
        }
        return try decode(data)
    }

    /// 单测直接喂数据用，绕开 Bundle 查找。
    static func decode(_ data: Data) throws -> Seed {
        do {
            let file = try JSONDecoder().decode(SeedFile.self, from: data)
            return Seed(
                definitions: file.definitions,
                catalog: file.catalog,
                requestProfiles: file.requestProfiles
            )
        } catch let error as DecodingError {
            throw SeedError.decodeFailed(String(describing: error))
        }
    }
}
