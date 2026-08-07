import SwiftUI

/// Explainable route decisions (AC-012 / FR-RTE-05): filters, scores,
/// selection and fallback history are read from the runtime ledger.
///
/// 每行一条请求：时间 · 请求模型 · 选中的 provider+model · 是否转移 · 耗时 ·
/// 结果。点开展开完整 trace（候选集、各候选得分、淘汰原因）。摘要行刻意压到
/// 一屏能扫完——路由 tab 的用途是"回答为什么这条请求走到了那里"，先要能一眼
/// 找到那条请求。
struct RoutesPolicySection: View {
    let traces: [RouteDecisionTrace]
    let entityNames: [String: String]
    let fallbackPolicy: FallbackPolicy
    let onFallbackPolicyChange: (FallbackPolicy) -> Void
    let onRefresh: () -> Void

    @State private var expandedTraceIDs: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(L10n.tr("models.tab.routes"))
                    .font(.headline)
                Spacer(minLength: 0)
                Button(action: onRefresh) {
                    Label(L10n.tr("models.routes.refresh"), systemImage: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
            }
            Text(L10n.tr("models.routes.subtitle"))
                .font(.caption)
                .foregroundStyle(.secondary)

            fallbackPicker

            if traces.isEmpty {
                EmptyStateView(
                    title: L10n.tr("models.tab.routes"),
                    message: L10n.tr("models.routes.no_decisions")
                )
            } else {
                ForEach(traces) { trace in
                    RouteDecisionRow(
                        trace: trace,
                        entityNames: entityNames,
                        isExpanded: expandedTraceIDs.contains(trace.id),
                        onToggle: { toggle(trace.id) }
                    )
                }
            }
        }
        .padding(.horizontal, LayoutRules.pagePadding)
    }

    private func toggle(_ id: String) {
        if expandedTraceIDs.contains(id) {
            expandedTraceIDs.remove(id)
        } else {
            expandedTraceIDs.insert(id)
        }
    }

    /// 失败转移策略（FR-RTE-04）。放在决策列表之前：用户来路由 tab 多半是因为
    /// 某条请求走得不对，先看到"当前规则是什么"才谈得上判断记录是否符合预期。
    private var fallbackPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker(
                L10n.tr("models.routes.fallback.title"),
                selection: Binding(
                    get: { fallbackPolicy.strategy },
                    set: { onFallbackPolicyChange(FallbackPolicy(strategy: $0, maxAttempts: fallbackPolicy.maxAttempts)) }
                )
            ) {
                ForEach(FallbackPolicy.Strategy.allCases, id: \.self) { strategy in
                    Text(Self.title(for: strategy)).tag(strategy)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Text(Self.explanation(for: fallbackPolicy.strategy))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if fallbackPolicy.strategy != .none {
                Stepper(
                    L10n.tr("models.routes.fallback.attempts_format", String(fallbackPolicy.effectiveMaxAttempts)),
                    value: Binding(
                        get: { fallbackPolicy.effectiveMaxAttempts },
                        set: { onFallbackPolicyChange(FallbackPolicy(strategy: fallbackPolicy.strategy, maxAttempts: $0)) }
                    ),
                    in: 1...FallbackPolicy.maxAllowedAttempts
                )
                .font(.caption)
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: LayoutRules.cardRadius))
    }

    private static func title(for strategy: FallbackPolicy.Strategy) -> String {
        switch strategy {
        case .none: return L10n.tr("models.routes.fallback.none")
        case .sameProvider: return L10n.tr("models.routes.fallback.same_provider")
        case .anyEligible: return L10n.tr("models.routes.fallback.any_eligible")
        }
    }

    private static func explanation(for strategy: FallbackPolicy.Strategy) -> String {
        switch strategy {
        case .none: return L10n.tr("models.routes.fallback.none_help")
        case .sameProvider: return L10n.tr("models.routes.fallback.same_provider_help")
        case .anyEligible: return L10n.tr("models.routes.fallback.any_eligible_help")
        }
    }
}

