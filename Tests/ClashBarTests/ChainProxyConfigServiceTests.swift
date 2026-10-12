import CryptoKit
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
            let snapshot = try ChainProxyConfigService.load(configURL: configURL, workingDirectory: root)
            #expect(snapshot.nodes.count == 3)
            let reloaded = try ChainProxyConfigService.load(configURL: configURL, workingDirectory: root)
            #expect(snapshot.nodes.map(\.yaml) == reloaded.nodes.map(\.yaml))
            let settings = try self.settings(from: snapshot)
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
            let snapshot = try ChainProxyConfigService.load(configURL: configURL, workingDirectory: root)
            let node = try #require(snapshot.nodes.first)
            let invalid = ChainProxySettings(enabled: true, id: UUID(), front: node, landing: node)
            #expect(throws: ChainProxyConfigError.self) {
                try ChainProxyConfigService.compose(sourceYAML: self.source, settings: invalid)
            }
        }
    }

    @Test func savedNodesSurviveUpdatesAndAirportSwitches() throws {
        try self.withFixture { root, configURL in
            let snapshot = try ChainProxyConfigService.load(configURL: configURL, workingDirectory: root)
            let settings = try self.settings(from: snapshot)
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
            let snapshot = try ChainProxyConfigService.load(configURL: configURL, workingDirectory: root)
            var settings = try self.settings(from: snapshot)
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

    @Test func readsInlineFileAndDefaultHTTPCacheProviders() throws {
        try self.withFixture { root, configURL in
            let cache = "proxies:\n  - {name: Cached, type: socks5, server: cached.example.com, port: 1080}\n"
            try cache.write(to: root.appendingPathComponent("provider.yaml"), atomically: true, encoding: .utf8)
            let url = "https://example.com/subscription"
            let hash = Insecure.MD5.hash(data: Data(url.utf8)).map { String(format: "%02x", $0) }.joined()
            let cacheDirectory = root.appendingPathComponent("proxies")
            try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            try cache.write(to: cacheDirectory.appendingPathComponent(hash), atomically: true, encoding: .utf8)
            let providers = """

            proxy-providers:
              Inline:
                type: inline
                payload:
                  - {name: Inline, type: socks5, server: inline.example.com, port: 1080}
                override: {additional-prefix: '[I] ', udp: false}
              File: {type: file, path: provider.yaml}
              HTTP: {type: http, url: 'https://example.com/subscription'}
              Missing: {type: file, path: unavailable.yaml}
              Expression: {type: inline, override: {override-expr: '.port = 443'}}
            """
            try (self.source + providers).write(to: configURL, atomically: true, encoding: .utf8)
            let snapshot = try ChainProxyConfigService.load(configURL: configURL, workingDirectory: root)
            #expect(snapshot.unavailableProviders == ["Expression", "Missing"])
            #expect(snapshot.nodes.contains { $0.id == "provider:source.yaml:File/Cached" })
            #expect(snapshot.nodes.contains { $0.id == "provider:source.yaml:HTTP/Cached" })
            let inline = try #require(snapshot.nodes.first { $0.id == "provider:source.yaml:Inline/[I] Inline" })
            let parsed = try #require(try Yams.load(yaml: inline.yaml) as? [String: Any])
            #expect(parsed["udp"] as? Bool == false)
            let cached = try #require(snapshot.nodes.first { $0.id == "provider:source.yaml:File/Cached" })
            let settings = ChainProxySettings(enabled: true, id: UUID(), front: inline, landing: cached)
            try ChainProxyConfigService.writeSettings(settings, workingDirectory: root)
            try FileManager.default.removeItem(at: root.appendingPathComponent("provider.yaml"))
            try FileManager.default.removeItem(at: cacheDirectory)
            try FileManager.default.removeItem(at: configURL)
            let saved = try #require(try ChainProxyConfigService.readSettings(workingDirectory: root))
            let yaml = try ChainProxyConfigService.compose(sourceYAML: self.airportB, settings: saved)
            let generated = try #require(try Yams.load(yaml: yaml) as? [String: Any])
            let proxies = try #require(generated["proxies"] as? [[String: Any]])
            let front = proxies[proxies.count - 2]
            let landing = try #require(proxies.last)
            #expect(landing["dialer-proxy"] as? String == front["name"] as? String)
            #expect(landing["server"] as? String == "cached.example.com")
            #expect(front["udp"] as? Bool == false)
        }
    }

    @Test func filtersNodesAndRejectsProviderPathEscapes() throws {
        try self.withFixture { root, configURL in
            let providers = """

            proxy-providers:
              Filtered:
                type: inline
                filter: '^JP`^香港'
                exclude-filter: 'Slow`禁止'
                exclude-type: http
                override: {additional-prefix: '[Filtered] '}
                payload:
                  - {name: JP Fast, type: socks5, server: fast.example.com, port: 1080}
                  - {name: JP Slow, type: socks5, server: slow.example.com, port: 1080}
                  - {name: JP HTTP, type: http, server: http.example.com, port: 1080}
                  - {name: US Fast, type: socks5, server: us.example.com, port: 1080}
                  - {name: 香港 快, type: socks5, server: hk.example.com, port: 1080}
                  - {name: 香港 禁止, type: socks5, server: excluded.example.com, port: 1080}
              InvalidInclude:
                type: inline
                filter: '['
                payload: [{name: JP Invalid, type: socks5, server: invalid.example.com, port: 1080}]
              InvalidExclude:
                type: inline
                exclude-filter: '['
                payload: [{name: JP Invalid, type: socks5, server: invalid.example.com, port: 1080}]
              Escape: {type: file, path: '../outside.yaml'}
              Chained:
                type: inline
                dialer-proxy: 'Front #1'
                payload:
                  - {name: Chained, type: socks5, server: chain.example.com, port: 1080}
            """
            try (self.source + providers).write(to: configURL, atomically: true, encoding: .utf8)
            let snapshot = try ChainProxyConfigService.load(configURL: configURL, workingDirectory: root)
            let names = snapshot.nodes.filter { $0.source.hasSuffix(" · Filtered") }.map(\.name)
            #expect(Set(names) == Set(["[Filtered] JP Fast", "[Filtered] 香港 快"]))
            #expect(snapshot.nodes.allSatisfy { !$0.source.hasSuffix(" · Chained") })
            #expect(snapshot.unavailableProviders == ["Escape", "InvalidExclude", "InvalidInclude"])
        }
    }

    @Test func corruptSavedSettingsAreNotSilentlyIgnored() throws {
        try self.withFixture { root, configURL in
            try "proxies: [invalid".write(to: configURL, atomically: true, encoding: .utf8)
            #expect(throws: ChainProxyConfigError.self) {
                try ChainProxyConfigService.load(configURL: configURL, workingDirectory: root)
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
            let settings = try self.settings(from: ChainProxyConfigService.load(configURL: configURL, workingDirectory: root))
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
            let settings = try self.settings(from: ChainProxyConfigService.load(configURL: configURL, workingDirectory: root))
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

    private func settings(from snapshot: ChainProxyConfigSnapshot) throws -> ChainProxySettings {
        let front = try #require(snapshot.nodes.first { $0.name == "Front #1" })
        let landing = try #require(snapshot.nodes.first { $0.name == "Exit, \"JP\"" })
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
