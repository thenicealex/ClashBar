import Foundation
import Testing
import Yams
@testable import ClashBar

struct ChainProxyConfigServiceTests {
    private let source = """
    mixed-port: 7890
    mode: global
    dns: {enable: true, nameserver: [1.1.1.1]}
    proxies:
      - &front {name: 'Front #1', type: socks5, server: 127.0.0.1, port: 1080}
      - {name: 'Exit, "JP"', type: ss, server: exit.example.com, port: 443, cipher: aes-128-gcm, password: 'secret: #value'}
      - {name: ClashBar Front, type: socks5, server: other.example.com, port: 1080}
      - {name: Existing chain, type: socks5, server: chained.example.com, port: 1080, dialer-proxy: 'Front #1'}
      - {name: Direct node, type: direct}
    proxy-groups:
      - {name: ClashBar Chain, type: select, proxies: ['Front #1']}
    rules: ['MATCH,ClashBar Chain']
    """

    @Test func composesCorrectDirectionAndPreservesRouting() throws {
        try self.withFixture { root, configURL in
            let settings = try self.settings()
            let yaml = try ChainProxyConfigService.compose(sourceYAML: self.source, settings: settings)
            let generated = try #require(try Yams.load(yaml: yaml) as? [String: Any])
            let proxies = try #require(generated["proxies"] as? [[String: Any]])
            let front = proxies[proxies.count - 2]
            let landing = try #require(proxies.last)
            #expect(front["server"] as? String == "127.0.0.1")
            #expect(front["dialer-proxy"] == nil)
            #expect(landing["server"] as? String == "exit.example.com")
            #expect(landing["dialer-proxy"] as? String == front["name"] as? String)
            #expect(landing["password"] as? String == "secret: #value")
            #expect(generated["mode"] as? String == "global")
            let groups = try #require(generated["proxy-groups"] as? [[String: Any]])
            let chainName = try #require(groups.first?["name"] as? String)
            #expect(generated["rules"] as? [String] == ["MATCH,\(chainName)"])
            #expect(groups.last?["name"] as? String == "GLOBAL")
            #expect(groups.last?["proxies"] as? [String] == [chainName])
            #expect(groups.contains { $0["name"] as? String == "ClashBar Chain" })
            #expect(generated["mixed-port"] as? Int == 7890)
            #expect((generated["dns"] as? [String: Any])?["enable"] as? Bool == true)
            #expect(try String(contentsOf: configURL, encoding: .utf8) == self.source)
        }
    }

