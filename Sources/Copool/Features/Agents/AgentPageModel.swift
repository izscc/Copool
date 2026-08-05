import Foundation
import SwiftUI

/// Backs the Agents tab: Agent Profile CRUD, routing mode, and the recent
/// routing decisions.
@MainActor
final class AgentPageModel: ObservableObject {
    @Published private(set) var profiles: [AgentProfile] = []
    @Published private(set) var settings: AgentRoutingSettings = .defaultValue
    @Published private(set) var events: [AgentRouteEvent] = []
    /// Third-party models a profile may be bound to.
    @Published private(set) var availableModels: [AgentCatalogModel] = []
    @Published var notice: NoticeMessage?

    private let agentRepository: AgentProfileRepository
    private let providerStoreRepository: ProviderStoreRepository

    init(
        agentRepository: AgentProfileRepository,
        providerStoreRepository: ProviderStoreRepository
    ) {
        self.agentRepository = agentRepository
        self.providerStoreRepository = providerStoreRepository
    }

    func load() {
        let store = (try? agentRepository.loadAgents()) ?? AgentProfileStore()
        profiles = store.profiles
        settings = store.settings
        events = ((try? agentRepository.loadRouteEvents())?.events ?? []).reversed()
        availableModels = Self.catalogModels(from: providerStoreRepository)
    }

    /// Only configured third-party models can be a routing target — a native
    /// model would just be forwarded, which is what happens without routing.
    static func catalogModels(from repository: ProviderStoreRepository) -> [AgentCatalogModel] {
        let providers = (try? repository.loadProviders())?.providers ?? []
        return providers.flatMap { provider in
            provider.models.map { model in
                AgentCatalogModel(
                    slug: model.id,
                    backendModel: model.id,
                    provider: provider.name,
                    displayName: model.displayName ?? model.id,
                    supportedReasoningEfforts: model.effectiveReasoningEfforts,
                    defaultReasoningEffort: model.defaultReasoningEffort
                )
            }
        }
    }

    // MARK: - Mutations

    func save(_ profile: AgentProfile) {
        var updated = profile
        updated.updatedAt = Int64(Date().timeIntervalSince1970)
        mutate { $0.upsert(updated) }
    }

    func delete(id: String) {
        mutate { $0.remove(id: id) }
    }

    func setMode(_ mode: AgentRoutingMode) {
        mutate { $0.settings.mode = mode }
    }

    func setDefaultProfile(id: String?) {
        mutate { $0.settings.defaultProfileID = id }
    }

    func setForcedProfile(id: String?) {
        mutate { $0.settings.forcedProfileID = id }
    }

    func setStrictMatching(_ value: Bool) {
        mutate { $0.settings.strictMatching = value }
    }

    func setEnabled(id: String, enabled: Bool) {
        mutate { store in
            guard let index = store.profiles.firstIndex(where: { $0.id == id }) else { return }
            store.profiles[index].enabled = enabled
        }
    }

    private func mutate(_ transform: (inout AgentProfileStore) -> Void) {
        do {
            let store = try agentRepository.mutateAgents { transform(&$0) }
            profiles = store.profiles
            settings = store.settings
        } catch {
            notice = NoticeMessage(style: .error, text: error.localizedDescription)
        }
    }
}
