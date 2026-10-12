import Foundation
import Testing
import Yams
@testable import ClashBar

@MainActor
@Suite(.serialized)
struct ChainProxyViewModelTests {
    @Test func savesWithoutChangingAirportAndRestoresAfterAppRestart() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let core = RecordingChainCore()
        let (model, config, landing) = try self.configuredModel(home: home, core: core)
        try await model.saveChainProxySettings(enabled: true, landing: landing)
        #expect(model.configService.selectedConfig == config)
        #expect(model.configService.availableConfigs.map(\.lastPathComponent) == ["airport.yaml"])
        #expect(try String(contentsOf: config, encoding: .utf8) == self.source)
        #expect(core.validationPaths.last?.contains("/runtime/") == true)

        let restored = try self.model(home: home, core: core)
        #expect(restored.chainProxySettings == model.chainProxySettings)
        let second = config.deletingLastPathComponent().appendingPathComponent("airport-b.yaml")
        try "proxies: []\nproxy-groups: []\nrules: [MATCH,DIRECT]\n".write(
            to: second, atomically: true, encoding: .utf8)
        _ = restored.configService.reloadConfigs()
        restored.configService.selectConfig(second)
        #expect(await restored.configValidationFailureDetails(configPath: second.path) == nil)
        #expect(core.validationPaths.last?.contains("/runtime/") == true)
        #expect(restored.chainProxySettings == model.chainProxySettings)

