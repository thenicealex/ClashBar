import Darwin
import Foundation
import Network
import Testing
import Yams
@testable import ClashBar

@Suite(.serialized)
struct ChainProxyLatencyServiceTests {
    @Test func isolatedConfigurationPreservesProxyAndDisablesListeners() throws {
        let node = try self.node()
        let source = try #require(try Yams.load(yaml: node.yaml) as? [String: Any])
        let config = try #require(try Yams.load(yaml: ChainProxyLatencyService.configuration(
            node: node, frontYAML: self.frontYAML, socketPath: "/tmp/test/api.sock")) as? [String: Any])
        let proxies = try #require(config["proxies"] as? [[String: Any]])
        var expected = source
        expected["name"] = "chain-latency"
        expected["dialer-proxy"] = "chain-front"
        #expect(proxies.count == 2)
        #expect(NSDictionary(dictionary: proxies[1]).isEqual(to: expected))
        #expect(config["external-controller-unix"] as? String == "/tmp/test/api.sock")
        #expect(config["external-controller"] == nil)
        #expect(config["mixed-port"] == nil)
        #expect(config["tun"] == nil)
        #expect((config["dns"] as? [String: Bool])?["enable"] == false)
    }

    @Test func cancellationStopsCoreAndRemovesPrivateConfiguration() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = root.appendingPathComponent("started")
        let binary = root.appendingPathComponent("fake-core")
        try "#!/bin/sh\necho \"$PWD\" > '\(marker.path)'\necho \"$$\" >> '\(marker.path)'\nexec /bin/sleep 30\n"
            .write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        let node = try self.node()
        let task = Task {
            try await ChainProxyLatencyService.measure(
                node: node, frontYAML: self.frontYAML, binaryPath: binary.path, url: "http://example.test", timeout: 500)
        }
        defer { task.cancel() }
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: marker.path), Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        if !FileManager.default.fileExists(atPath: marker.path) {
            _ = try await task.value
            Issue.record("Core did not create the startup marker")
            return
        }
        let lines = try String(contentsOf: marker, encoding: .utf8).split(separator: "\n")
        let directory = try #require(lines.first.map(String.init))
        let pid = try #require(lines.last.flatMap { Int32($0) })
        #expect(try FileManager.default.attributesOfItem(atPath: directory)[.posixPermissions] as? Int == 0o700)
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: directory))
        #expect(Darwin.kill(pid, 0) == -1)
        #expect(errno == ESRCH)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CLASHBAR_TEST_MIHOMO"] != nil))
    func measuresHTTPProxyWithRealMihomo() async throws {
        let binary = try #require(ProcessInfo.processInfo.environment["CLASHBAR_TEST_MIHOMO"])
        let listener = try NWListener(using: .tcp, on: .any)
        let queue = DispatchQueue(label: "ChainProxyLatencyServiceTests.proxy")
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
                guard String(data: data ?? Data(), encoding: .utf8)?.hasPrefix("CONNECT ") == true else {
                    connection.cancel()
                    return
                }
                connection.send(content: Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8),
                                completion: .contentProcessed { _ in
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
                        guard String(data: data ?? Data(), encoding: .utf8)?.hasPrefix("CONNECT ") == true else {
                            connection.cancel()
                            return
                        }
                        connection.send(content: Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8),
                                        completion: .contentProcessed { _ in
                            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { _, _, _, _ in
                                queue.asyncAfter(deadline: .now() + 0.03) {
                                    connection.send(content: Data("HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n".utf8),
                                                    completion: .contentProcessed { _ in connection.cancel() })
                                }
                            }
                        })
                    }
                })
            }
        }
        listener.start(queue: queue)
        defer { listener.cancel() }
        let deadline = Date().addingTimeInterval(5)
        while (listener.port?.rawValue ?? 0) == 0, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let port = try #require(listener.port?.rawValue)
        let node = try ChainProxyConfigService.makeNode(name: "HTTP Test", yaml: """
        type: http
        server: exit.invalid
        port: 1080
        """)
        let delay = try await ChainProxyLatencyService.measure(
            node: node, frontYAML: try ChainProxyLatencyService.airportSnapshot(
                sourceYAML: "proxies: [{name: Front, type: http, server: 127.0.0.1, port: \(port)}]\nproxy-groups: [{name: Select, type: select, proxies: [Front]}]",
                selections: ["Select": "Front"], workingDirectory: FileManager.default.temporaryDirectory), binaryPath: binary, url: "http://example.test/generate_204", timeout: 1000)
        #expect(delay > 0)
    }

    @Test func snapshotsCurrentSelectionAndPreservesDependencies() throws {
        let yaml = """
        proxies:
          - {name: First, type: socks5, server: first.test, port: 1080}
          - {name: Second, type: vmess, server: second.test, port: 443, uuid: preserved, dialer-proxy: Upstream}
          - {name: Hop, type: http, server: hop.test, port: 8080}
        proxy-groups:
          - {name: Select, type: select, proxies: [First, Auto]}
          - {name: Auto, type: url-test, proxies: [Second]}
        """
        let source = try ChainProxyLatencyService.airportSnapshot(
            sourceYAML: yaml, selections: ["Select": "Auto", "Auto": "Second", "Upstream": "Hop"],
            workingDirectory: FileManager.default.temporaryDirectory)
        let config = try #require(try Yams.load(yaml: source) as? [String: Any])
        let proxies = try #require(config["proxies"] as? [[String: Any]])
        #expect(proxies.compactMap { $0["name"] as? String } == ["Hop", "Second"])
        #expect(proxies.last?["uuid"] as? String == "preserved")
        #expect(proxies.last?["dialer-proxy"] as? String == "Hop")
        let switched = try ChainProxyLatencyService.airportSnapshot(
            sourceYAML: yaml, selections: ["Select": "First"], workingDirectory: FileManager.default.temporaryDirectory)
        #expect(!switched.contains("second.test"))
        #expect(switched.contains("first.test"))
    }

    @Test func unavailableFrontNeverFallsBackToDirect() throws {
        for selections in [["Select": "DIRECT"], ["Select": "Missing"], ["Select": "Select"], [:]] {
            #expect(throws: ChainProxyLatencyError.self) {
                try ChainProxyLatencyService.airportSnapshot(
                    sourceYAML: "proxy-groups: [{name: Select, type: select, proxies: [DIRECT]}]",
                    selections: selections, workingDirectory: FileManager.default.temporaryDirectory)
            }
        }
    }

    @Test func providerCacheAndGlobalSelectionAreSnapshotted() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = "proxies: [{name: ProviderNode, type: socks5, server: cached.test, port: 1080, password: preserved}]"
        let url = directory.appendingPathComponent("provider.yaml")
        try cache.write(to: url, atomically: true, encoding: .utf8)
        let snapshot = try ChainProxyLatencyService.airportSnapshot(
            sourceYAML: "proxy-providers: {Airport: {path: provider.yaml}}",
            selections: ["GLOBAL": "ProviderNode"], workingDirectory: directory, global: true)
        #expect(snapshot.contains("cached.test"))
        #expect(snapshot.contains("preserved"))
        #expect(try String(contentsOf: url, encoding: .utf8) == cache)
    }

    @Test func inlineProviderOverridesPreserveEffectiveCurrentNode() throws {
        let yaml = """
        proxies: [{name: Hop, type: socks5, server: hop.test, port: 1080}]
        proxy-providers:
          Airport:
            type: inline
            payload: [{name: Raw, type: socks5, server: front.test, port: 443, password: preserved, tls: true}]
            override: {additional-prefix: Airport-, additional-suffix: -Node, skip-cert-verify: true, dialer-proxy: Hop}
        proxy-groups: [{name: Select, type: select, use: [Airport]}]
        """
        let snapshot = try ChainProxyLatencyService.airportSnapshot(
            sourceYAML: yaml, selections: ["Select": "Airport-Raw-Node"],
            workingDirectory: FileManager.default.temporaryDirectory)
        let config = try #require(try Yams.load(yaml: snapshot) as? [String: Any])
        let proxies = try #require(config["proxies"] as? [[String: Any]])
        #expect(proxies.last?["name"] as? String == "Airport-Raw-Node")
        #expect(proxies.last?["skip-cert-verify"] as? Bool == true)
        #expect(proxies.last?["tls"] as? Bool == true)
        #expect(proxies.last?["password"] as? String == "preserved")
        #expect(proxies.last?["dialer-proxy"] as? String == "Hop")
    }

    @Test(arguments: [false, true])
    func defaultProviderCacheAndEmptyDialerArePreserved(emptyPath: Bool) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let cacheDirectory = directory.appendingPathComponent("proxies")
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try "proxies: [{name: Cached, type: socks5, server: cached.test, port: 1080, dialer-proxy: OldHop}]"
            .write(to: cacheDirectory.appendingPathComponent("851475765cd0ebc9b9e68ee9156292e1"),
                   atomically: true, encoding: .utf8)
        let path = emptyPath ? "path: ''" : ""
        let snapshot = try ChainProxyLatencyService.airportSnapshot(
            sourceYAML: """
            proxy-providers:
              Airport:
                type: http
                url: https://airport.test/sub
                \(path)
                payload: [{name: Cached, type: socks5, server: fallback.test, port: 1080}]
                override: {dialer-proxy: ''}
            proxy-groups: [{name: Select, type: select, use: [Airport]}]
            """,
            selections: ["Select": "Cached"], workingDirectory: directory)
        #expect(snapshot.contains("cached.test"))
        #expect(!snapshot.contains("fallback.test"))
        #expect(!snapshot.contains("OldHop"))
    }

    private var frontYAML: String {
        "proxies: [{name: Front, type: socks5, server: front.test, port: 1080}]\nproxy-groups: [{name: chain-front, type: select, proxies: [Front]}]"
    }

    private func node() throws -> ChainProxyNode {
        try ChainProxyConfigService.makeNode(name: "Exit", yaml: """
        type: socks5
        server: proxy.example.com
        port: 1080
        username: user
        password: secret
        tls: true
        sni: tls.example.com
        skip-cert-verify: false
        udp: true
        """)
    }
}
