import SwiftUI

/// Agents tab: bind task shapes to models, then watch what the router picked.
/// Secondary navigation: Profiles / Sessions / Tools / Live.
struct AgentPageView: View {
    @ObservedObject var model: AgentPageModel
    @State private var editing: AgentProfile?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LayoutRules.sectionSpacing) {
                header
                subTabPicker
                switch model.subTab {
                case .profiles:
                    routingModeSection
                    profilesSection
                case .sessions:
                    sessionsSection
                case .tools:
                    toolsSection
                case .live:
                    if !model.events.isEmpty {
                        activitySection
                    } else {
                        Text(L10n.tr("agents.live.empty"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, LayoutRules.pagePadding)
                    }
                }
            }
            .padding(.vertical, LayoutRules.pagePadding)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .task {
            model.load()
            model.loadSessions()
        }
        .onChange(of: model.subTab) { _, newValue in
            if newValue == .sessions {
                model.loadSessions()
            }
        }
        .sheet(item: $editing) { profile in
            AgentProfileEditor(
                profile: profile,
                availableModels: model.availableModels,
                otherProfiles: model.profiles.filter { $0.id != profile.id },
                onSave: { updated in
                    model.save(updated)
                    editing = nil
                },
                onCancel: { editing = nil }
            )
        }
        .sheet(item: $model.selectedSession) { session in
            SessionPreviewSheet(session: session)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.tr("agents.title"))
                .font(.headline)
            Text(L10n.tr("agents.subtitle"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, LayoutRules.pagePadding)
    }

    private var subTabPicker: some View {
        Picker("", selection: $model.subTab) {
            ForEach(AgentSubTab.allCases) { tab in
                Text(tab.label).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .padding(.horizontal, LayoutRules.pagePadding)
    }

    // MARK: - Sessions (AC-102: index + search + preview)

    private var sessionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField(L10n.tr("agents.sessions.search_placeholder"), text: $model.sessionSearchText)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)

            if model.filteredSessions.isEmpty {
                Text(L10n.tr("agents.sessions.empty"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 6) {
                    ForEach(model.filteredSessions.prefix(50)) { session in
                        Button {
                            model.selectedSession = session
                        } label: {
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(session.displayName ?? session.targetSessionID)
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    Text(session.targetSessionID)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 0)
                                Text(relativeTime(session.updatedAt))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(8)
                        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
        .padding(14)
        .frostedRoundedSurface(cornerRadius: 12, prominent: false)
        .padding(.horizontal, LayoutRules.pagePadding)
    }

    private func relativeTime(_ unixSeconds: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(unixSeconds))
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    // MARK: - Tools (read-only execution boundary status)

    private var toolsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.tr("agents.tools.title"))
                .font(.subheadline.weight(.semibold))
            Text(L10n.tr("agents.tools.subtitle"))
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Image(systemName: "lock.shield")
                    .foregroundStyle(.green)
                Text(L10n.tr("agents.tools.boundary"))
                    .font(.caption)
            }
            .padding(10)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))

            HStack(spacing: 10) {
                Image(systemName: "xmark.circle")
                    .foregroundStyle(.orange)
                Text(L10n.tr("agents.tools.computer_use_off"))
                    .font(.caption)
            }
            .padding(10)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        }
        .padding(14)
        .frostedRoundedSurface(cornerRadius: 12, prominent: false)
        .padding(.horizontal, LayoutRules.pagePadding)
    }

    private var routingModeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker(L10n.tr("agents.mode.label"), selection: Binding(
                get: { model.settings.mode },
                set: { model.setMode($0) }
            )) {
                Text(L10n.tr("agents.mode.off")).tag(AgentRoutingMode.off)
                Text(L10n.tr("agents.mode.auto")).tag(AgentRoutingMode.auto)
                Text(L10n.tr("agents.mode.forced")).tag(AgentRoutingMode.forced)
            }
            .pickerStyle(.segmented)

            Text(modeExplanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if model.settings.mode == .auto {
                Toggle(L10n.tr("agents.strict_matching"), isOn: Binding(
                    get: { model.settings.strictMatching },
                    set: { model.setStrictMatching($0) }
                ))
                .font(.caption)
            }
        }
        .padding(14)
        .frostedRoundedSurface(cornerRadius: 12, prominent: false)
        .padding(.horizontal, LayoutRules.pagePadding)
    }

    private var modeExplanation: String {
        switch model.settings.mode {
        case .off: return L10n.tr("agents.mode.off.hint")
        case .auto: return L10n.tr("agents.mode.auto.hint")
        case .forced: return L10n.tr("agents.mode.forced.hint")
        }
    }

    private var profilesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L10n.tr("agents.profiles.title"))
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button {
                    editing = AgentProfile(id: UUID().uuidString, name: L10n.tr("agents.profiles.new_name"))
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if model.profiles.isEmpty {
                Text(L10n.tr("agents.profiles.empty"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                ForEach(model.profiles) { profile in
                    AgentProfileRow(
                        profile: profile,
                        isDefault: model.settings.defaultProfileID == profile.id,
                        onToggleEnabled: { model.setEnabled(id: profile.id, enabled: $0) },
                        onEdit: { editing = profile },
                        onDelete: { model.delete(id: profile.id) },
                        onMakeDefault: { model.setDefaultProfile(id: profile.id) }
                    )
                }
            }
        }
        .padding(14)
        .frostedRoundedSurface(cornerRadius: 12, prominent: false)
        .padding(.horizontal, LayoutRules.pagePadding)
    }

    private var activitySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.tr("agents.live.title"))
                .font(.subheadline.weight(.semibold))
            Text(L10n.tr("agents.live.subtitle"))
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(model.events.prefix(30)) { event in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(event.sessionName ?? event.taskID ?? "—")
                            .font(.caption.weight(.medium))
                        Text(event.profileID ?? event.profileName ?? "—")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        if let modelID = event.model {
                            Text(modelID)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                    Text(timestampText(event.at))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
        }
        .padding(14)
        .frostedRoundedSurface(cornerRadius: 12, prominent: false)
        .padding(.horizontal, LayoutRules.pagePadding)
    }

    private func timestampText(_ unixSeconds: Int64) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(unixSeconds)))
    }
}