        try await restored.saveChainProxySettings(enabled: false, landing: landing)
        #expect(try await restored.runtimeConfigPath(for: second.path) == second.path)
        #expect(core.validationPaths.last == second.path)
        #expect(restored.chainProxySettings?.landing == landing)
        #expect(restored.configService.selectedConfig == second)
    }

    @Test(arguments: [true, false])
    func failedValidationKeepsSavedSettingsAndAirportSelection(enabled: Bool) async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let core = RecordingChainCore(rejectsValidation: true)
        let (model, config, landing) = try self.configuredModel(home: home, core: core)
        let root = model.workingDirectoryManager.rootDirectoryURL
        let previous = ChainProxySettings(enabled: !enabled, id: UUID(), landing: landing)
        try ChainProxyConfigService.writeSettings(previous, workingDirectory: root)
        model.loadChainProxySettings()
        do {
            try await model.saveChainProxySettings(enabled: enabled, landing: landing)
            Issue.record("Expected validation to fail")
        } catch {
            #expect(model.chainProxySettings == previous)
            #expect(try ChainProxyConfigService.readSettings(workingDirectory: root) == previous)
            #expect(model.configService.selectedConfig == config)
            #expect(!model.isChainProxySaving)
            #expect(!model.isRuntimeConfigUpdating)
        }
    }

    @Test(arguments: [true, false], [true, false])
    func toggleCommitsOnlyAfterApplyAndRetainsStateOnFailure(enabled: Bool, failSave: Bool) async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let core = RecordingChainCore(running: true)
        let (model, config, landing) = try self.configuredModel(home: home, core: core)
        let root = model.workingDirectoryManager.rootDirectoryURL
        let previous = ChainProxySettings(enabled: !enabled, id: UUID(), landing: landing)
        try ChainProxyConfigService.writeSettings(previous, workingDirectory: root)
        try ChainProxyConfigService.writeNodes([landing], workingDirectory: root)
        model.loadChainProxySettings()
        let pause = ChainValidationPause()
        let session = self.configureAPI(for: model, pause: pause)
        defer { session.invalidateAndCancel() }
        let api = ChainAPIProtocol.state
        if failSave { api.failNextConfigPUT() }
        let saving = Task { () -> Error? in
            do {
                try await model.saveChainProxySettings(enabled: enabled, landing: landing)
                return nil
            } catch { return error }
        }
        await pause.waitUntilPaused()
        #expect(model.chainProxySettings == previous)
        #expect(try ChainProxyConfigService.readSettings(workingDirectory: root) == previous)
        #expect(model.isChainProxySaving)
        #expect(model.isRuntimeConfigUpdating)
        do {
            try await model.saveChainProxySettings(enabled: enabled, landing: landing)
            Issue.record("A second toggle must not overlap the pending apply")
        } catch {
            #expect(error is ChainProxyConfigError)
        }
        await pause.release()
        let error = await saving.value
        if failSave {
            #expect(model.errorLogs.contains { $0.level == "error" && $0.message.contains(model.tr("log.chain.apply")) })
            #expect(model.errorLogs.contains { $0.level == "info" && $0.message.contains(model.tr("log.chain.rollback")) })
        }
        #expect((error != nil) == failSave)
        let expected = failSave ? previous : ChainProxySettings(
            enabled: enabled, id: previous.id, landing: landing)
        #expect(model.chainProxySettings == expected)
        #expect(try ChainProxyConfigService.readSettings(workingDirectory: root) == expected)
        #expect(try ChainProxyConfigService.readNodes(workingDirectory: root, settings: expected) == [landing])
        #expect(model.configService.selectedConfig == config)
        #expect(api.appliedPaths.count == (failSave ? 2 : 1))
        let finalPath = try #require(api.appliedPaths.last)
        #expect(finalPath == (expected.enabled ? try await model.runtimeConfigPath(for: config.path) : config.path))
        #expect(!model.isChainProxySaving)
        #expect(!model.isRuntimeConfigUpdating)
    }

    @Test(arguments: [(true, false), (true, true), (false, false), (false, true)])
    func runningReloadAndSaveApplyLatestChain(reloadFirst: Bool, initiallyEnabled: Bool) async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let pause = ChainValidationPause()
        let core = RecordingChainCore(running: true, pause: pause)
        let (model, config, landing) = try self.configuredModel(home: home, core: core)
        let root = model.workingDirectoryManager.rootDirectoryURL
        let oldLanding = ChainProxyNode(
            id: "saved-old-exit", name: "Old Exit",
            yaml: "name: Old Exit\ntype: socks5\nserver: old-exit.example.com\nport: 1080\n")
        let previous = ChainProxySettings(enabled: initiallyEnabled, id: UUID(), landing: oldLanding)
        try ChainProxyConfigService.writeSettings(previous, workingDirectory: root)
        model.loadChainProxySettings()

        let api = ChainAPIProtocol.state
        let session = self.configureAPI(for: model)
        defer {
            model.cancelOwnedTasks()
            session.invalidateAndCancel()
        }
        #expect(model.isRuntimeRunning)

        let first = Task {
            if reloadFirst {
                await model.reloadConfig()
            } else {
                try await model.saveChainProxySettings(enabled: true, landing: landing)
            }
        }
        // Suspend the first transaction after it has captured a configuration, before any PUT.
        await pause.waitUntilPaused()
        let second = Task {
            if reloadFirst {
                try await model.saveChainProxySettings(enabled: true, landing: landing)
            } else {
                await model.reloadConfig()
            }
        }
        // Allow the competing operation to reach the held gate. No network timing controls the first operation.
        try await Task.sleep(for: .milliseconds(200))
        #expect(core.validationPaths.count == 1)
        #expect(api.appliedPaths.isEmpty)
        await pause.release()
        try await first.value
        try await second.value

        let paths = api.appliedPaths
        #expect(paths.count == 2)
        let finalPath = try #require(paths.last)
        let yaml = try String(contentsOfFile: finalPath, encoding: .utf8)
        let runtime = try #require(try Yams.load(yaml: yaml) as? [String: Any])
        let proxies = try #require(runtime["proxies"] as? [[String: Any]])
        let runtimeFront = try #require(proxies.first { $0["name"] as? String == "Front" })
        let runtimeLanding = try #require(proxies.first { $0["dialer-proxy"] as? String == "Select" })
        #expect(runtimeFront["server"] as? String == "front.example.com")
        #expect(runtimeLanding["server"] as? String == "exit.example.com")
        #expect(runtimeLanding["dialer-proxy"] as? String == "Select")
        let saved = try #require(try ChainProxyConfigService.readSettings(workingDirectory: root))
        #expect(saved.enabled)
        #expect(saved.landing == landing)
        #expect(model.chainProxySettings == saved)
        #expect(model.configService.selectedConfig == config)
        #expect(!model.isRuntimeConfigUpdating)
        #expect(!model.isChainProxySaving)
    }

    @Test func airportSwitchWaitsForInFlightChainSave() async throws {
        let home = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let validationPause = ChainValidationPause()
        let putPause = ChainValidationPause()
        let core = RecordingChainCore(running: true, pause: validationPause)
        let (model, airportA, landing) = try self.configuredModel(home: home, core: core)
        let airportB = airportA.deletingLastPathComponent().appendingPathComponent("airport-b.yaml")
        let sourceB = """
        mixed-port: 7891
        external-controller: chain.test:9090
        proxies: [{name: B Node, type: socks5, server: b.example.com, port: 1080}]
        proxy-groups: [{name: B Select, type: select, proxies: [B Node]}]
        rules: ["DOMAIN,lan.local,DIRECT", "MATCH,B Select"]
        """
        try sourceB.write(to: airportB, atomically: true, encoding: .utf8)
        _ = model.configService.reloadConfigs()
        model.configService.selectConfig(airportA)
        let selectedA = try #require(model.configService.selectedConfig)
        let session = self.configureAPI(for: model, pause: putPause)
        defer {
            model.cancelOwnedTasks()
            session.invalidateAndCancel()
        }

        let switching = Task { await model.selectConfigFile(named: "airport-b.yaml") }
        await validationPause.waitUntilPaused()
        let saving = Task {
            try await model.saveChainProxySettings(enabled: true, landing: landing)
        }
        // Complete switch validation while the save's PUT response is still suspended.
        await putPause.waitUntilPaused()
        await validationPause.release()
        try await Task.sleep(for: .milliseconds(200))
        #expect(model.configService.selectedConfig == selectedA)
        #expect(core.restartPaths.isEmpty)
        await putPause.release()
        let result = await saving.result
        await switching.value
        try result.get()

        #expect(model.configService.selectedConfig?.lastPathComponent == "airport-b.yaml")
        #expect(core.restartPaths.count == 1)
        let restartedPath = try #require(core.restartPaths.last)
        let yaml = try String(contentsOfFile: restartedPath, encoding: .utf8)
        let runtime = try #require(try Yams.load(yaml: yaml) as? [String: Any])
        #expect(runtime["mixed-port"] as? Int == 7891)
        let proxies = try #require(runtime["proxies"] as? [[String: Any]])
        let runtimeFront = try #require(proxies.first { $0["name"] as? String == "B Node" })
        let runtimeLanding = try #require(proxies.first { $0["dialer-proxy"] as? String == "B Select" })
        #expect(runtimeFront["server"] as? String == "b.example.com")
        #expect(runtimeLanding["server"] as? String == "exit.example.com")
        #expect(runtimeLanding["dialer-proxy"] as? String == "B Select")
        let saved = try #require(try ChainProxyConfigService.readSettings(
            workingDirectory: model.workingDirectoryManager.rootDirectoryURL))
        #expect(saved.enabled)
        #expect(saved.landing == landing)
        #expect(model.chainProxySettings == saved)
        #expect(!model.isChainProxySaving)
        #expect(!model.isCoreActionProcessing)
    }

    @Test(arguments: [false, true])
    func remoteSwitchWaitsForLocalSaveAndRollback(failSave: Bool) async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let core = RecordingChainCore(running: true)
        let (model, _, landing) = try self.configuredModel(home: home, core: core)
        let root = model.workingDirectoryManager.rootDirectoryURL
        let previous = ChainProxySettings(enabled: false, id: UUID(), landing: landing)
        try ChainProxyConfigService.writeSettings(previous, workingDirectory: root)
        model.loadChainProxySettings()
        let probePause = ChainValidationPause()
        let putPause = ChainValidationPause()
        let session = self.configureAPI(for: model, pause: putPause)
        let api = ChainAPIProtocol.state
        api.configureRemoteProbe(pause: probePause, failPUT: failSave)
        defer {
            model.cancelOwnedTasks()
            session.invalidateAndCancel()
        }
        let machine = RemoteMachine(name: "Remote test", host: "remote.test")
        model.remoteMachineStore.addMachine(machine)

        let switching = Task { await model.switchToMachineTarget(.remote(machine)) }
        await probePause.waitUntilPaused()
        let saving = Task { () -> Error? in
            do {
                try await model.saveChainProxySettings(enabled: true, landing: landing)
                return nil
            } catch {
                return error
            }
        }
        // Finish probing while the local PUT is suspended; the target must stay local through rollback too.
        await putPause.waitUntilPaused()
        await probePause.release()
        try await Task.sleep(for: .milliseconds(200))
        #expect(model.remoteMachineStore.activeTarget.isLocal)
        #expect(model.apiClient?.controller == "http://chain.test:9090")
        await putPause.release()
        let error = await saving.value
        await switching.value

        #expect((error != nil) == failSave)
        #expect(model.remoteMachineStore.activeTarget == .remote(machine))
        #expect(api.appliedPaths.count == (failSave ? 2 : 1))
        let mutations = api.requests.filter { $0.method != "GET" }
        #expect(!mutations.isEmpty)
        #expect(mutations.allSatisfy { $0.host == "chain.test" })
        let saved = try #require(try ChainProxyConfigService.readSettings(workingDirectory: root))
        #expect(saved.enabled == !failSave)
        #expect(model.chainProxySettings == saved)
        if failSave {
            #expect(saved == previous)
            let rolledBackPath = try #require(api.appliedPaths.last)
            #expect(try String(contentsOfFile: rolledBackPath, encoding: .utf8) == self.source)
        }
        #expect(!model.isChainProxySaving)
        #expect(!model.isRuntimeConfigUpdating)
    }

    @Test(arguments: [true, false])
    func nodeSwitchWaitsForChainToggleAndFollowsTheAirportGroup(global: Bool) async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let (model, config, landing) = try self.configuredModel(home: home, core: RecordingChainCore(running: true))
        let pause = ChainValidationPause()
        let session = self.configureAPI(for: model, pause: pause)
        defer { session.invalidateAndCancel() }
        let api = ChainAPIProtocol.state
        api.seedAirportSelections()
        let saving = Task { try await model.saveChainProxySettings(enabled: true, landing: landing) }
        await pause.waitUntilPaused()
        let group = global ? "GLOBAL" : "Select"
        let switching = Task { await model.switchProxy(group: group, target: "Front") }
        try await Task.sleep(for: .milliseconds(150))
        #expect(model.chainProxySettings == nil)
        await pause.release()
        let result = await saving.result
        await switching.value
        try result.get()
        let settings = try #require(model.chainProxySettings)
        let actualGroup = global ? ChainProxyConfigService.globalFrontName(id: settings.id) : group
        #expect(api.selectedNode(in: actualGroup) == "Front")
        #expect(api.selectedNode(in: global ? "Select" : ChainProxyConfigService.globalFrontName(id: settings.id)) == "Exit")
        #expect(model.proxyGroups.first { $0.name == "GLOBAL" }?.all == ["Select", "Front", "Exit", "DIRECT", "REJECT"])
        #expect(api.appliedPaths.count == 1)
        #expect(settings.landing == landing)
        #expect(model.configService.selectedConfig == config)
        #expect(!model.isChainProxySaving)
        #expect(!model.isRuntimeConfigUpdating)
        try await model.saveChainProxySettings(enabled: false, landing: landing)
        #expect(api.selectedNode(in: group) == "Front")
        #expect(api.appliedPaths.last == config.path)
        #expect(model.chainProxySettings?.landing == landing)
    }

    @Test func chainFailuresAndConnectionErrorsPersistInExistingLogsWithoutCredentials() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let (model, _, _) = try self.configuredModel(home: home, core: RecordingChainCore(rejectsValidation: true))
        let node = try ChainProxyConfigService.makeNode(
            name: "Private Exit", yaml: "type: socks5\nserver: exit.example.com\nport: 443\nusername: private-user\npassword: private-password")
        do {
            try await model.saveChainProxySettings(enabled: true, landing: node)
            Issue.record("Expected validation failure")
        } catch {}
        let details = "SOCKS auth private-user private-password timeout at exit.example.com:443"
        model.logChainProxyFailure(operation: "log.chain.apply", error: APIError.statusCode(502, details))
        model.logChainProxyFailure(operation: "log.chain.rollback", error: APIError.statusCode(503, details))
        model.logChainProxyFailure(operation: "log.chain.latency", error: ChainProxyLatencyError.failed(details))
        model.appendMihomoLog(level: "warning", message: "[TCP] dial Chain Proxy: " + details)
        model.flushPendingMihomoLogsIfNeeded()
        let messages = model.errorLogs.map(\.message)
        #expect(messages.contains { $0.contains(model.tr("log.chain.validate")) })
        #expect(messages.contains { $0.contains(model.tr("log.chain.apply")) && $0.contains("502") })
        #expect(messages.contains { $0.contains(model.tr("log.chain.rollback")) && $0.contains("503") })
        #expect(messages.contains { $0.contains(model.tr("log.chain.latency")) && $0.contains("timeout") })
        #expect(model.errorLogs.contains { $0.source == .mihomo && $0.level == "warning" })
        model.clashbarLogStore?.flush()
        model.mihomoLogStore?.flush()
        let logs = model.workingDirectoryManager.logsDirectoryURL
        let persisted = try String(contentsOf: logs.appendingPathComponent("app.log"), encoding: .utf8)
            + String(contentsOf: logs.appendingPathComponent("core.log"), encoding: .utf8)
        for message in messages + [persisted] {
            #expect(!message.contains("private-user"))
            #expect(!message.contains("private-password"))
        }
        #expect(persisted.contains("timeout at exit.example.com:443"))
    }

    @Test(arguments: [true, false])
    func persistenceAndRollbackFailuresAreLogged(rollbackFails: Bool) async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let (model, config, landing) = try self.configuredModel(home: home, core: RecordingChainCore(running: true))
        let session = self.configureAPI(for: model)
        defer { session.invalidateAndCancel() }
        if rollbackFails {
            ChainAPIProtocol.state.failNextConfigPUT(count: 2)
        } else {
            // Block only settings persistence after the runtime configuration was applied.
            try FileManager.default.createDirectory(
                at: ChainProxyConfigService.settingsURL(workingDirectory: model.workingDirectoryManager.rootDirectoryURL),
                withIntermediateDirectories: true)
        }
        do {
            try await model.saveChainProxySettings(enabled: true, landing: landing)
            Issue.record("Expected apply or persistence failure")
        } catch {}
        let stage = model.tr(rollbackFails ? "log.chain.rollback" : "log.chain.save")
        #expect(model.errorLogs.contains { $0.level == "error" && $0.message.contains(stage) })
        #expect(ChainAPIProtocol.state.appliedPaths.count == 2)
        #expect(model.chainProxySettings == nil)
        #expect(model.configService.selectedConfig == config)
        #expect(!model.isChainProxySaving)
        #expect(!model.isRuntimeConfigUpdating)
    }

    private func mockSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChainAPIProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func configureAPI(for model: AppViewModel, pause: ChainValidationPause? = nil) -> URLSession {
        ChainAPIProtocol.state.reset(pause: pause)
        let session = self.mockSession()
        model.controller = "http://chain.test:9090"
        model.apiClient = MihomoAPIService(controller: model.controller, secret: nil, session: session)
        model.apiStatus = .healthy
        model.activeMenuTab = .logs
        return session
    }

    private let source = """
    proxies:
      - {name: Front, type: socks5, server: front.example.com, port: 1080}
      - {name: Exit, type: socks5, server: exit.example.com, port: 1080}
    proxy-groups: [{name: Select, type: select, proxies: [Front, Exit]}]
    rules: ["MATCH,Select"]
    """

    private func configuredModel(home: URL, core: RecordingChainCore) throws
        -> (AppViewModel, URL, ChainProxyNode)
    {
        let model = try self.model(home: home, core: core)
        let config = model.workingDirectoryManager.configDirectoryURL.appendingPathComponent("airport.yaml")
        try self.source.write(to: config, atomically: true, encoding: .utf8)
        _ = model.configService.reloadConfigs()
        model.configService.selectConfig(config)
        let landing = try ChainProxyConfigService.makeNode(
            name: "Exit", yaml: "type: socks5\nserver: exit.example.com\nport: 1080")
        return (model, config, landing)
    }

    private func model(home: URL, core: RecordingChainCore) throws -> AppViewModel {
        let working = WorkingDirectoryManager(homeDirectory: home)
        try working.bootstrapDirectories()
        let config = ConfigService(
            configManager: ConfigDirectoryManager(workingDirectoryManager: working),
            configImportService: ConfigImportService())
        config.setConfigDirectory(working.configDirectoryURL)
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        return AppViewModel(dependencies: AppDependencies(
            processManager: core,
            configService: config,
            systemProxyService: SystemProxyService(),
            tunPermissionService: TunPermissionService(),
            launchAtLoginService: AppLaunchService(),
            workingDirectoryManager: working,
            networkReachabilityMonitor: NetworkReachabilityMonitor(),
            ssidMonitorService: SSIDMonitorService(),
            remoteMachineStore: RemoteMachineStore(session: self.mockSession(), defaults: defaults),
            proxyGroupIconCache: ProxyGroupIconCache(iconDirectory: working.iconDirectoryURL, session: nil),
            clashbarLogStore: AppLogStore(logFileURL: working.logsDirectoryURL.appendingPathComponent("app.log")),
            mihomoLogStore: AppLogStore(logFileURL: working.logsDirectoryURL.appendingPathComponent("core.log"))))
    }
}

