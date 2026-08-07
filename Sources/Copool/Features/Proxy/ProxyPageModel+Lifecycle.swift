import Foundation

extension ProxyPageModel {
    func bootstrapOnAppLaunch(using settings: AppSettings) async {
        guard !didRunLaunchBootstrap else { return }
        didRunLaunchBootstrap = true

        applySettings(settings)
        if usesRemoteMacControl {
            await refreshRemoteSnapshot(showErrors: false)
            if shouldRequestRemoteSnapshotRefresh() {
                await requestRemoteSnapshotRefresh(showErrors: false)
            }
            startRemoteSnapshotSyncIfNeeded()
            return
        }

        stopRemoteSnapshotSync()

        // 先收敛残留的托管块（A2）。放在 autoStart 判断之前：上一次异常退出留下
        // 的托管块指向一个没人监听的端口，此时不管要不要自动启动，它都得清掉，
        // 否则 ChatGPT.app 里第三方模型全是死路。自动启动会紧接着重新写入。
        let didReconcile = await coordinator.reconcileProviderSplitOnLaunch()

        await refreshLocalRuntimeStatus()

        guard settings.autoStartApiProxy, !proxyStatus.running else {
            // 只在不会立刻重启代理时提示——马上就要恢复的话，提示"已停服"只会
            // 让用户困惑（A3）。
            if didReconcile {
                notice = NoticeMessage(style: .info, text: L10n.tr("proxy.split.recovered"))
            }
            return
        }

        do {
            proxyStatus = try await coordinator.startProxy(preferredPort: nil)
            await refreshLocalRuntimeStatus()
        } catch {
            notice = NoticeMessage(style: .error, text: error.localizedDescription)
        }
    }

    func loadIfNeeded() async {
        if !hasLoaded {
            await load()
        } else {
            await refreshForTabEntry()
        }
    }

    func refreshForTabEntry() async {
        if usesRemoteMacControl {
            await refreshRemoteSnapshot(showErrors: false)
            if shouldRequestRemoteSnapshotRefresh() {
                await requestRemoteSnapshotRefresh(showErrors: false)
            }
            return
        }

        do {
            let settings = try await settingsCoordinator.currentSettings()
            applySettings(settings)
            await refreshLocalRuntimeStatus()
        } catch {
            notice = NoticeMessage(style: .error, text: error.localizedDescription)
        }
    }

    func load() async {
        loading = true
        defer { loading = false }

        do {
            let settings = try await settingsCoordinator.currentSettings()
            applySettings(settings)
            if usesRemoteMacControl {
                await refreshRemoteSnapshot(showErrors: true)
                if shouldRequestRemoteSnapshotRefresh() {
                    await requestRemoteSnapshotRefresh(showErrors: false)
                }
                startRemoteSnapshotSyncIfNeeded()
            } else {
                stopRemoteSnapshotSync()
                await refreshLocalRuntimeStatus()
                await refreshAllRemoteStatuses()
            }
            hasLoaded = true
        } catch {
            notice = NoticeMessage(style: .error, text: error.localizedDescription)
        }
    }
}
