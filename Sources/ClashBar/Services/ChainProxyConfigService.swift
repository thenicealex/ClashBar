import CryptoKit
import Foundation
import Yams

struct ChainProxyNode: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let name: String
    let yaml: String
}

struct ChainProxyFrontSelection: Codable, Equatable, Sendable {
    let group: String
    let node: String
}

struct ChainProxySettings: Codable, Equatable, Sendable {
    var enabled: Bool = false
    let id: UUID
    let landing: ChainProxyNode
}

struct ChainProxyRuntimeConfig: Sendable {
    let url: URL
    let isChained: Bool
}

enum ChainProxyConfigError: Error {
    case invalidConfig
    case missingAirportFront
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

    static func airportProxies(source: [String: Any], workingDirectory: URL) -> [[String: Any]] {
        var proxies = source["proxies"] as? [[String: Any]] ?? []
        for provider in (source["proxy-providers"] as? [String: [String: Any]] ?? [:]).values {
            var nodes = provider["payload"] as? [[String: Any]] ?? []
            let path = (provider["path"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (provider["url"] as? String).map {
                "proxies/" + Insecure.MD5.hash(data: Data($0.utf8)).map { String(format: "%02x", $0) }.joined()
            }
            if let path {
                let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : workingDirectory.appendingPathComponent(path)
                if let yaml = try? String(contentsOf: url, encoding: .utf8),
                   let cache = try? Yams.load(yaml: yaml) as? [String: Any],
                   let cached = cache["proxies"] as? [[String: Any]] { nodes = cached }
            }
            let overrides = provider["override"] as? [String: Any] ?? [:]
            // Expression overrides require the core's evaluator; never test an approximation.
            if overrides["override-expr"] != nil { continue }
            for var node in nodes {
                guard var name = node["name"] as? String,
                      self.proxyPassesFilters(node, options: provider, include: true) else { continue }
                for replacement in overrides["proxy-name"] as? [[String: String]] ?? [] {
                    if let pattern = replacement["pattern"], let target = replacement["target"],
                       let regex = try? NSRegularExpression(pattern: pattern)
                    {
                        name = regex.stringByReplacingMatches(
                            in: name, range: NSRange(name.startIndex..., in: name), withTemplate: target)
                    }
                }
                node.merge(overrides.filter { !["additional-prefix", "additional-suffix", "proxy-name"].contains($0.key) }) {
                    _, override in override
                }
                node["name"] = (overrides["additional-prefix"] as? String ?? "") + name
                    + (overrides["additional-suffix"] as? String ?? "")
                if node["dialer-proxy"] == nil { node["dialer-proxy"] = provider["dialer-proxy"] }
                proxies.append(node)
            }
        }
        return proxies
    }

    private static func proxyPassesFilters(_ proxy: [String: Any], options: [String: Any], include: Bool) -> Bool {
        guard let name = proxy["name"] as? String else { return false }
        func matches(_ pattern: String) -> Bool? {
            var matched = false
            for part in pattern.components(separatedBy: "`") {
                guard let regex = try? NSRegularExpression(pattern: part) else { return nil }
                matched = matched || regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
            }
            return matched
        }
        if include, let filter = options["filter"] as? String, !filter.isEmpty, matches(filter) != true { return false }
        if let exclude = options["exclude-filter"] as? String, !exclude.isEmpty, matches(exclude) != false { return false }
        let types = (options["exclude-type"] as? String ?? "").lowercased().components(separatedBy: "|")
        return !types.contains((proxy["type"] as? String ?? "").lowercased())
    }

    static func frontIsAvailable(_ front: ChainProxyFrontSelection, source: [String: Any], workingDirectory: URL) -> Bool {
        let groups = source["proxy-groups"] as? [[String: Any]] ?? []
        let staticProxies = source["proxies"] as? [[String: Any]] ?? []
        let providers = source["proxy-providers"] as? [String: [String: Any]] ?? [:]
        let group = groups.first { $0["name"] as? String == front.group }
        guard let group else {
            return front.group == "GLOBAL" && (groups + staticProxies).contains { $0["name"] as? String == front.node }
        }
        var candidates = (groups + staticProxies).filter {
            (group["proxies"] as? [String] ?? []).contains($0["name"] as? String ?? "")
        }
        let all = group["include-all"] as? Bool == true
        if all || group["include-all-proxies"] as? Bool == true {
            candidates += staticProxies.filter { self.proxyPassesFilters($0, options: group, include: true) }
        }
        let used = all || group["include-all-providers"] as? Bool == true
            ? Array(providers.keys) : group["use"] as? [String] ?? []
        let providerSource: [String: Any] = ["proxy-providers": providers.filter { used.contains($0.key) }]
        candidates += self.airportProxies(source: providerSource, workingDirectory: workingDirectory)
            .filter { self.proxyPassesFilters($0, options: group, include: true) }
        return candidates.contains {
            $0["name"] as? String == front.node
                && !["direct", "reject", "reject-drop", "pass"].contains(($0["type"] as? String ?? "").lowercased())
                && self.proxyPassesFilters($0, options: group, include: false)
        }
    }

    static func frontKey(for configURL: URL) -> String {
        configURL.standardizedFileURL.resolvingSymlinksInPath().path
    }

    static func readFrontSelections(workingDirectory: URL) throws -> [String: ChainProxyFrontSelection] {
        let url = workingDirectory.appendingPathComponent("state/chain-proxy-fronts.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        return try JSONDecoder().decode([String: ChainProxyFrontSelection].self, from: Data(contentsOf: url))
    }

    static func writeFrontSelections(_ selections: [String: ChainProxyFrontSelection], workingDirectory: URL) throws {
        let url = workingDirectory.appendingPathComponent("state/chain-proxy-fronts.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try self.writePrivateData(JSONEncoder().encode(selections), to: url)
    }

    static func prepareRuntimeConfig(
        configURL: URL, workingDirectory: URL, settings: ChainProxySettings?, front: ChainProxyFrontSelection?) throws -> ChainProxyRuntimeConfig
    {
        guard let settings, settings.enabled, let front else { return ChainProxyRuntimeConfig(url: configURL, isChained: false) }
        let source = try String(contentsOf: configURL, encoding: .utf8)
        let config = try self.parse(source)
        guard self.frontIsAvailable(front, source: config, workingDirectory: workingDirectory)
        else { return ChainProxyRuntimeConfig(url: configURL, isChained: false) }
        let yaml = try self.compose(sourceYAML: source, settings: settings, front: front)
        let directory = workingDirectory.appendingPathComponent("runtime", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Immutable content paths keep concurrent validation and subscription reloads isolated.
        let hash = SHA256.hash(data: Data(yaml.utf8)).map { String(format: "%02x", $0) }.joined()
        let runtimeURL = directory.appendingPathComponent("chain-\(hash).yaml")
        try self.writePrivateData(Data(yaml.utf8), to: runtimeURL)
        return ChainProxyRuntimeConfig(url: runtimeURL, isChained: true)
    }

    static func globalFrontName(id: UUID) -> String {
        "ClashBar_Airport_GLOBAL_\(id.uuidString)"
    }

    static func compose(sourceYAML: String, settings: ChainProxySettings, front: ChainProxyFrontSelection?) throws -> String {
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
        guard let front, groups.contains(where: { $0["name"] as? String == front.group }) || front.group == "GLOBAL" else {
            throw ChainProxyConfigError.missingAirportFront
        }
        let frontGroup = front.group == "GLOBAL" ? globalFront : front.group
        for index in groups.indices where groups[index]["name"] as? String == front.group {
            groups[index]["default-selected"] = front.node
        }
        let exitName = prefix + frontGroup
        guard !names.contains(exitName) else {
            throw ChainProxyConfigError.invalidConfig
        }
        var exitProxy = landing
        exitProxy["name"] = exitName
        exitProxy["dialer-proxy"] = frontGroup
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
        if front.group == "GLOBAL" { global["default-selected"] = front.node }
        global["name"] = globalFront
        global["hidden"] = true
        groups.removeAll { $0["name"] as? String == "GLOBAL" }
        groups.append(global)
        proxies.append(exitProxy)
        groups.append(["name": "GLOBAL", "type": "select", "proxies": [exitName]])
        if let rules = config["rules"] as? [String] {
            config["rules"] = rules.map { self.route($0, bypassNames: bypassNames, exitName: exitName) }
        }
        if let subRules = config["sub-rules"] as? [String: [String]] {
            config["sub-rules"] = subRules.mapValues { rules in
                rules.map { self.route($0, bypassNames: bypassNames, exitName: exitName) }
            }
        }
        config["proxies"] = proxies
        config["proxy-groups"] = groups
        return try Yams.dump(object: config, allowUnicode: true, sortKeys: true)
    }

    private static func route(
        _ rule: String, bypassNames: Set<String>, exitName: String) -> String
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
        parts[index] = exitName
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
