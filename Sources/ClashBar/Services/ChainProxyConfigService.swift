import CryptoKit
import Foundation
import Yams

struct ChainProxyNode: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let name: String
    let source: String
    let yaml: String
}

struct ChainProxyConfigSnapshot: Sendable {
    let sourceURL: URL
    let nodes: [ChainProxyNode]
    let unavailableProviders: [String]
}

struct ChainProxySettings: Codable, Equatable, Sendable {
    var enabled: Bool
    let id: UUID
    let front: ChainProxyNode
    let landing: ChainProxyNode
}

enum ChainProxyConfigError: Error {
    case invalidConfig
    case invalidSelection
    case sourceChanged
    case invalidSavedSettings
}

enum ChainProxyConfigService {
    static func load(configURL: URL, workingDirectory: URL) throws -> ChainProxyConfigSnapshot {
        let raw = try String(contentsOf: configURL, encoding: .utf8)
        let config = try self.parse(raw)

        var nodes = try self.nodes(
            from: config["proxies"] as? [[String: Any]] ?? [],
            source: configURL.lastPathComponent,
            idPrefix: "config:\(configURL.lastPathComponent)")
        var unavailableProviders: [String] = []
        let providers = config["proxy-providers"] as? [String: [String: Any]] ?? [:]
        for name in providers.keys.sorted() {
            guard let provider = providers[name] else { continue }
            do {
                // Expressions require mihomo's own evaluator. Do not silently copy unmodified nodes.
                var override = provider["override"] as? [String: Any] ?? [:]
                if override["dialer-proxy"] == nil { override["dialer-proxy"] = provider["dialer-proxy"] }
                guard override["override-expr"] == nil, provider["age-secret-key"] == nil else {
                    throw ChainProxyConfigError.invalidConfig
                }
                let payload = try self.providerPayload(provider, workingDirectory: workingDirectory)
                // mihomo filters raw names before applying provider overrides.
                let filtered = try payload.filter { try self.includes($0, provider: provider) }
                let overridden = try filtered.map { try self.applyOverride(override, to: $0) }
                nodes += try self.nodes(
                    from: overridden,
                    source: "\(configURL.lastPathComponent) · \(name)",
                    idPrefix: "provider:\(configURL.lastPathComponent):\(name)")
            } catch {
                unavailableProviders.append(name)
            }
        }
        nodes.sort {
            if $0.name == $1.name { return $0.source.localizedStandardCompare($1.source) == .orderedAscending }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        return ChainProxyConfigSnapshot(
            sourceURL: configURL,
            nodes: nodes,
            unavailableProviders: unavailableProviders)
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

    static func compose(sourceYAML: String, settings: ChainProxySettings) throws -> String {
        try self.validate(settings)
        guard settings.enabled else { return sourceYAML }
        var config = try self.parse(sourceYAML)
        var proxies = config["proxies"] as? [[String: Any]] ?? []
        var groups = config["proxy-groups"] as? [[String: Any]] ?? []
        var names = Set(proxies.compactMap { $0["name"] as? String })
        names.formUnion(groups.compactMap { $0["name"] as? String })
        let suffix = settings.id.uuidString
        let frontName = self.uniqueName("ClashBar Front \(suffix)", names: &names)
        let landingName = self.uniqueName("ClashBar Landing \(suffix)", names: &names)
        let groupName = self.uniqueName("ClashBar Chain \(suffix)", names: &names)
        var frontProxy = try self.parse(settings.front.yaml)
        var landingProxy = try self.parse(settings.landing.yaml)
        frontProxy["name"] = frontName
        landingProxy["name"] = landingName
        landingProxy["dialer-proxy"] = frontName
        proxies += [frontProxy, landingProxy]
        groups.insert(["name": groupName, "type": "select", "proxies": [landingName]], at: 0)
        // Keep global mode on the independent chain as well, including across config switches.
        groups.removeAll { $0["name"] as? String == "GLOBAL" }
        groups.append(["name": "GLOBAL", "type": "select", "proxies": [groupName]])
        config["proxies"] = proxies
        config["proxy-groups"] = groups
        let directTypes: Set<String> = ["direct", "reject", "reject-drop", "pass"]
        let bypassNames = Set(proxies.compactMap { proxy -> String? in
            guard directTypes.contains((proxy["type"] as? String ?? "").lowercased()) else { return nil }
            return proxy["name"] as? String
        }).union(["DIRECT", "REJECT", "REJECT-DROP", "PASS", "PASS-RULE"])
        if let rules = config["rules"] as? [String] {
            config["rules"] = rules.map { self.route($0, through: groupName, bypassNames: bypassNames) }
        }
        if let subRules = config["sub-rules"] as? [String: [String]] {
            config["sub-rules"] = subRules.mapValues { rules in
                rules.map { self.route($0, through: groupName, bypassNames: bypassNames) }
            }
        }
        return try Yams.dump(object: config, allowUnicode: true, sortKeys: true)
    }

    private static func route(_ rule: String, through group: String, bypassNames: Set<String>) -> String {
        var parts = rule.components(separatedBy: ",")
        guard parts.count >= 2, parts[0].trimmingCharacters(in: .whitespaces).uppercased() != "SUB-RULE" else {
            return rule
        }
        var index = parts.count - 1
        while index > 0, ["no-resolve", "src"].contains(parts[index].trimmingCharacters(in: .whitespaces)) {
            index -= 1
        }
        guard !bypassNames.contains(parts[index].trimmingCharacters(in: .whitespaces)) else { return rule }
        parts[index] = group
        return parts.joined(separator: ",")
    }

    private static func validate(_ settings: ChainProxySettings) throws {
        guard settings.front.id != settings.landing.id else { throw ChainProxyConfigError.invalidSelection }
        for node in [settings.front, settings.landing] {
            let parsed = try self.parse(node.yaml)
            guard !(parsed["server"] as? String ?? "").isEmpty,
                  !(parsed["type"] as? String ?? "").isEmpty,
                  (parsed["dialer-proxy"] as? String ?? "").isEmpty
            else { throw ChainProxyConfigError.invalidSelection }
        }
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

    private static func nodes(
        from proxies: [[String: Any]], source: String, idPrefix: String) throws -> [ChainProxyNode]
    {
        var names: Set<String> = []
        return try proxies.compactMap { proxy in
            guard let name = proxy["name"] as? String,
                  let type = proxy["type"] as? String,
                  !["direct", "reject", "reject-drop", "pass"].contains(type.lowercased()),
                  proxy["server"] as? String != nil,
                  (proxy["dialer-proxy"] as? String ?? "").isEmpty,
                  names.insert(name).inserted
            else { return nil }
            return ChainProxyNode(
                id: "\(idPrefix)/\(name)",
                name: name,
                source: source,
                yaml: try Yams.dump(object: proxy, allowUnicode: true, sortKeys: true))
        }
    }

    private static func providerPayload(
        _ provider: [String: Any], workingDirectory: URL) throws -> [[String: Any]]
    {
        if provider["type"] as? String == "inline" {
            return provider["payload"] as? [[String: Any]] ?? []
        }
        let path: URL
        if let configuredPath = provider["path"] as? String, !configuredPath.isEmpty {
            path = configuredPath.hasPrefix("/")
                ? URL(fileURLWithPath: configuredPath).standardizedFileURL
                : workingDirectory.appendingPathComponent(configuredPath).standardizedFileURL
        } else if provider["type"] as? String == "http", let url = provider["url"] as? String {
            // Match mihomo's default HTTP provider cache path: <home>/proxies/<MD5(url)>.
            let hash = Insecure.MD5.hash(data: Data(url.utf8)).map { String(format: "%02x", $0) }.joined()
            path = workingDirectory.appendingPathComponent("proxies").appendingPathComponent(hash)
        } else {
            throw ChainProxyConfigError.invalidConfig
        }
        let root = workingDirectory.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let resolved = path.resolvingSymlinksInPath().standardizedFileURL
        guard resolved.pathComponents.starts(with: root) else { throw ChainProxyConfigError.invalidConfig }
        do {
            let config = try self.parse(String(contentsOf: resolved, encoding: .utf8))
            guard let proxies = config["proxies"] as? [[String: Any]] else {
                throw ChainProxyConfigError.invalidConfig
            }
            return proxies
        } catch {
            if let fallback = provider["payload"] as? [[String: Any]] { return fallback }
            throw ChainProxyConfigError.invalidConfig
        }
    }

    private static func applyOverride(_ override: [String: Any], to node: [String: Any]) throws -> [String: Any] {
        var result = node
        let supportedKeys = [
            "tfo", "mptcp", "udp", "udp-over-tcp", "up", "down", "skip-cert-verify",
            "name-cert-verify", "dialer-proxy", "interface-name", "routing-mark", "ip-version",
        ]
        for key in supportedKeys where override[key] != nil { result[key] = override[key] }
        var name = node["name"] as? String ?? ""
        for replacement in override["proxy-name"] as? [[String: String]] ?? [] {
            if let pattern = replacement["pattern"], let target = replacement["target"] {
                let regex = try NSRegularExpression(pattern: pattern)
                name = regex.stringByReplacingMatches(
                    in: name, range: NSRange(name.startIndex..., in: name), withTemplate: target)
            }
        }
        result["name"] = (override["additional-prefix"] as? String ?? "")
            + name + (override["additional-suffix"] as? String ?? "")
        return result
    }

    private static func includes(_ node: [String: Any], provider: [String: Any]) throws -> Bool {
        let name = node["name"] as? String ?? ""
        if let pattern = provider["filter"] as? String, !pattern.isEmpty {
            if try !self.matchesProviderPattern(pattern, name: name) { return false }
        }
        if let pattern = provider["exclude-filter"] as? String, !pattern.isEmpty {
            if try self.matchesProviderPattern(pattern, name: name) { return false }
        }
        let excludedTypes = (provider["exclude-type"] as? String ?? "").lowercased().split(separator: "|")
        return !excludedTypes.contains(Substring((node["type"] as? String ?? "").lowercased()))
    }

    private static func matchesProviderPattern(_ pattern: String, name: String) throws -> Bool {
        let range = NSRange(name.startIndex..., in: name)
        return try pattern.split(separator: "`").contains {
            try NSRegularExpression(pattern: String($0)).firstMatch(in: name, range: range) != nil
        }
    }

    private static func uniqueName(_ base: String, names: inout Set<String>) -> String {
        var candidate = base
        var suffix = 2
        while names.contains(candidate) {
            candidate = "\(base) \(suffix)"
            suffix += 1
        }
        names.insert(candidate)
        return candidate
    }
}
