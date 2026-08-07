import Foundation

/// Wires the pure `RoutePlanner` into production routing (AC-012).
///
/// When the v2 registry is present and version 2, every third-party model
/// request is resolved through: hard-filter → score → select, with the full
/// decision trace appended to `RouteDecisionLedger`. The selected provider
/// instance id (a stable v1-inherited UUID, AC-005) is what the caller uses
/// to find the concrete v1 `ProviderConfig` for the upstream request.
/// If the v2 registry is empty or stale, the resolver returns nil and the
/// caller falls back to the legacy v1 route matching (no behavior change).
struct V2RouteResolver: Sendable {
    let registryRepository: ProviderRegistryV2Repository
    let ledger: RouteDecisionLedger

    /// 一个可投递的落点：实例 + 目录条目 + 该条目的请求档案。
    struct Landing: Sendable, Equatable {
        let instance: ProviderInstance
        let entry: ModelCatalogEntry
        let requestProfile: RequestProfile
    }

    struct Resolution: Sendable, Equatable {
        let instance: ProviderInstance
        let entry: ModelCatalogEntry
        let trace: RouteDecisionTrace
        /// 该条目适用的请求档案（FR-PRO-05）。解析时一并算出，避免出站路径
        /// 再读一次 registry.json——那既多一次 IO，又可能读到已被改动的版本，
        /// 让路由决策和请求体变换基于两份不同的快照。
        let requestProfile: RequestProfile
        /// 首选失败后按策略依次改投的落点（FR-RTE-04）。同样在解析时算完：
        /// 转移发生在请求失败之后，那时再回头读注册表，读到的可能已经是另一
        /// 份配置，转移目标会和 trace 里记录的候选集对不上。
        let fallbacks: [Landing]
    }

    /// 为什么解析不出来。调用方据此区分「回落 v1」与「直接 404」。
    enum Failure: Error, Equatable, Sendable {
        /// v2 注册表不可用（空、版本不符）——调用方应回落 v1 匹配。
        case registryUnavailable
        /// 模型名在目录里查无此项（FR-RTE-02 第④步）。回落 v1，v1 也不中则 404。
        case unknownModel(String)
        /// 名字对得上，但所有候选都被硬约束淘汰（缺凭据、被禁用、能力不足…）。
        case noEligibleCandidate(String)
    }

