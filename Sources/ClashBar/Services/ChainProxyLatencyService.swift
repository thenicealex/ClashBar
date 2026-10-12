import CryptoKit
import Darwin
import Foundation
import Yams

enum ChainProxyLatencyError: Error {
    case unavailable
    case failed(String)
}

/// Tests an exit through a snapshot of the selected airport node without changing the running core or its airport selection.
enum ChainProxyLatencyService {
    static func measure(node: ChainProxyNode, frontYAML: String, binaryPath: String, url: String, timeout: Int) async throws -> Int {
        let worker = Task.detached(priority: .userInitiated) {
            try self.measureSynchronously(node: node, frontYAML: frontYAML, binaryPath: binaryPath, url: url, timeout: timeout)
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    static func configuration(node: ChainProxyNode, frontYAML: String, socketPath: String) throws -> String {
        let validated = try ChainProxyConfigService.makeNode(id: node.id, name: node.name, yaml: node.yaml)
        guard var proxy = try Yams.load(yaml: validated.yaml) as? [String: Any] else {
            throw ChainProxyLatencyError.failed("Invalid exit configuration")
        }
        guard var config = try Yams.load(yaml: frontYAML) as? [String: Any],
              var proxies = config["proxies"] as? [[String: Any]], !proxies.isEmpty
        else { throw ChainProxyLatencyError.unavailable }
        proxy["name"] = "chain-latency"
        proxy["dialer-proxy"] = "chain-front"
        proxies.append(proxy)
        config["proxies"] = proxies
        config["external-controller-unix"] = socketPath
        config["mode"] = "direct"
        config["log-level"] = "warning"
        config["dns"] = ["enable": false]
        return try Yams.dump(object: config, allowUnicode: true, sortKeys: true)
    }

    static func airportSnapshot(
        sourceYAML: String, selections: [String: String], workingDirectory: URL, global: Bool = false) throws -> String
    {
        guard let source = try? Yams.load(yaml: sourceYAML) as? [String: Any] else {
            throw ChainProxyLatencyError.unavailable
        }
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
                guard var name = node["name"] as? String else { continue }
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
        var included: [[String: Any]] = []
        var visited: Set<String> = []
        func include(_ name: String) throws -> String {
            guard visited.insert(name).inserted, name != "chain-front", name != "chain-latency" else {
                throw ChainProxyLatencyError.unavailable
            }
            if let selected = selections[name] { return try include(selected) }
            guard var proxy = proxies.first(where: { $0["name"] as? String == name }),
                  let type = proxy["type"] as? String,
                  !["direct", "reject", "reject-drop", "pass"].contains(type.lowercased())
            else { throw ChainProxyLatencyError.unavailable }
            if let dialer = proxy["dialer-proxy"] as? String, !dialer.isEmpty { proxy["dialer-proxy"] = try include(dialer) }
            included.append(proxy)
            return name
        }
        let name = global ? "GLOBAL" : ChainProxyConfigService.mainFrontName(
            groups: source["proxy-groups"] as? [[String: Any]] ?? [], fallback: "GLOBAL")
        let front = try include(name)
        return try Yams.dump(object: [
            "proxies": included,
            "proxy-groups": [["name": "chain-front", "type": "select", "proxies": [front]]],
        ], allowUnicode: true, sortKeys: true)
    }

    private static func measureSynchronously(
        node: ChainProxyNode, frontYAML: String, binaryPath: String, url: String, timeout: Int) throws -> Int
    {
        try Task.checkCancellation()
        // Keep the Unix socket below macOS's path length limit, in a private directory.
        let directory = URL(fileURLWithPath: "/tmp").appendingPathComponent("cb-latency-" + UUID().uuidString)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let socket = directory.appendingPathComponent("api.sock")
        let config = directory.appendingPathComponent("config.yaml")
        try self.configuration(node: node, frontYAML: frontYAML, socketPath: socket.path).write(to: config, atomically: true, encoding: .utf8)
        let core = Process()
        core.executableURL = URL(fileURLWithPath: binaryPath)
        core.currentDirectoryURL = directory
        core.arguments = ["-d", directory.path, "-f", config.path]
        let logURL = directory.appendingPathComponent("core.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let log = try FileHandle(forWritingTo: logURL)
        defer { try? log.close() }
        core.standardOutput = log
        core.standardError = log
        func failure(_ stage: String) -> ChainProxyLatencyError {
            let detail = (try? String(contentsOf: logURL, encoding: .utf8))?
                .split(separator: "\n").suffix(3).joined(separator: "\n") ?? ""
            return .failed(stage + (detail.isEmpty ? "" : ": " + detail))
        }
        try core.run()
        defer { self.stop(core) }
        let startupDeadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: socket.path) {
            try Task.checkCancellation()
            guard core.isRunning, Date() < startupDeadline else { throw failure("Core startup failed") }
            Thread.sleep(forTimeInterval: 0.05)
        }
        try Task.checkCancellation()
        let request = Process()
        request.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        request.arguments = [
            "--noproxy", "*", "--unix-socket", socket.path, "--fail", "--silent",
            "--max-time", String(Double(timeout) / 1000 + 2),
            "--get", "--data-urlencode", "url=\(url)", "--data-urlencode", "timeout=\(timeout)",
            "http://localhost/proxies/chain-latency/delay",
        ]
        let output = Pipe()
        request.standardOutput = output
        request.standardError = FileHandle.nullDevice
        try request.run()
        defer { self.stop(request) }
        let deadline = Date().addingTimeInterval(Double(timeout) / 1000 + 3)
        while request.isRunning {
            try Task.checkCancellation()
            guard Date() < deadline else { throw failure("Latency request timed out") }
            Thread.sleep(forTimeInterval: 0.05)
        }
        guard request.terminationStatus == 0,
              let delay = try JSONDecoder().decode(DelayMeasurement.self, from: output.fileHandleForReading.readDataToEndOfFile()).value,
              delay > 0
        else { throw failure("Latency request failed (curl \(request.terminationStatus))") }
        return delay
    }

    private static func stop(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let deadline = Date().addingTimeInterval(0.5)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
    }
}