    @Test func rejectsSameNode() throws {
        try self.withFixture { root, configURL in
            let node = try self.settings().front
            let invalid = ChainProxySettings(enabled: true, id: UUID(), front: node, landing: node)
            #expect(throws: ChainProxyConfigError.self) {
                try ChainProxyConfigService.compose(sourceYAML: self.source, settings: invalid)
            }
        }
    }

    @Test func savedNodesSurviveUpdatesAndAirportSwitches() throws {
        try self.withFixture { root, configURL in
            let settings = try self.settings()
            try ChainProxyConfigService.writeSettings(settings, workingDirectory: root)
            let saved = try #require(try ChainProxyConfigService.readSettings(workingDirectory: root))
            #expect(saved == settings)
            let updated = self.airportB
            try updated.write(to: configURL, atomically: true, encoding: .utf8)
            let runtimeA = try ChainProxyConfigService.prepareRuntimeConfig(
                configURL: configURL, workingDirectory: root, settings: saved)
            try self.expectSavedChain(at: runtimeA)
            let airportBURL = configURL.deletingLastPathComponent().appendingPathComponent("airport-b.yaml")
            try self.airportB.write(to: airportBURL, atomically: true, encoding: .utf8)
            try FileManager.default.removeItem(at: configURL)
            let runtimeB = try ChainProxyConfigService.prepareRuntimeConfig(
                configURL: airportBURL, workingDirectory: root, settings: saved)
            try self.expectSavedChain(at: runtimeB)
            #expect(try String(contentsOf: airportBURL, encoding: .utf8) == self.airportB)
            #expect(try ChainProxyConfigService.readSettings(workingDirectory: root) == settings)
            #expect(runtimeB.deletingLastPathComponent().lastPathComponent == "runtime")
            let settingsURL = ChainProxyConfigService.settingsURL(workingDirectory: root)
            #expect(settingsURL.deletingLastPathComponent().lastPathComponent == "state")
            let permissions = try FileManager.default.attributesOfItem(atPath: settingsURL.path)[.posixPermissions] as? Int
            #expect(permissions == 0o600)
            let runtimePermissions = try FileManager.default.attributesOfItem(atPath: runtimeB.path)[.posixPermissions] as? Int
            #expect(runtimePermissions == 0o600)
        }
    }

    @Test func disablingRestoresExactAirportConfigAndRetainsNodes() throws {
        try self.withFixture { root, configURL in
            var settings = try self.settings()
            settings.enabled = false
            try ChainProxyConfigService.writeSettings(settings, workingDirectory: root)
            let saved = try #require(try ChainProxyConfigService.readSettings(workingDirectory: root))
            #expect(saved == settings)
            #expect(try ChainProxyConfigService.compose(sourceYAML: self.source, settings: saved) == self.source)
            #expect(try ChainProxyConfigService.prepareRuntimeConfig(
                configURL: configURL, workingDirectory: root, settings: saved) == configURL)
            #expect(try ChainProxyConfigService.prepareRuntimeConfig(
                configURL: configURL, workingDirectory: root, settings: nil) == configURL)
        }
    }

    @Test func manualNodeLibraryPersistsEditsAndDeletesIndependently() throws {
        try self.withFixture { root, configURL in
            let settings = try self.settings()
            let nodes = [settings.front, settings.landing]
            #expect(try ChainProxyConfigService.readNodes(workingDirectory: root, settings: nil).isEmpty)
            let disabled = ChainProxySettings(id: UUID(), front: settings.front, landing: settings.landing)
            #expect(!disabled.enabled)
            try ChainProxyConfigService.writeNodes(nodes, workingDirectory: root)
            try FileManager.default.removeItem(at: configURL)
            #expect(try ChainProxyConfigService.readNodes(workingDirectory: root, settings: nil) == nodes)
            let edited = try ChainProxyConfigService.makeNode(
                id: settings.front.id, name: "Edited Front", yaml: "type: http\nserver: new.example.com\nport: '8080'")
            try ChainProxyConfigService.writeNodes([edited, settings.landing], workingDirectory: root)
            let reloaded = try ChainProxyConfigService.readNodes(workingDirectory: root, settings: nil)
            #expect(reloaded.first == edited)
            #expect(reloaded.last == settings.landing)
            try ChainProxyConfigService.writeNodes([], workingDirectory: root)
            #expect(try ChainProxyConfigService.readNodes(workingDirectory: root, settings: settings).isEmpty)
            let path = root.appendingPathComponent("state/chain-proxy-nodes.json").path
            #expect(try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int == 0o600)
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
            let node = try self.settings().front
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

    @Test func existingSavedNodesRemainAvailableWithoutAnAirport() throws {
        try self.withFixture { root, configURL in
            let settings = try self.settings()
            try ChainProxyConfigService.writeSettings(settings, workingDirectory: root)
            try FileManager.default.removeItem(at: configURL)
            let saved = try ChainProxyConfigService.readSettings(workingDirectory: root)
            #expect(try ChainProxyConfigService.readNodes(workingDirectory: root, settings: saved)
                == [settings.front, settings.landing])
        }
    }

    @Test(arguments: [true, false])
    func sameNameLegacyNodesSupportAddingAndEditing(addNode: Bool) throws {
        try self.withFixture { root, configURL in
            let front = ChainProxyNode(id: "legacy-front", name: "Shared Name", yaml: """
            # Original front parameters
            name: Shared Name
            type: socks5
            server: front.example.com
            port: '1080'
            username: front-user
            password: 'secret: #front'
            udp: true
            """)
            let landing = ChainProxyNode(id: "legacy-exit", name: "Shared Name", yaml: """
            # Original nested parameters
            name: Shared Name
            type: ss
            server: exit.example.com
            port: 443
            cipher: aes-128-gcm
            password: 'secret: #exit'
            plugin: v2ray-plugin
            plugin-opts:
              mode: websocket
              host: cdn.example.com
              tls: true
              path: /ws
            """)
            let settings = ChainProxySettings(enabled: true, id: UUID(), front: front, landing: landing)
            try ChainProxyConfigService.writeSettings(settings, workingDirectory: root)
            try FileManager.default.removeItem(at: configURL)
            let saved = try ChainProxyConfigService.readSettings(workingDirectory: root)
            let migrated = try ChainProxyConfigService.readNodes(workingDirectory: root, settings: saved)
            #expect(migrated.map(\.id) == [front.id, landing.id])
            #expect(Set(migrated.map(\.name)).count == 2)
            #expect(migrated.map(\.yaml) == [front.yaml, landing.yaml])
            #expect(try ChainProxyConfigService.readNodes(workingDirectory: root, settings: saved) == migrated)

            var updated = migrated
            if addNode {
                updated.append(try ChainProxyConfigService.makeNode(
                    name: "Added Node", yaml: "type: http\nserver: added.example.com\nport: 8080"))
            } else {
                updated[1] = try ChainProxyConfigService.makeNode(
                    id: migrated[1].id, name: migrated[1].name,
                    yaml: landing.yaml.replacingOccurrences(of: "exit.example.com", with: "updated.example.com"))
                var expected = try #require(try Yams.load(yaml: landing.yaml) as? [String: Any])
                expected["name"] = migrated[1].name
                expected["server"] = "updated.example.com"
                let actual = try #require(try Yams.load(yaml: updated[1].yaml) as? [String: Any])
                #expect(NSDictionary(dictionary: expected).isEqual(to: actual))
            }
            try ChainProxyConfigService.writeNodes(updated, workingDirectory: root)
            let reloaded = try ChainProxyConfigService.readNodes(workingDirectory: root, settings: saved)
            #expect(reloaded == updated)
            #expect(Array(reloaded.prefix(2)).map(\.id) == [front.id, landing.id])
            #expect(reloaded[0].yaml == front.yaml)
            if addNode { #expect(reloaded[1].yaml == landing.yaml) }
            #expect(try ChainProxyConfigService.readSettings(workingDirectory: root) == settings)
        }
    }

    @Test func corruptSavedSettingsAreNotSilentlyIgnored() throws {
        try self.withFixture { root, configURL in
            try "proxies: [invalid".write(to: configURL, atomically: true, encoding: .utf8)
            #expect(throws: ChainProxyConfigError.self) {
                try ChainProxyConfigService.compose(sourceYAML: "proxies: [invalid", settings: self.settings())
            }
            let url = ChainProxyConfigService.settingsURL(workingDirectory: root)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "invalid JSON".write(to: url, atomically: true, encoding: .utf8)
            #expect(throws: ChainProxyConfigError.self) {
                try ChainProxyConfigService.readSettings(workingDirectory: root)
            }
        }
    }

    @Test func preservesDirectRejectLogicalAndSubRules() throws {
        try self.withFixture { root, configURL in
            let settings = try self.settings()
            let yaml = try ChainProxyConfigService.compose(sourceYAML: self.airportB, settings: settings)
            let config = try #require(try Yams.load(yaml: yaml) as? [String: Any])
            let groups = try #require(config["proxy-groups"] as? [[String: Any]])
            let chain = try #require(groups.first?["name"] as? String)
            #expect(config["rules"] as? [String] == [
                "DOMAIN,lan.local,DIRECT",
                "DOMAIN,ads.example,REJECT",
                "IP-CIDR,192.168.0.0/16,DIRECT,no-resolve",
                "IP-CIDR,10.0.0.0/8,\(chain),no-resolve",
                "AND,((NETWORK,tcp),(DST-PORT,443)),\(chain)",
                "SUB-RULE,(NETWORK,udp),UDP",
                "MATCH,\(chain)",
            ])
            let subRules = try #require(config["sub-rules"] as? [String: [String]])
            #expect(subRules["UDP"] == ["DST-PORT,53,DIRECT", "MATCH,\(chain)"])
            #expect(config["mode"] as? String == "rule")
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CLASHBAR_TEST_MIHOMO"] != nil))
    func composedAirportsPassMihomoValidation() throws {
        let binary = try #require(ProcessInfo.processInfo.environment["CLASHBAR_TEST_MIHOMO"])
        try self.withFixture { root, configURL in
            let settings = try self.settings()
            for source in [self.source, self.airportB] {
                try source.write(to: configURL, atomically: true, encoding: .utf8)
                let runtimeURL = try ChainProxyConfigService.prepareRuntimeConfig(
                    configURL: configURL, workingDirectory: root, settings: settings)
                let process = Process()
                process.executableURL = URL(fileURLWithPath: binary)
                process.arguments = ["-d", root.path, "-f", runtimeURL.path, "-t"]
                let output = Pipe()
                process.standardOutput = output
                process.standardError = output
                try process.run()
                process.waitUntilExit()
                let diagnostics = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                #expect(process.terminationStatus == 0, "\(diagnostics)")
            }
        }
    }

    private let airportB = """
    mixed-port: 7891
    mode: rule
    proxies:
      - {name: B Node, type: socks5, server: b.example.com, port: 1080}
    proxy-groups:
      - {name: B Select, type: select, proxies: [B Node]}
    rules:
      - DOMAIN,lan.local,DIRECT
      - DOMAIN,ads.example,REJECT
      - IP-CIDR,192.168.0.0/16,DIRECT,no-resolve
      - IP-CIDR,10.0.0.0/8,B Select,no-resolve
      - AND,((NETWORK,tcp),(DST-PORT,443)),B Select
      - SUB-RULE,(NETWORK,udp),UDP
      - MATCH,B Select
    sub-rules:
      UDP: ["DST-PORT,53,DIRECT", "MATCH,B Select"]
    """

    private func settings() throws -> ChainProxySettings {
        let front = try ChainProxyConfigService.makeNode(
            name: "Front #1", yaml: "type: socks5\nserver: 127.0.0.1\nport: 1080")
        let landing = try ChainProxyConfigService.makeNode(
            name: "Exit, \"JP\"", yaml: "type: ss\nserver: exit.example.com\nport: 443\ncipher: aes-128-gcm\npassword: 'secret: #value'")
        return ChainProxySettings(enabled: true, id: UUID(), front: front, landing: landing)
    }

    private func expectSavedChain(at url: URL) throws {
        let yaml = try String(contentsOf: url, encoding: .utf8)
        let config = try #require(try Yams.load(yaml: yaml) as? [String: Any])
        let proxies = try #require(config["proxies"] as? [[String: Any]])
        let front = proxies[proxies.count - 2]
        let landing = try #require(proxies.last)
        #expect(front["server"] as? String == "127.0.0.1")
        #expect(landing["server"] as? String == "exit.example.com")
        #expect(landing["password"] as? String == "secret: #value")
        #expect(landing["dialer-proxy"] as? String == front["name"] as? String)
        #expect(config["mixed-port"] as? Int == 7891)
    }

    private func withFixture(_ body: (URL, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let configDirectory = root.appendingPathComponent("config")
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let configURL = configDirectory.appendingPathComponent("source.yaml")
        try self.source.write(to: configURL, atomically: true, encoding: .utf8)
        try body(root, configURL)
    }
}