private final class RecordingChainCore: MihomoControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []
    private var restarts: [String] = []
    private let rejectsValidation: Bool
    private let running: Bool
    private let pause: ChainValidationPause?

    init(rejectsValidation: Bool = false, running: Bool = false, pause: ChainValidationPause? = nil) {
        self.rejectsValidation = rejectsValidation
        self.running = running
        self.pause = pause
    }

    var status: CoreLifecycleStatus { self.running ? .running(pid: 123) : .stopped }
    var isRunning: Bool { self.running }
    var detectedBinaryPath: String? { nil }
    var validationPaths: [String] { self.lock.withLock { self.paths } }
    var restartPaths: [String] { self.lock.withLock { self.restarts } }

    func validateConfigAsync(configPath: String) async throws {
        let isFirst = self.lock.withLock {
            self.paths.append(configPath)
            return self.paths.count == 1
        }
        if isFirst { await self.pause?.suspend() }
        if self.rejectsValidation { throw ChainProxyConfigError.invalidConfig }
    }

    func startAsync(configPath: String, controller: String) async throws -> CoreLifecycleStatus { .stopped }
    func restartAsync(configPath: String, controller: String) async throws -> CoreLifecycleStatus {
        self.lock.withLock { self.restarts.append(configPath) }
        return self.status
    }
    func stop() {}
    func stopAsync() async {}
}

