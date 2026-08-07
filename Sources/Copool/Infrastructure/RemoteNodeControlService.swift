import Foundation

/// Real node control over the existing SSH transport (AC-204): version
/// handshake, liveness heartbeat, upgrade and rollback against a remote
/// router node. The heartbeat payload contract is enforced by
/// `RemoteHeartbeat.validateNoSecrets` — the wire format carries identity +
/// status + counters only.
struct RemoteNodeControlService {
    let shellRunner: RemoteShellCommandRunner
    let monitor: HeartbeatMonitor
    let appVersion: String
    let now: @Sendable () -> Int64

    init(
        shellRunner: RemoteShellCommandRunner = RemoteShellCommandRunner(fileManager: .default),
        monitor: HeartbeatMonitor = HeartbeatMonitor(),
        appVersion: String = {
            Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        }(),
        now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970) }
    ) {
        self.shellRunner = shellRunner
        self.monitor = monitor
        self.appVersion = appVersion
        self.now = now
    }

    /// Reads the node's identity file (`node-info.json` under the remote
    /// proxyd data dir) and evaluates protocol compatibility. Returns nil
    /// when the node does not expose node-info (pre-protocol install).
    func handshake(server: RemoteServerConfig) throws -> RemoteHandshake? {
        let raw = try shellRunner.runSSH(
            server: server,
            command: "cat ~/.codex-tools-proxyd/node-info.json 2>/dev/null || echo '{}'"
        )
        guard let data = raw.data(using: .utf8),
              let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = info["version"] as? String else {
            return nil
        }
        let nodeProtocol = info["protocolVersion"] as? Int ?? 0
        return RemoteHandshake.evaluate(appVersion: appVersion, nodeVersion: version, nodeProtocol: nodeProtocol)
    }

    /// Remote liveness probe: curls the node's own health endpoint and folds
    /// the result into the heartbeat monitor. The returned node carries the
    /// monitor-derived status.
    func heartbeat(server: RemoteServerConfig, node: RemoteNode, port: Int) throws -> RemoteNode {
        let raw = try shellRunner.runSSH(
            server: server,
            command: "curl -s -m 5 http://127.0.0.1:\(port)/health 2>/dev/null || echo '{}'"
        )
        let alive = raw.contains("\"ok\":true") || raw.contains("\"ok\": true")
        var updated = node
        if alive {
            updated.lastHeartbeatAt = now()
        }
        updated.status = monitor.status(lastHeartbeatAt: updated.lastHeartbeatAt, pendingOperation: node.pendingOperation)
        return updated
    }

    /// Upgrades a node: uploads the new binary via SCP into the stage
    /// directory, then swaps + restarts through the deployment plan's
    /// install command. The node is marked `.updating` for the duration
    /// (upgrade gate, AC-204).
    func upgrade(server: RemoteServerConfig, node: RemoteNode, binaryPath: String) throws -> RemoteNode {
        var updating = monitor.beginUpgrade(node: node)
        let serviceName = RemoteProxyDeploymentPlan.serviceName(for: server.id)
        let stage = RemoteProxyDeploymentPlan.stageDirectory(serverID: server.id, unixTime: Int(now()))
        do {
            try shellRunner.runSCP(server: server, localPath: binaryPath, remotePath: "\(stage)/copool-router")
            let install = RemoteProxyDeploymentPlan.renderInstallCommand(
                server: server,
                serviceName: serviceName,
                stageDir: stage,
                shellQuote: shellRunner.shellQuote
            )
            _ = try shellRunner.runSSH(server: server, command: install)
            guard let handshake = try handshake(server: server), handshake.accepted else {
                updating.pendingOperation = nil
                updating.status = .degraded
                throw AppError.network("Remote node upgrade handshake failed")
            }
            updating = monitor.completeUpgrade(node: updating, newVersion: handshake.nodeVersion)
        } catch {
            updating.pendingOperation = nil
            updating.status = node.status
            throw error
        }
        return updating
    }

    /// Rolls back to the previous binary: the install command keeps a
    /// `previous-version` copy; this restores it and restarts the service.
    func rollback(server: RemoteServerConfig, node: RemoteNode) throws -> RemoteNode {
        var updating = monitor.beginUpgrade(node: node)
        updating.pendingOperation = "rollback"
        let serviceName = RemoteProxyDeploymentPlan.serviceName(for: server.id)
        let command = """
        set -e
        APP=~/.codex-tools-proxyd/bin/copool-router
        if [ -f "$APP.previous-version" ]; then
          cp "$APP.previous-version" "$APP"
          chmod +x "$APP"
        fi
        systemctl --user restart \(shellRunner.shellQuote(serviceName)) 2>/dev/null || true
        echo done
        """
        do {
            _ = try shellRunner.runSSH(server: server, command: command)
            // Verify the service actually restarted (review: the previous
            // `|| true` swallowed restart failures and still marked online).
            let health = try shellRunner.runSSH(
                server: server,
                command: "sleep 1; curl -s -m 5 http://127.0.0.1:\(server.listenPort)/health 2>/dev/null || echo '{}'"
            )
            let alive = health.contains("\"ok\":true") || health.contains("\"ok\": true")
            updating.pendingOperation = nil
            if alive {
                updating.lastHeartbeatAt = now()
                updating.status = .online
            } else {
                updating.status = .degraded
            }
        } catch {
            updating.pendingOperation = nil
            updating.status = node.status
            throw error
        }
        return updating
    }
}
