import Foundation
import Testing
import Yams
@testable import ClashBar

struct ChainProxyConfigServiceTests {
    private let source = """
    mixed-port: 7890
    mode: rule
    proxies:
      - {name: Airport A, type: socks5, server: a.example.com, port: 1080}
      - {name: Airport B, type: socks5, server: b.example.com, port: 1080}
      - {name: Bypass, type: direct}
    proxy-groups:
      - {name: Select, type: select, proxies: [Airport A, Airport B]}
      - {name: Auto, type: url-test, proxies: [Airport A, Airport B], url: 'https://example.com', interval: 300}
    rules:
      - DOMAIN,lan.local,DIRECT
      - DOMAIN,ads.example,REJECT
      - DOMAIN,bypass.example,Bypass
      - IP-CIDR,10.0.0.0/8,Select,no-resolve
      - AND,((NETWORK,tcp),(DST-PORT,443)),Auto
      - SUB-RULE,(NETWORK,udp),UDP
      - MATCH,Select
    sub-rules:
      UDP: ["DST-PORT,53,DIRECT", "MATCH,Select"]
    """

    @Test func allProxyRulesFollowTheMainAirportSelection() throws {
        let settings = try self.settings()
        let original = try self.parse(self.source)
        let config = try self.parse(ChainProxyConfigService.compose(sourceYAML: self.source, settings: settings))
        let proxies = try #require(config["proxies"] as? [[String: Any]])
        let groups = try #require(config["proxy-groups"] as? [[String: Any]])
        let originalProxies = try #require(original["proxies"] as? [[String: Any]])
        #expect(NSArray(array: Array(proxies.prefix(3))).isEqual(to: originalProxies))
        for group in try #require(original["proxy-groups"] as? [[String: Any]]) {
            let copied = try #require(groups.first { $0["name"] as? String == group["name"] as? String })
            #expect(NSDictionary(dictionary: group).isEqual(to: copied))
        }
        let selectExit = try #require(proxies.first { $0["dialer-proxy"] as? String == "Select" })
        #expect(!proxies.contains { $0["dialer-proxy"] as? String == "Auto" })
        #expect(selectExit["server"] as? String == "exit.example.com")
        #expect(selectExit["password"] as? String == "secret: #value")
        #expect(proxies.filter { $0["dialer-proxy"] as? String == "Select" }.count == 1)
        let select = try #require(selectExit["name"] as? String)
        #expect(config["rules"] as? [String] == [
            "DOMAIN,lan.local,DIRECT", "DOMAIN,ads.example,REJECT", "DOMAIN,bypass.example,Bypass",
            "IP-CIDR,10.0.0.0/8,\(select),no-resolve",
            "AND,((NETWORK,tcp),(DST-PORT,443)),\(select)", "SUB-RULE,(NETWORK,udp),UDP", "MATCH,\(select)",
        ])
        #expect((config["sub-rules"] as? [String: [String]])?["UDP"] == ["DST-PORT,53,DIRECT", "MATCH,\(select)"])
        let globalFront = ChainProxyConfigService.globalFrontName(id: settings.id)
        let globalExit = try #require(proxies.first { $0["dialer-proxy"] as? String == globalFront })
        let global = try #require(groups.first { $0["name"] as? String == "GLOBAL" })
        let globalExitName = try #require(globalExit["name"] as? String)
        #expect(global["proxies"] as? [String] == [globalExitName])
        let airportGlobal = try #require(groups.first { $0["name"] as? String == globalFront })
        #expect(airportGlobal["proxies"] as? [String] == ["Select", "Auto", "Airport A", "Airport B", "Bypass", "DIRECT", "REJECT"])
        #expect(config["mode"] as? String == "rule")
    }

    @Test func mainGroupFollowsMenuOrderAndServiceGroupsAreNotFronts() throws {
        let yaml = """
        proxies: [{name: Node, type: socks5, server: localhost, port: 1080}]
        proxy-groups:
          - {name: Service, type: select, proxies: [DIRECT, Node]}
          - {name: Main, type: select, proxies: [Node]}
          - {name: GLOBAL, type: select, proxies: [Main, Service]}
        rules: ["DOMAIN,service.example,Service", "MATCH,Main"]
        """
        let config = try self.parse(ChainProxyConfigService.compose(sourceYAML: yaml, settings: self.settings()))
        let proxies = try #require(config["proxies"] as? [[String: Any]])
        let exit = try #require(proxies.first { $0["dialer-proxy"] as? String == "Main" })
        #expect(!proxies.contains { $0["dialer-proxy"] as? String == "Service" })
        let name = try #require(exit["name"] as? String)
        #expect(config["rules"] as? [String] == ["DOMAIN,service.example,\(name)", "MATCH,\(name)"])
    }

    @Test func providersAndIncludeAllCannotSelectInjectedExits() throws {
        let yaml = """
        proxies: [{name: Local, type: socks5, server: localhost, port: 1080}]
        proxy-providers:
          Subscription:
            type: inline
            payload: [{name: Provider Node, type: socks5, server: p.example.com, port: 1080}]
        proxy-groups:
          - {name: Airport, type: select, include-all: true, exclude-filter: 'blocked', use: [Subscription]}
          - {name: GLOBAL, type: select, proxies: [Airport, Local], default-selected: Airport}
        rules: ["MATCH,Airport"]
        """
        let original = try self.parse(yaml)
        let settings = try self.settings()
        let config = try self.parse(ChainProxyConfigService.compose(sourceYAML: yaml, settings: settings))
        #expect(config["proxy-providers"] as? NSDictionary == original["proxy-providers"] as? NSDictionary)
        let groups = try #require(config["proxy-groups"] as? [[String: Any]])
        let group = try #require(groups.first { $0["name"] as? String == "Airport" })
        #expect(group["include-all"] as? Bool == true)
        #expect(group["use"] as? [String] == ["Subscription"])
        let regex = try NSRegularExpression(pattern: try #require(group["exclude-filter"] as? String))
        let proxies = try #require(config["proxies"] as? [[String: Any]])
        for proxy in proxies where proxy["dialer-proxy"] != nil {
            let name = try #require(proxy["name"] as? String)
            #expect(regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil)
        }
        #expect(regex.firstMatch(in: "Local", range: NSRange(location: 0, length: 5)) == nil)
        let global = try #require(groups.first { $0["name"] as? String == ChainProxyConfigService.globalFrontName(id: settings.id) })
        #expect(global["default-selected"] as? String == "Airport")
        #expect(global["proxies"] as? [String] == ["Airport", "Local"])
    }

    @Test func airportChangesKeepOnlyTheIndependentExitSnapshot() throws {
        try self.withFixture { root, airport in
            let settings = try self.settings()
            try ChainProxyConfigService.writeSettings(settings, workingDirectory: root)
            let next = """
            proxies: [{name: New Airport, type: socks5, server: new.example.com, port: 1080}]
            proxy-groups: [{name: New Select, type: select, proxies: [New Airport]}]
            rules: ["MATCH,New Select"]
            """
            for yaml in [self.source, next] {
                try yaml.write(to: airport, atomically: true, encoding: .utf8)
                let runtime = try ChainProxyConfigService.prepareRuntimeConfig(
                    configURL: airport, workingDirectory: root, settings: settings)
                let generated = try self.parse(String(contentsOf: runtime, encoding: .utf8))
                let proxies = try #require(generated["proxies"] as? [[String: Any]])
                #expect(proxies.filter { $0["server"] as? String == "exit.example.com" }.count >= 1)
                #expect(proxies.contains { $0["dialer-proxy"] as? String == (yaml == next ? "New Select" : "Select") })
                #expect(try String(contentsOf: airport, encoding: .utf8) == yaml)
                #expect(try ChainProxyConfigService.readSettings(workingDirectory: root) == settings)
                #expect(try FileManager.default.attributesOfItem(atPath: runtime.path)[.posixPermissions] as? Int == 0o600)
            }
            let saved = try self.parseJSON(Data(contentsOf: ChainProxyConfigService.settingsURL(workingDirectory: root)))
            #expect(saved["front"] == nil)
        }
    }

    @Test func disablingRestoresExactAirportConfigAndRetainsExit() throws {
        try self.withFixture { root, airport in
            var settings = try self.settings()
            settings.enabled = false
            try ChainProxyConfigService.writeSettings(settings, workingDirectory: root)
            #expect(try ChainProxyConfigService.compose(sourceYAML: self.source, settings: settings) == self.source)
            #expect(try ChainProxyConfigService.prepareRuntimeConfig(configURL: airport, workingDirectory: root, settings: settings) == airport)
            #expect(try ChainProxyConfigService.readSettings(workingDirectory: root) == settings)
            #expect(!ChainProxySettings(id: UUID(), landing: settings.landing).enabled)
        }
    }

    @Test(arguments: [true, false])
    func legacySettingsRetainExitIDAndFullParametersForAddingAndEditing(addNode: Bool) throws {
        try self.withFixture { root, _ in
            let settings = try self.settings()
            var legacy = try self.parseJSON(JSONEncoder().encode(settings))
            legacy["front"] = ["id": "old-front", "name": settings.landing.name, "yaml": "unused legacy parameters"]
            let url = ChainProxyConfigService.settingsURL(workingDirectory: root)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: legacy).write(to: url)
            let migrated = try #require(try ChainProxyConfigService.readSettings(workingDirectory: root))
            #expect(migrated == settings)
            var nodes = try ChainProxyConfigService.readNodes(workingDirectory: root, settings: migrated)
            #expect(nodes == [settings.landing])
            if addNode {
                nodes.append(try ChainProxyConfigService.makeNode(name: "Added", yaml: "type: http\nserver: added.example.com\nport: 8080"))
            } else {
                nodes[0] = try ChainProxyConfigService.makeNode(
                    id: nodes[0].id, name: nodes[0].name,
                    yaml: nodes[0].yaml.replacingOccurrences(of: "exit.example.com", with: "edited.example.com"))
                #expect(nodes[0].id == settings.landing.id)
                let edited = try self.parse(nodes[0].yaml)
                var expected = try self.parse(settings.landing.yaml)
                expected["server"] = "edited.example.com"
                #expect(NSDictionary(dictionary: expected).isEqual(to: edited))
            }
            try ChainProxyConfigService.writeNodes(nodes, workingDirectory: root)
            #expect(try ChainProxyConfigService.readNodes(workingDirectory: root, settings: migrated) == nodes)
            #expect(try ChainProxyConfigService.readSettings(workingDirectory: root) == settings)
            try ChainProxyConfigService.writeNodes([], workingDirectory: root)
            #expect(try ChainProxyConfigService.readNodes(workingDirectory: root, settings: migrated).isEmpty)
        }
    }

    @Test func manualNodesRejectInvalidParametersAndDuplicateNames() throws {
        try self.withFixture { root, _ in
            let invalidYAML = [
                "proxies: []",
                "type: socks5\nserver: s\nport: 0",
                "type: socks5\nserver: s\nport: 65536",
                "type: socks5\nserver: s\nport: 1080\ndialer-proxy: dependent",
                "type: [invalid]",
            ]
            for yaml in invalidYAML {
                #expect(throws: ChainProxyConfigError.self) {
                    try ChainProxyConfigService.makeNode(name: "Node", yaml: yaml)
                }
            }
            #expect(throws: ChainProxyConfigError.self) {
                try ChainProxyConfigService.makeNode(name: " ", yaml: "type: socks5\nserver: s\nport: 1080")
            }
            let node = try self.settings().landing
            try ChainProxyConfigService.writeNodes([node], workingDirectory: root)
            let duplicate = try ChainProxyConfigService.makeNode(name: node.name, yaml: node.yaml)
            #expect(throws: ChainProxyConfigError.self) {
                try ChainProxyConfigService.writeNodes([node, duplicate], workingDirectory: root)
            }
            #expect(try ChainProxyConfigService.readNodes(workingDirectory: root, settings: nil) == [node])
            let library = root.appendingPathComponent("state/chain-proxy-nodes.json")
            try "invalid JSON".write(to: library, atomically: true, encoding: .utf8)
            #expect(throws: (any Error).self) {
                try ChainProxyConfigService.readNodes(workingDirectory: root, settings: self.settings())
            }
        }
    }

    @Test func rejectsInvalidExitAndCorruptSavedSettings() throws {
        try self.withFixture { root, _ in
            let invalid = ChainProxySettings(enabled: true, id: UUID(), landing: ChainProxyNode(
                id: "bad", name: "Bad", yaml: "type: socks5\nserver: s\nport: 1080\ndialer-proxy: manual"))
            #expect(throws: ChainProxyConfigError.self) { try ChainProxyConfigService.compose(sourceYAML: self.source, settings: invalid) }
            let url = ChainProxyConfigService.settingsURL(workingDirectory: root)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "invalid JSON".write(to: url, atomically: true, encoding: .utf8)
            #expect(throws: ChainProxyConfigError.self) { try ChainProxyConfigService.readSettings(workingDirectory: root) }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CLASHBAR_TEST_MIHOMO"] != nil))
    func composedAirportsPassMihomoValidation() throws {
        let binary = try #require(ProcessInfo.processInfo.environment["CLASHBAR_TEST_MIHOMO"])
        try self.withFixture { root, airport in
            let runtime = try ChainProxyConfigService.prepareRuntimeConfig(configURL: airport, workingDirectory: root, settings: self.settings())
            let process = Process()
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = ["-d", root.path, "-f", runtime.path, "-t"]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            try process.run()
            process.waitUntilExit()
            let diagnostics = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            #expect(process.terminationStatus == 0, "\(diagnostics)")
        }
    }

    private func settings() throws -> ChainProxySettings {
        let landing = try ChainProxyConfigService.makeNode(
            id: "independent-exit", name: "Exit", yaml: """
            type: ss
            server: exit.example.com
            port: 443
            cipher: aes-128-gcm
            password: 'secret: #value'
            plugin: v2ray-plugin
            plugin-opts: {mode: websocket, host: cdn.example.com, tls: true, path: /ws}
            """)
        return ChainProxySettings(enabled: true, id: UUID(), landing: landing)
    }

    private func parse(_ yaml: String) throws -> [String: Any] {
        try #require(try Yams.load(yaml: yaml) as? [String: Any])
    }

    private func parseJSON(_ data: Data) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func withFixture(_ body: (URL, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let configDirectory = root.appendingPathComponent("config")
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let airport = configDirectory.appendingPathComponent("airport.yaml")
        try self.source.write(to: airport, atomically: true, encoding: .utf8)
        try body(root, airport)
    }
}
