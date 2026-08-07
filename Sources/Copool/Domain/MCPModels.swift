import Foundation

struct MCPServerRecord: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var name: String
    var targetID: String
    var command: String?
    var endpoint: String?
    var toolNames: [String]
    var permission: Permission
    var status: Status

    enum Permission: String, Codable, Equatable, Sendable {
        case unknown
        case allowed
        case denied
        case reviewRequired
    }

    enum Status: String, Codable, Equatable, Sendable {
        case discovered
        case invalid
        case unavailable
    }
}

struct MCPDiscoveryReport: Codable, Equatable, Sendable {
    var targetID: String
    var sourcePath: String
    var servers: [MCPServerRecord]
    var warnings: [String]
}

protocol MCPDiscoveryService: Sendable {
    func discover(targetID: String) -> MCPDiscoveryReport
}

struct FileMCPDiscoveryService: MCPDiscoveryService {
    var configPaths: [String: URL]

    func discover(targetID: String) -> MCPDiscoveryReport {
        guard let path = configPaths[targetID] else {
            return MCPDiscoveryReport(targetID: targetID, sourcePath: "", servers: [], warnings: ["No target MCP config path configured"])
        }
        guard let data = try? Data(contentsOf: path) else {
            return MCPDiscoveryReport(targetID: targetID, sourcePath: path.path, servers: [], warnings: ["MCP config is unavailable"])
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return MCPDiscoveryReport(targetID: targetID, sourcePath: path.path, servers: [], warnings: ["MCP config is not valid JSON"])
        }
        let rawServers = root["mcpServers"] as? [String: Any] ?? root["servers"] as? [String: Any] ?? [:]
        var servers: [MCPServerRecord] = []
        var warnings: [String] = []
        for (name, value) in rawServers {
            guard let config = value as? [String: Any] else {
                warnings.append("Server \(name) has an invalid configuration")
                continue
            }
            let command = config["command"] as? String
            let endpoint = config["url"] as? String ?? config["endpoint"] as? String
            let tools = (config["tools"] as? [String]) ?? []
            let permission: MCPServerRecord.Permission = config["disabled"] as? Bool == true ? .denied : .reviewRequired
            let status: MCPServerRecord.Status = command == nil && endpoint == nil ? .invalid : .discovered
            servers.append(MCPServerRecord(
                id: "\(targetID):\(name)",
                name: name,
                targetID: targetID,
                command: command,
                endpoint: endpoint,
                toolNames: tools,
                permission: permission,
                status: status
            ))
        }
        return MCPDiscoveryReport(targetID: targetID, sourcePath: path.path, servers: servers.sorted { $0.name < $1.name }, warnings: warnings)
    }
}
