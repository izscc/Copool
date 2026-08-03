import Foundation

struct RemoteServerHeaderPresentation: Equatable {
    let title: String
    let subtitle: String?
    let statusLabel: String
    let isRunning: Bool
}

struct RemoteServerMetricDescriptor: Identifiable, Equatable {
    let title: String
    let value: String

    var id: String { title }
}

struct RemoteServerDetailDescriptor: Identifiable, Equatable {
    let title: String
    let value: String
    let canCopy: Bool

    var id: String { title }
}

struct RemoteServerLogsPresentation: Equatable {
    let content: String
    let canCopy: Bool
}

struct RemoteServerDiscoveryPresentation: Equatable {
    let title: String
    let items: [RemoteServerDiscoveryItemPresentation]
}

struct RemoteServerDiscoveryItemPresentation: Identifiable, Equatable {
    let instance: DiscoveredRemoteProxyInstance
    let label: String
    let serviceName: String
    let remoteDir: String
    let listenPort: String
    let statusSummary: String
    let baseURL: String
    let apiKeyLabel: String

    var id: String { serviceName }
}

enum RemoteServerCardPresentation {
    static func header(
        label: String,
        sshUser: String,
        host: String,
        sshPort: Int,
        isExpanded: Bool,
        status: RemoteProxyStatus?
    ) -> RemoteServerHeaderPresentation {
        RemoteServerHeaderPresentation(
            title: label.isEmpty ? RemoteServerConfiguration.defaultLabel : label,
            subtitle: isExpanded ? nil : "\(sshUser)@\(host):\(sshPort)",
            statusLabel: RemoteServerConfiguration.statusLabel(status),
            isRunning: status?.running == true
        )
    }

    static func metrics(
        status: RemoteProxyStatus?
    ) -> [RemoteServerMetricDescriptor] {
        [
            RemoteServerMetricDescriptor(title: L10n.tr("proxy.status.installed"), value: RemoteServerConfiguration.boolText(status?.installed)),
            RemoteServerMetricDescriptor(title: "Systemd", value: RemoteServerConfiguration.boolText(status?.serviceInstalled)),
            RemoteServerMetricDescriptor(title: L10n.tr("settings.launch_at_startup"), value: RemoteServerConfiguration.boolText(status?.enabled)),
            RemoteServerMetricDescriptor(title: L10n.tr("proxy.status.running"), value: RemoteServerConfiguration.boolText(status?.running)),
            RemoteServerMetricDescriptor(title: "PID", value: status?.pid.map(String.init) ?? "--")
        ]
    }

    static func details(
        status: RemoteProxyStatus?
    ) -> [RemoteServerDetailDescriptor] {
        [
            RemoteServerDetailDescriptor(
                title: L10n.tr("proxy.detail.base_url"),
                value: status?.baseURL ?? "--",
                canCopy: status != nil
            ),
            RemoteServerDetailDescriptor(
                title: L10n.tr("proxy.detail.api_key"),
                value: status?.apiKey ?? L10n.tr("proxy.value.generated_after_first_start"),
                canCopy: status?.apiKey != nil
            ),
            RemoteServerDetailDescriptor(
                title: L10n.tr("proxy.remote.service_name"),
                value: status?.serviceName ?? L10n.tr("common.unknown"),
                canCopy: status != nil
            )
        ]
    }

    static func logs(
        logs: String?
    ) -> RemoteServerLogsPresentation {
        let content = logs?.isEmpty == false
            ? logs!
            : L10n.tr("proxy.remote.logs.not_loaded")
        return RemoteServerLogsPresentation(
            content: content,
            canCopy: !(logs ?? "").isEmpty
        )
    }

    static func discovery(
        instances: [DiscoveredRemoteProxyInstance]
    ) -> RemoteServerDiscoveryPresentation? {
        guard !instances.isEmpty else { return nil }

        return RemoteServerDiscoveryPresentation(
            title: L10n.tr("proxy.remote.discovery.title"),
            items: instances.map { instance in
                RemoteServerDiscoveryItemPresentation(
                    instance: instance,
                    label: discoveryLabel(for: instance),
                    serviceName: instance.serviceName,
                    remoteDir: instance.remoteDir,
                    listenPort: String(instance.listenPort),
                    statusSummary: discoveryStatusSummary(for: instance),
                    baseURL: instance.baseURL,
                    apiKeyLabel: instance.apiKeyPresent
                        ? L10n.tr("proxy.remote.discovery.api_key_present")
                        : L10n.tr("proxy.remote.discovery.api_key_missing")
                )
            }
        )
    }

    private static func discoveryStatusSummary(
        for instance: DiscoveredRemoteProxyInstance
    ) -> String {
        [
            L10n.tr(
                instance.running
                    ? "proxy.remote.discovery.state.running"
                    : "proxy.remote.discovery.state.stopped"
            ),
            L10n.tr(
                instance.enabled
                    ? "proxy.remote.discovery.state.enabled"
                    : "proxy.remote.discovery.state.disabled"
            ),
            L10n.tr(
                instance.installed
                    ? "proxy.remote.discovery.state.binary_present"
                    : "proxy.remote.discovery.state.binary_missing"
            )
        ]
        .joined(separator: " · ")
    }

    private static func discoveryLabel(
        for instance: DiscoveredRemoteProxyInstance
    ) -> String {
        guard let label = instance.label?.trimmingCharacters(in: .whitespacesAndNewlines),
              !label.isEmpty else {
            return instance.serviceName
        }
        return label
    }
}
