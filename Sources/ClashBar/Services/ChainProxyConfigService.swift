import CryptoKit
import Foundation
import Yams

struct ChainProxyNode: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let name: String
    let yaml: String
}

struct ChainProxySettings: Codable, Equatable, Sendable {
    var enabled: Bool = false
    let id: UUID
    let landing: ChainProxyNode
}

enum ChainProxyConfigError: Error {
    case invalidConfig
    case invalidSelection
    case sourceChanged
    case invalidSavedSettings
    case invalidNodeConfig
    case invalidNodeLink
    case unsupportedNodeForm
}

enum ChainProxyConfigService {
    static func makeNode(id: String = UUID().uuidString, name: String, yaml: String) throws -> ChainProxyNode {
        do {
            var proxy = try self.parse(yaml)
            let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, !name.isEmpty,
                  let type = proxy["type"] as? String, !type.isEmpty,
                  !["direct", "reject", "reject-drop", "pass"].contains(type.lowercased()),
                  !(proxy["server"] as? String ?? "").trimmingCharacters(in: .whitespaces).isEmpty,
                  let port = proxy["port"] as? Int ?? Int(proxy["port"] as? String ?? ""), (1...65535).contains(port),
                  (proxy["dialer-proxy"] as? String ?? "").isEmpty
            else { throw ChainProxyConfigError.invalidNodeConfig }
            proxy["name"] = name
            return ChainProxyNode(
                id: id, name: name, yaml: try Yams.dump(object: proxy, allowUnicode: true, sortKeys: true))
        } catch {
            throw ChainProxyConfigError.invalidNodeConfig
        }
    }

    static func readNodes(workingDirectory: URL, settings: ChainProxySettings?) throws -> [ChainProxyNode] {
        let url = self.nodesURL(workingDirectory: workingDirectory)
        guard FileManager.default.fileExists(atPath: url.path) else {
            // Keep nodes saved by earlier versions available without consulting the airport profile.
            return settings.map { [$0.landing] } ?? []
        }
        let nodes = try JSONDecoder().decode([ChainProxyNode].self, from: Data(contentsOf: url))
        try self.validateNodes(nodes)
        return nodes
    }

    static func writeNodes(_ nodes: [ChainProxyNode], workingDirectory: URL) throws {
        try self.validateNodes(nodes)
        let url = self.nodesURL(workingDirectory: workingDirectory)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try self.writePrivateData(JSONEncoder().encode(nodes), to: url)
    }

    private static func nodesURL(workingDirectory: URL) -> URL {
        workingDirectory.appendingPathComponent("state").appendingPathComponent("chain-proxy-nodes.json")
    }

    private static func validateNodes(_ nodes: [ChainProxyNode]) throws {
        guard Set(nodes.map(\.id)).count == nodes.count, Set(nodes.map(\.name)).count == nodes.count else {
            throw ChainProxyConfigError.invalidNodeConfig
        }
        for node in nodes { _ = try self.makeNode(id: node.id, name: node.name, yaml: node.yaml) }
    }

    static func settingsURL(workingDirectory: URL) -> URL {
        workingDirectory.appendingPathComponent("state").appendingPathComponent("chain-proxy.json")
    }