private actor ChainValidationPause {
    private var paused = false
    private var arrival: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func suspend() async {
        self.paused = true
        self.arrival?.resume()
        self.arrival = nil
        await withCheckedContinuation { self.releaseContinuation = $0 }
    }

    func waitUntilPaused() async {
        if self.paused { return }
        await withCheckedContinuation { self.arrival = $0 }
    }

    func release() {
        self.releaseContinuation?.resume()
        self.releaseContinuation = nil
    }
}

private final class ChainAPIState: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []
    private var nextPUTPause: ChainValidationPause?
    private var nextProbePause: ChainValidationPause?
    private var failedPUTsRemaining = 0
    private var recordedRequests: [(host: String, method: String)] = []

    private var proxySnapshot: [String: [String: Any]] = [:]

    func seedAirportSelections() {
        self.lock.withLock {
            self.proxySnapshot = [
                "GLOBAL": ["name": "GLOBAL", "type": "Selector", "all": ["Select", "Front", "Exit"], "now": "Exit"],
                "Select": ["name": "Select", "type": "Selector", "all": ["Front", "Exit"], "now": "Exit"],
            ]
        }
    }

    func selectedNode(in group: String) -> String? {
        self.lock.withLock { self.proxySnapshot[group]?["now"] as? String }
    }

    var requests: [(host: String, method: String)] { self.lock.withLock { self.recordedRequests } }
    var appliedPaths: [String] { self.lock.withLock { self.paths } }

    func reset(pause: ChainValidationPause? = nil) {
        self.lock.withLock {
            self.proxySnapshot = [:]
            self.paths.removeAll()
            self.nextPUTPause = pause
            self.nextProbePause = nil
            self.failedPUTsRemaining = 0
            self.recordedRequests.removeAll()
        }
    }

    func failNextConfigPUT(count: Int = 1) {
        self.lock.withLock { self.failedPUTsRemaining = count }
    }

    func configureRemoteProbe(pause: ChainValidationPause, failPUT: Bool) {
        self.lock.withLock {
            self.nextProbePause = pause
            self.failedPUTsRemaining = failPUT ? 1 : 0
        }
    }

    private func requestBody(_ request: URLRequest) throws -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { throw URLError(.cannotDecodeRawData) }
        stream.open()
        defer { stream.close() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else { throw URLError(.cannotDecodeRawData) }
            if count == 0 { break }
            result.append(contentsOf: buffer.prefix(count))
        }
        return result
    }

    func response(to request: URLRequest) async throws -> Data {
        self.lock.withLock {
            self.recordedRequests.append((request.url?.host ?? "", request.httpMethod ?? "GET"))
        }
        if request.url?.host == "remote.test", request.url?.path == "/version" {
            let pause = self.lock.withLock {
                let pause = self.nextProbePause
                self.nextProbePause = nil
                return pause
            }
            await pause?.suspend()
        }
        if request.url?.path == "/configs", request.httpMethod == "PUT" {
            let body = try self.requestBody(request)
            let payload = try JSONSerialization.jsonObject(with: body) as? [String: String]
            guard let path = payload?["path"] else { throw URLError(.cannotDecodeRawData) }
            // Model a reload that resets choices, so restoration must use the real selection API.
            let yaml = try String(contentsOfFile: path, encoding: .utf8)
            let config = try Yams.load(yaml: yaml) as? [String: Any] ?? [:]
            let groups = config["proxy-groups"] as? [[String: Any]] ?? []
            var snapshot: [String: [String: Any]] = [:]
            for group in groups {
                guard let name = group["name"] as? String else { continue }
                let all = group["proxies"] as? [String] ?? []
                snapshot[name] = ["name": name, "type": "Selector", "all": all, "now": all.first ?? "",
                                  "hidden": group["hidden"] as? Bool ?? false]
            }
            if snapshot["GLOBAL"] == nil {
                let names = groups.compactMap { $0["name"] as? String }
                    + (config["proxies"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
                snapshot["GLOBAL"] = ["name": "GLOBAL", "type": "Selector", "all": names, "now": names.first ?? ""]
            }
            self.lock.withLock { self.proxySnapshot = snapshot }
            let (pause, fail) = self.lock.withLock {
                self.paths.append(path)
                let pause = self.nextPUTPause
                let fail = self.failedPUTsRemaining > 0
                self.nextPUTPause = nil
                if fail { self.failedPUTsRemaining -= 1 }
                return (pause, fail)
            }
            await pause?.suspend()
            if fail { throw URLError(.cannotDecodeRawData) }
        }
        if request.url?.path == "/configs", request.httpMethod == "GET" {
            let enabled = request.url?.host == "remote.test"
            return Data("{\"mode\":\"rule\",\"tun\":{\"enable\":\(enabled)}}".utf8)
        }
        if request.url?.path == "/version" { return Data(#"{"version":"v1.19.27"}"#.utf8) }
        if request.url?.path == "/proxies" {
            let snapshot = self.lock.withLock { self.proxySnapshot }
            return try JSONSerialization.data(withJSONObject: ["proxies": snapshot])
        }
        if request.url?.path.hasPrefix("/proxies/") == true, request.httpMethod == "PUT" {
            let data = try self.requestBody(request)
            let body = try JSONSerialization.jsonObject(with: data) as? [String: String]
            let group = request.url?.lastPathComponent ?? ""
            guard let target = body?["name"] else { throw URLError(.cannotDecodeRawData) }
            try self.lock.withLock {
                guard (self.proxySnapshot[group]?["all"] as? [String])?.contains(target) == true else {
                    throw URLError(.badServerResponse)
                }
                self.proxySnapshot[group]?["now"] = target
            }
        }
        if request.url?.path.hasPrefix("/providers/") == true { return Data(#"{"providers":{}}"#.utf8) }
        return Data("{}".utf8)
    }
}

private final class ChainAPIProtocol: URLProtocol, @unchecked Sendable {
    // The test suite is serialized, so every case can use the same mock state.
    static let state = ChainAPIState()
    private let lock = NSLock()
    private var responseTask: Task<Void, Never>?

    override class func canInit(with request: URLRequest) -> Bool {
        ["chain.test", "remote.test"].contains(request.url?.host ?? "")
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        self.lock.withLock { self.responseTask = Task { await self.respond() } }
    }

    private func respond() async {
        do {
            guard let url = self.request.url,
                  let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
            else { throw URLError(.badServerResponse) }
            let data = try await Self.state.response(to: self.request)
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: data)
            self.client?.urlProtocolDidFinishLoading(self)
        } catch {
            self.client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() { self.lock.withLock { self.responseTask?.cancel() } }
}