/// 一条路由决策：摘要行 + 可展开的完整 trace。
struct RouteDecisionRow: View {
    let trace: RouteDecisionTrace
    let entityNames: [String: String]
    let isExpanded: Bool
    let onToggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: onToggle) {
                summary
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(.isButton)

            if isExpanded {
                Divider()
                detail
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: LayoutRules.cardRadius))
    }

    // MARK: - 摘要行

    private var summary: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Image(systemName: outcomeIcon)
                    .foregroundStyle(outcomeColor)
                Text(Self.timeText(trace.at))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text(trace.selectionKind.rawValue.uppercased())
                    .font(.caption2.weight(.semibold))
                Text(trace.requestedModel)
                    .font(.caption)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if trace.didFailover {
                    Label(L10n.tr("models.routes.failover_badge"), systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .labelStyle(.titleAndIcon)
                }
                if let durationMS = trace.durationMS {
                    Text(Self.durationText(durationMS))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 6) {
                // 缩进对齐上一行的图标之后，让"选中的是谁"读起来是那一行的
                // 补充说明，而不是另一条独立信息。
                Spacer().frame(width: 18)
                Text(selectionText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(outcomeText)
                    .font(.caption2)
                    .foregroundStyle(outcomeColor)
            }
        }
        .contentShape(Rectangle())
    }

    /// 选中的 provider + model。两者都没有时说明这条请求根本没路由出去。
    private var selectionText: String {
        guard let selected = trace.selectedCandidate else {
            return L10n.tr("models.routes.no_selection")
        }
        let provider = name(for: selected.providerInstanceID)
        let model = name(for: selected.modelEntryID)
        return L10n.tr("models.routes.selection_format", provider, model, selected.dialect.rawValue)
    }

    private var outcomeIcon: String {
        switch trace.outcome {
        case .succeeded: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .notRouted: return "xmark.circle.fill"
        case .pending: return "clock"
        }
    }

    private var outcomeColor: Color {
        switch trace.outcome {
        case .succeeded: return .green
        case .failed: return .red
        case .notRouted: return .orange
        case .pending: return .secondary
        }
    }

    private var outcomeText: String {
        let base: String
        switch trace.outcome {
        case .succeeded: base = L10n.tr("models.routes.outcome.succeeded")
        case .failed: base = L10n.tr("models.routes.outcome.failed")
        case .notRouted: base = L10n.tr("models.routes.outcome.not_routed")
        case .pending: base = L10n.tr("models.routes.outcome.pending")
        }
        guard let status = trace.httpStatus else { return base }
        return "\(base) · \(status)"
    }

    // MARK: - 展开的完整 trace

    private var detail: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 请求 ID 放在最前：用户拿它去和上游工单/日志对齐。
            LabeledTraceRow(label: L10n.tr("models.routes.detail.request_id"), value: trace.requestID)

            let accepted = trace.candidates.filter { $0.rejectedReason == nil }
            let rejected = trace.candidates.filter { $0.rejectedReason != nil }

            if !accepted.isEmpty {
                Text(L10n.tr("models.routes.detail.candidates_format", String(accepted.count)))
                    .font(.caption2.weight(.semibold))
                // 按分数降序：第一行就是被选中的那条，用户不用自己找。
                ForEach(accepted.sorted { $0.score > $1.score }) { candidate in
                    CandidateScoreRow(
                        candidate: candidate,
                        isSelected: candidate.modelEntryID == trace.selectedEntryID,
                        providerName: name(for: candidate.providerInstanceID),
                        modelName: name(for: candidate.modelEntryID)
                    )
                }
            }

            if !rejected.isEmpty {
                Text(L10n.tr("models.routes.detail.rejected_format", String(rejected.count)))
                    .font(.caption2.weight(.semibold))
                    .padding(.top, 2)
                ForEach(rejected) { candidate in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "minus.circle")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(name(for: candidate.modelEntryID))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        Text(candidate.rejectedReason ?? "")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .multilineTextAlignment(.trailing)
                    }
                }
            }

            if trace.didFailover {
                LabeledTraceRow(
                    label: L10n.tr("models.routes.detail.fallbacks"),
                    value: trace.fallbackAttempts.map { name(for: $0) }.joined(separator: " → ")
                )
            }

            if !trace.failureChain.isEmpty {
                Text(L10n.tr("models.routes.failures_format", trace.failureChain.joined(separator: " → ")))
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// id → 显示名。查不到就用 id 本身：那条实例可能已被删除，硬造一个名字
    /// 会让用户以为它还在。
    private func name(for id: String) -> String {
        entityNames[id] ?? id
    }

    // MARK: - 格式化

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm:ss"
        return formatter
    }()

    static func timeText(_ epochSeconds: Int64) -> String {
        timeFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(epochSeconds)))
    }

    /// 秒级以下保留毫秒。一条 180ms 和一条 1.8s 的差别在诊断时是决定性的，
    /// 统一四舍五入到秒会把它们显示成同一个"0s"和"2s"。
    static func durationText(_ milliseconds: Int) -> String {
        guard milliseconds >= 1000 else { return "\(milliseconds)ms" }
        return String(format: "%.1fs", Double(milliseconds) / 1000)
    }
}

/// 展开区里的一条候选及其得分。
struct CandidateScoreRow: View {
    let candidate: RouteCandidateScore
    let isSelected: Bool
    let providerName: String
    let modelName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.caption2)
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                Text(modelName)
                    .font(.caption2.weight(isSelected ? .semibold : .regular))
                    .lineLimit(1)
                Text(providerName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(String(format: "%.3f", candidate.score))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
            }
            if !candidate.reasons.isEmpty {
                Text(candidate.reasons.joined(separator: " · "))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 18)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct LabeledTraceRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Text(label)
                .font(.caption2.weight(.semibold))
            Text(value)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}