    static func readSettings(workingDirectory: URL) throws -> ChainProxySettings? {
        let url = self.settingsURL(workingDirectory: workingDirectory)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let settings = try JSONDecoder().decode(ChainProxySettings.self, from: Data(contentsOf: url))
            try self.validate(settings)
            return settings
        } catch {
            throw ChainProxyConfigError.invalidSavedSettings
        }
    }

    static func writeSettings(_ settings: ChainProxySettings, workingDirectory: URL) throws {
        try self.validate(settings)
        let url = self.settingsURL(workingDirectory: workingDirectory)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(settings)
        try self.writePrivateData(data, to: url)
    }

    static func prepareRuntimeConfig(
        configURL: URL, workingDirectory: URL, settings: ChainProxySettings?) throws -> URL
    {
        guard let settings, settings.enabled else { return configURL }
        let source = try String(contentsOf: configURL, encoding: .utf8)
        let yaml = try self.compose(sourceYAML: source, settings: settings)
        let directory = workingDirectory.appendingPathComponent("runtime", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Immutable content paths keep concurrent validation and subscription reloads isolated.
        let hash = SHA256.hash(data: Data(yaml.utf8)).map { String(format: "%02x", $0) }.joined()
        let runtimeURL = directory.appendingPathComponent("chain-\(hash).yaml")
        try self.writePrivateData(Data(yaml.utf8), to: runtimeURL)
        return runtimeURL
    }

    static func globalFrontName(id: UUID) -> String {
        "ClashBar_Airport_GLOBAL_\(id.uuidString)"
    }

    static func compose(sourceYAML: String, settings: ChainProxySettings) throws -> String {
        try self.validate(settings)
        guard settings.enabled else { return sourceYAML }
        var config = try self.parse(sourceYAML)
        var proxies = config["proxies"] as? [[String: Any]] ?? []
        var groups = config["proxy-groups"] as? [[String: Any]] ?? []
        var names = Set(proxies.compactMap { $0["name"] as? String })
        names.formUnion(groups.compactMap { $0["name"] as? String })
        let prefix = "ClashBar Exit \(settings.id.uuidString) via "
        let globalFront = self.globalFrontName(id: settings.id)
        guard !names.contains(globalFront) else { throw ChainProxyConfigError.invalidConfig }
        let directTypes: Set<String> = ["direct", "reject", "reject-drop", "pass"]
        let bypassNames = Set(proxies.compactMap { proxy -> String? in
            guard directTypes.contains((proxy["type"] as? String ?? "").lowercased()) else { return nil }
            return proxy["name"] as? String
        }).union(["DIRECT", "REJECT", "REJECT-DROP", "PASS", "PASS-RULE"])
        let landing = try self.parse(settings.landing.yaml)
        let mainFront = self.mainFrontName(groups: groups, fallback: globalFront)
        let mainExit = prefix + mainFront
        let globalExit = prefix + "GLOBAL"
        guard !names.contains(mainExit), !names.contains(globalExit) else {
            throw ChainProxyConfigError.invalidConfig
        }
        var mainProxy = landing
        mainProxy["name"] = mainExit
        mainProxy["dialer-proxy"] = mainFront
        var globalProxy = landing
        globalProxy["name"] = globalExit
        globalProxy["dialer-proxy"] = globalFront
        // Keep airport groups and their selections intact. Exclude only injected exits from include-all.
        for index in groups.indices where groups[index]["include-all"] as? Bool == true
            || groups[index]["include-all-proxies"] as? Bool == true
        {
            let filter = groups[index]["exclude-filter"] as? String ?? ""
            let exclude = "^" + NSRegularExpression.escapedPattern(for: prefix)
            groups[index]["exclude-filter"] = filter.isEmpty ? exclude : "(\(filter))|\(exclude)"
        }
        var global = groups.first { $0["name"] as? String == "GLOBAL" } ?? [
            "name": "GLOBAL", "type": "select",
            "proxies": groups.compactMap { $0["name"] as? String }
                + proxies.compactMap { $0["name"] as? String } + ["DIRECT", "REJECT"],
        ]
        global["name"] = globalFront
        global["hidden"] = true
        groups.removeAll { $0["name"] as? String == "GLOBAL" }
        groups.append(global)
        proxies += [mainProxy, globalProxy]
        groups.append(["name": "GLOBAL", "type": "select", "proxies": [globalExit]])
        if let rules = config["rules"] as? [String] {
            config["rules"] = rules.map { self.route($0, bypassNames: bypassNames, mainExit: mainExit, globalExit: globalExit) }
        }
        if let subRules = config["sub-rules"] as? [String: [String]] {
            config["sub-rules"] = subRules.mapValues { rules in
                rules.map { self.route($0, bypassNames: bypassNames, mainExit: mainExit, globalExit: globalExit) }
            }
        }
        config["proxies"] = proxies
        config["proxy-groups"] = groups
        return try Yams.dump(object: config, allowUnicode: true, sortKeys: true)
    }

    static func mainFrontName(groups: [[String: Any]], fallback: String) -> String {
        let groupOrder = groups.first { $0["name"] as? String == "GLOBAL" }?["proxies"] as? [String]
            ?? groups.compactMap { $0["name"] as? String }
        return groupOrder.first { name in
            name != "GLOBAL" && groups.contains { $0["name"] as? String == name && $0["type"] as? String == "select" }
        } ?? groupOrder.first { $0 != "GLOBAL" } ?? fallback
    }

    private static func route(
        _ rule: String, bypassNames: Set<String>, mainExit: String, globalExit: String) -> String
    {
        var parts = rule.components(separatedBy: ",")
        guard parts.count >= 2, parts[0].trimmingCharacters(in: .whitespaces).uppercased() != "SUB-RULE" else {
            return rule
        }
        var index = parts.count - 1
        while index > 0, ["no-resolve", "src"].contains(parts[index].trimmingCharacters(in: .whitespaces)) {
            index -= 1
        }
        guard !bypassNames.contains(parts[index].trimmingCharacters(in: .whitespaces)) else { return rule }
        parts[index] = parts[index].trimmingCharacters(in: .whitespaces) == "GLOBAL" ? globalExit : mainExit
        return parts.joined(separator: ",")
    }

    private static func validate(_ settings: ChainProxySettings) throws {
        _ = try self.makeNode(id: settings.landing.id, name: settings.landing.name, yaml: settings.landing.yaml)
    }

    private static func writePrivateData(_ data: Data, to url: URL) throws {
        // Node snapshots contain credentials and are stored outside the airport configuration directory.
        try (data as NSData).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func parse(_ raw: String) throws -> [String: Any] {
        do {
            guard let config = try Yams.load(yaml: raw) as? [String: Any] else {
                throw ChainProxyConfigError.invalidConfig
            }
            return config
        } catch {
            // Parser diagnostics can contain credentials from the YAML source.
            throw ChainProxyConfigError.invalidConfig
        }
    }

}
