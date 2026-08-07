import Foundation

extension ProxyPageModel {
    func refreshStatus() async {
        if usesRemoteMacControl {
            await requestRemoteSnapshotRefresh(showErrors: true, showLoading: true)
            return
        }
        loading = true
        defer { loading = false }
        do {
            let snapshot = try await performLocalCommand(kind: .refreshStatus)
            applyRemoteSnapshot(snapshot)
        } catch {
            notice = NoticeMessage(style: .error, text: error.localizedDescription)
        }
    }

    func startProxy() async {
        if usesRemoteMacControl {
            await performRemoteCommand(
                kind: .startProxy,
                preferredProxyPort: Int(preferredPortText),
                proxyConfiguration: currentProxyConfiguration,
                successNotice: L10n.tr("proxy.notice.api_proxy_started")
            )
            return
        }
        loading = true
        defer { loading = false }

        let preferredPort = Int(preferredPortText)

        do {
            let snapshot = try await performLocalCommand(
                kind: .startProxy,
                preferredProxyPort: preferredPort,
                proxyConfiguration: currentProxyConfiguration
            )
            applyRemoteSnapshot(snapshot)
            notice = NoticeMessage(style: .success, text: L10n.tr("proxy.notice.api_proxy_started"))
        } catch {
            notice = NoticeMessage(style: .error, text: error.localizedDescription)
        }
    }

    func stopProxy() async {
        if usesRemoteMacControl {
            await performRemoteCommand(
                kind: .stopProxy,
                successNotice: L10n.tr("proxy.notice.api_proxy_stopped")
            )
            return
        }
        loading = true
        defer { loading = false }

        do {
            let snapshot = try await performLocalCommand(kind: .stopProxy)
            applyRemoteSnapshot(snapshot)
            notice = NoticeMessage(style: .info, text: L10n.tr("proxy.notice.api_proxy_stopped"))
        } catch {
            notice = NoticeMessage(style: .error, text: error.localizedDescription)
        }
    }

    func refreshAPIKey() async {
        if usesRemoteMacControl {
            await performRemoteCommand(
                kind: .refreshAPIKey,
                successNotice: L10n.tr("proxy.notice.api_key_refreshed")
            )
            return
        }
        loading = true
        defer { loading = false }

        do {
            let snapshot = try await performLocalCommand(kind: .refreshAPIKey)
            applyRemoteSnapshot(snapshot)
            notice = NoticeMessage(style: .success, text: L10n.tr("proxy.notice.api_key_refreshed"))
        } catch {
            notice = NoticeMessage(style: .error, text: error.localizedDescription)
        }
    }

    func setAutoStartProxy(_ value: Bool) async {
        if usesRemoteMacControl {
            autoStartProxy = value
            await performRemoteCommand(
                kind: .setAutoStartProxy,
                autoStartProxy: value,
                successNotice: L10n.tr("proxy.notice.auto_start_updated")
            )
            return
        }
        do {
            let snapshot = try await performLocalCommand(
                kind: .setAutoStartProxy,
                autoStartProxy: value
            )
            applyRemoteSnapshot(snapshot)
            notice = NoticeMessage(style: .success, text: L10n.tr("proxy.notice.auto_start_updated"))
        } catch {
            notice = NoticeMessage(style: .error, text: error.localizedDescription)
        }
    }

    func refreshLocalRuntimeStatus() async {
        let pair = await coordinator.loadStatus()
        proxyStatus = pair.0
        applyCloudflaredStatus(pair.1)
        onProviderSplitStateChanged?()
    }
}