/// Session preview sheet (AC-102): metadata for the selected session.
private struct SessionPreviewSheet: View {
    let session: SessionRecord
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L10n.tr("agents.sessions.preview_title"))
                    .font(.headline)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            VStack(alignment: .leading, spacing: 6) {
                label(L10n.tr("agents.sessions.preview_name"), session.displayName ?? "—")
                label(L10n.tr("agents.sessions.preview_session_id"), session.targetSessionID)
                label(L10n.tr("agents.sessions.preview_target"), session.targetID)
                label(L10n.tr("agents.sessions.preview_model"), session.modelEntryID ?? "—")
                label(L10n.tr("agents.sessions.preview_status"), session.status.rawValue)
                label(L10n.tr("agents.sessions.preview_turns"), String(session.turnCount))
                if let summary = session.lastTaskSummary {
                    label(L10n.tr("agents.sessions.preview_summary"), summary)
                }
            }
            .font(.caption)

            Spacer()
        }
        .padding(20)
        .frame(width: 380, height: 260)
    }

    private func label(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .leading)
            Text(value)
                .textSelection(.enabled)
        }
    }
}

private struct AgentProfileRow: View {
    let profile: AgentProfile
    let isDefault: Bool
    let onToggleEnabled: (Bool) -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onMakeDefault: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(profile.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    if isDefault {
                        AccountTagView(
                            text: L10n.tr("agents.profile.default_tag"),
                            backgroundColor: Color.accentColor.opacity(0.16),
                            foregroundColor: .accentColor
                        )
                    }
                }
                Text(profile.modelRef?.backendModel ?? L10n.tr("agents.profile.no_model"))
                    .font(.caption)
                    .foregroundStyle(profile.modelRef == nil ? Color.orange : Color.secondary)
                if !profile.taskTypes.isEmpty || !profile.tags.isEmpty {
                    Text((profile.taskTypes + profile.tags).joined(separator: " · "))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            Toggle("", isOn: Binding(get: { profile.enabled }, set: onToggleEnabled))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)

