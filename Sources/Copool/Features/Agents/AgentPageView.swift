import SwiftUI

/// Agents tab: bind task shapes to models, then watch what the router picked.
struct AgentPageView: View {
    @ObservedObject var model: AgentPageModel
    @State private var editing: AgentProfile?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LayoutRules.sectionSpacing) {
                header
                routingModeSection
                profilesSection
                if !model.events.isEmpty {
                    activitySection
                }
            }
            .padding(.vertical, LayoutRules.pagePadding)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task { model.load() }
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
                Spacer(minLength: 0)
                Button {
                    editing = AgentProfile(name: L10n.tr("agents.profile.new_name"))
                } label: {
                    Label(L10n.tr("agents.profiles.add"), systemImage: "plus")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
            }

            if model.profiles.isEmpty {
                Text(L10n.tr("agents.profiles.empty"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 12)
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
        .padding(.horizontal, LayoutRules.pagePadding)
    }

    private var activitySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.tr("agents.activity.title"))
                .font(.subheadline.weight(.semibold))
            ForEach(model.events.prefix(20)) { event in
                HStack(spacing: 8) {
                    Image(systemName: event.resolved ? "arrow.triangle.branch" : "minus.circle")
                        .font(.caption2)
                        .foregroundStyle(event.resolved ? Color.accentColor : Color.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(event.model ?? L10n.tr("agents.activity.not_routed"))
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                        Text(event.reason)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                    if let name = event.profileName {
                        Text(name)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frostedRoundedSurface(cornerRadius: 10, prominent: false)
            }
        }
        .padding(.horizontal, LayoutRules.pagePadding)
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