    /// 解析优先级（FR-RTE-02）：① 精确 entry.id ② 别名 ③ 后端模型 ID
    /// ④ 全落空 → 不路由。
    ///
    /// 第④步**不做全目录兜底**。23 家 provider 的场景下，用户在目标应用里
    /// 手误敲一个不存在的模型名，兜底会把它静默送到打分器随手选出的模型上：
    /// 产生真实费用、结果莫名其妙、而且没有任何一处告诉用户名字打错了。
    /// 宁可 404。
    func resolve(
        requestID: String,
        requestedModel: String,
        context: RouteRequestContext = .default,
        allowedProviderInstanceIDs: [String] = [],
        metrics: [String: RouteRuntimeMetrics] = [:],
        now: Int64 = Int64(Date().timeIntervalSince1970)
    ) -> Result<Resolution, Failure> {
        let registry = registryRepository.loadRegistry()
        guard registry.version == ProviderRegistryV2.currentVersion,
              !registry.instances.isEmpty,
              !registry.catalog.isEmpty else {
            return .failure(.registryUnavailable)
        }

        // 转移策略读自 registry（FR-RTE-04）：跨供应商转移会换掉计费主体，
        // 不能由代码替用户决定。老 registry 缺该字段时解码即落到 `.default`。
        let planner = RoutePlanner(weights: .default, fallback: registry.fallbackPolicy)

        // Credential gate (FR-RTE-03): the planner receives only the tri-state
        // gate value — never a secret. Throttled credentials stay in the
        // running with reduced weight rather than taking the provider offline.
        let credentials = Dictionary(
            uniqueKeysWithValues: registry.credentials.map { ($0.id, $0.gateState(now: now)) }
        )

        let normalized = requestedModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let exact = registry.catalog.first { $0.id == normalized }
        // 别名比对走归一化：目录里存的是小写去空白的形式（CatalogCuration），
        // 用原样字符串比会让 "Sonnet" 匹配不上自己的别名 "sonnet"。
        let aliasNeedle = CatalogCuration.normalizeAlias(normalized)
        let alias = registry.catalog.first { entry in
            entry.aliases.contains { CatalogCuration.normalizeAlias($0) == aliasNeedle }
        }
        let backend = registry.catalog.filter { $0.backendModelID == normalized }

        let matching: [ModelCatalogEntry]
        if let exact {
            matching = [exact]
        } else if let alias {
            matching = [alias]
        } else if !backend.isEmpty {
            // 同一个后端模型 ID 挂在多家 provider 下（例如 deepseek-v3 同时来自
            // 官方和几个网关）——全部交给打分器，由它按健康度/配额/成本选。
            matching = backend
        } else {
            // 查无此项：仍然写一条 trace，否则用户在路由 tab 里看不到
            // "我确实发过这个请求，它被拒了"（V2RouteResolver 既有约定）。
            let constraints = RouteHardConstraints(
                request: context,
                allowedProviderInstanceIDs: allowedProviderInstanceIDs
            )
            ledger.append(
                RouteDecisionTrace(
                    requestID: requestID,
                    selectionKind: context.selectionKind,
                    requestedModel: requestedModel,
                    resolvedModel: nil,
                    constraints: constraints,
                    candidates: [],
                    selectedEntryID: nil,
                    fallbackAttempts: [],
                    failureChain: ["unknown model: no catalog entry matched id, alias or backend model id"],
                    outcome: .notRouted
                )
            )
            return .failure(.unknownModel(normalized))
        }

        let selectionKind: ModelSelectionKind = exact != nil ? .explicit : (alias != nil ? .alias : context.selectionKind)
        let selectedEntryID = exact?.id ?? alias?.id
        let effectiveContext = RouteRequestContext(
            targetBindingID: context.targetBindingID,
            sessionID: context.sessionID,
            requestedCapabilities: context.requestedCapabilities,
            requestedRegion: context.requestedRegion,
            remainingBudget: context.remainingBudget,
            explicitEntryID: selectedEntryID,
            alias: context.alias,
            selectionKind: selectionKind
        )
        let constraints = RouteHardConstraints(
            request: effectiveContext,
            allowedProviderInstanceIDs: allowedProviderInstanceIDs
        )

        let (selected, trace) = planner.plan(
            requestID: requestID,
            requestedModel: requestedModel,
            selectionKind: selectionKind,
            entries: matching,
            instances: registry.instances,
            credentials: credentials,
            constraints: constraints,
            metrics: metrics
        )

        // Always record the trace — even a failed resolution is explainable.
        ledger.append(trace)

        guard let selected,
              let instance = registry.instances.first(where: { $0.id == selected.providerInstanceID }),
              let entry = registry.catalog.first(where: { $0.id == selected.modelEntryID }) else {
            return .failure(.noEligibleCandidate(normalized))
        }
        // 转移落点在这里一次性解析完。查不到实例/条目的候选直接丢弃而不是
        // 保留成空壳：转移时拿着一个解析不出实例的候选，唯一的下场是再失败
        // 一次，白烧一次预算。
        let fallbacks = planner.fallbackOrder(after: selected, from: trace.candidates)
            .compactMap { candidate -> Landing? in
                guard let instance = registry.instances.first(where: { $0.id == candidate.providerInstanceID }),
                      let entry = registry.catalog.first(where: { $0.id == candidate.modelEntryID }) else {
                    return nil
                }
                return Landing(
                    instance: instance,
                    entry: entry,
                    requestProfile: registry.requestProfile(for: entry)
                )
            }

        return .success(
            Resolution(
                instance: instance,
                entry: entry,
                trace: trace,
                requestProfile: registry.requestProfile(for: entry),
                fallbacks: fallbacks
            )
        )
    }
}