            Menu {
                Button(L10n.tr("common.edit"), action: onEdit)
                Button(L10n.tr("agents.profile.make_default"), action: onMakeDefault)
                Divider()
                Button(L10n.tr("common.delete"), role: .destructive, action: onDelete)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.body)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 24)
        }
        .padding(12)
        .frostedRoundedSurface(cornerRadius: 10, prominent: false)
        .opacity(profile.enabled ? 1 : 0.55)
    }
}

/// Sheet for editing one profile.
private struct AgentProfileEditor: View {
    @State var profile: AgentProfile
    let availableModels: [AgentCatalogModel]
    let otherProfiles: [AgentProfile]
    let onSave: (AgentProfile) -> Void
    let onCancel: () -> Void

    @State private var taskTypesText: String = ""
    @State private var tagsText: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L10n.tr("agents.editor.title"))
                .font(.headline)
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    field(L10n.tr("agents.editor.name")) {
                        TextField("", text: $profile.name)
                            .textFieldStyle(.roundedBorder)
                    }

                    field(L10n.tr("agents.editor.summary"), hint: L10n.tr("agents.editor.summary.hint")) {
                        TextField("", text: $profile.summary, axis: .vertical)
                            .lineLimit(2...4)
                            .textFieldStyle(.roundedBorder)
                    }

                    field(L10n.tr("agents.editor.model")) {
                        Picker("", selection: modelBinding) {
                            Text(L10n.tr("agents.editor.model.none")).tag("")
                            ForEach(availableModels, id: \.slug) { entry in
                                Text("\(entry.provider) / \(entry.slug)").tag(entry.slug)
                            }
                        }
                        .labelsHidden()
                        if availableModels.isEmpty {
                            Text(L10n.tr("agents.editor.model.empty"))
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                    }

                    field(L10n.tr("agents.editor.task_types"), hint: L10n.tr("agents.editor.labels.hint")) {
                        TextField("", text: $taskTypesText)
                            .textFieldStyle(.roundedBorder)
                    }

                    field(L10n.tr("agents.editor.tags"), hint: L10n.tr("agents.editor.labels.hint")) {
                        TextField("", text: $tagsText)
                            .textFieldStyle(.roundedBorder)
                    }

                    field(L10n.tr("agents.editor.reasoning")) {
                        Picker("", selection: Binding(
                            get: { profile.reasoningEffort ?? "" },
                            set: { profile.reasoningEffort = $0.isEmpty ? nil : $0 }
                        )) {
                            Text(L10n.tr("agents.editor.reasoning.inherit")).tag("")
                            Text("low").tag("low")
                            Text("medium").tag("medium")
                            Text("high").tag("high")
                        }
                        .labelsHidden()
                    }

                    Toggle(L10n.tr("agents.editor.subagent_enabled"), isOn: $profile.subagentEnabled)
                        .font(.subheadline)
                }
                .padding(.horizontal, 20)
            }

            Divider()
                .padding(.top, 12)

            HStack {
                Spacer()
                Button(L10n.tr("common.cancel"), action: onCancel)
                Button(L10n.tr("common.save")) {
                    profile.taskTypes = Self.splitLabels(taskTypesText)
                    profile.tags = Self.splitLabels(tagsText)
                    onSave(profile)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(profile.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(20)
        }
        .frame(width: 440, height: 560)
        .onAppear {
            taskTypesText = profile.taskTypes.joined(separator: ", ")
            tagsText = profile.tags.joined(separator: ", ")
        }
    }

    private var modelBinding: Binding<String> {
        Binding(
            get: { profile.modelRef?.catalogSlug ?? profile.modelRef?.backendModel ?? "" },
            set: { slug in
                guard let entry = availableModels.first(where: { $0.slug == slug }) else {
                    profile.modelRef = nil
                    return
                }
                profile.modelRef = AgentModelRef(
                    provider: entry.provider,
                    backendModel: entry.backendModel,
                    catalogSlug: entry.slug
                )
            }
        )
    }

    @ViewBuilder
    private func field<Content: View>(
        _ title: String,
        hint: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
            content()
            if let hint {
                Text(hint)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Accepts both comma styles so a Chinese input method does not silently
    /// produce one long label.
    static func splitLabels(_ text: String) -> [String] {
        text
            .split(whereSeparator: { $0 == "," || $0 == "，" || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
