import Foundation

@MainActor
extension AppViewModel {
    func loadChainProxySettings() {
        do {
            self.chainProxySettings = try ChainProxyConfigService.readSettings(
                workingDirectory: self.workingDirectoryManager.rootDirectoryURL)
            self.chainProxySettingsLoadFailed = false
            if let node = self.chainProxySettings?.landing { self.chainProxyLogRedactor.include(yaml: node.yaml) }
            if let nodes = try? ChainProxyConfigService.readNodes(
                workingDirectory: self.workingDirectoryManager.rootDirectoryURL, settings: self.chainProxySettings)
            {
                for node in nodes { self.chainProxyLogRedactor.include(yaml: node.yaml) }
            }
        } catch {
            self.chainProxySettingsLoadFailed = true
            self.appendLog(level: "error", message: self.tr("ui.chain.saved_load_failed"))
        }
        do {
            self.chainProxyFrontSelections = try ChainProxyConfigService.readFrontSelections(
                workingDirectory: self.workingDirectoryManager.rootDirectoryURL)
        } catch {
            self.chainProxyFrontSelections = [:]
            self.appendLog(level: "error", message: self.tr("ui.chain.front_load_failed"))
        }
    }

    func runtimeConfigPath(for configPath: String) async throws -> String {
        guard !self.chainProxySettingsLoadFailed else { throw ChainProxyConfigError.invalidSavedSettings }
        return try await self.runtimeConfigPath(for: configPath, using: self.chainProxySettings)
    }

    func runtimeConfigPath(for configPath: String, using settings: ChainProxySettings?) async throws -> String {
        let root = self.workingDirectoryManager.rootDirectoryURL
        let key = ChainProxyConfigService.frontKey(for: URL(fileURLWithPath: configPath))
        let front = self.chainProxyFrontSelections[key]
        let result = try await Task.detached {
            try ChainProxyConfigService.prepareRuntimeConfig(
                configURL: URL(fileURLWithPath: configPath), workingDirectory: root, settings: settings, front: front)
        }.value
        if settings?.enabled == true {
            if result.isChained { self.unavailableChainProxyFronts.remove(key) }
            else {
                self.unavailableChainProxyFronts.insert(key)
                self.appendLog(level: "warning", message: self.tr("ui.chain.front_missing"))
            }
        }
        return result.url.path
    }

    func saveChainProxySettings(enabled: Bool, landing: ChainProxyNode) async throws {
        self.chainProxyLogRedactor.include(yaml: landing.yaml)
        let operation = enabled ? "log.chain.enable" : "log.chain.disable"
        self.appendLog(level: "info", message: self.tr("log.chain.started", self.tr(operation)))
        guard !self.isRemoteTarget, !self.isCoreActionProcessing, !self.isLocalRuntimeChanging else {
            self.logChainProxyFailure(operation: operation, error: ChainProxyConfigError.sourceChanged)
            throw ChainProxyConfigError.sourceChanged
        }
        self.isLocalRuntimeChanging = true
        defer { self.isLocalRuntimeChanging = false }
        do {
            try await self.beginRuntimeConfigUpdate()
        } catch {
            self.logChainProxyFailure(operation: operation, error: error)
            throw error
        }
        defer { self.isRuntimeConfigUpdating = false }
        guard !self.isRemoteTarget, !self.isCoreActionProcessing else {
            self.logChainProxyFailure(operation: operation, error: ChainProxyConfigError.sourceChanged)
            throw ChainProxyConfigError.sourceChanged
        }
        let previous = self.chainProxySettings
        let previousUnavailable = self.unavailableChainProxyFronts
        let settings = ChainProxySettings(enabled: enabled, id: previous?.id ?? UUID(), landing: landing)
        let selectedURL = self.configService.selectedConfig
        let root = self.workingDirectoryManager.rootDirectoryURL
        let wasRunning = self.processManager.isRunning
        var appliedToRuntime = false
        var stage = "log.chain.validate"

        do {
            if enabled, selectedURL == nil { throw ChainProxyConfigError.missingAirportFront }
            if let selectedURL {
                let source = try Data(contentsOf: selectedURL)
                let runtimePath = try await self.runtimeConfigPath(for: selectedURL.path, using: settings)
                if enabled, self.currentChainProxyFront == nil { throw ChainProxyConfigError.missingAirportFront }
                try await self.processManager.validateConfig(configPath: runtimePath)
                guard !self.isRemoteTarget, self.configService.selectedConfig == selectedURL,
                      !self.isCoreActionProcessing, try Data(contentsOf: selectedURL) == source
                else { throw ChainProxyConfigError.sourceChanged }
                if wasRunning {
                    // Mark before the request: an error response may arrive after the core applied the config.
                    stage = "log.chain.apply"
                    appliedToRuntime = true
                    try await self.reloadLocalRuntimeConfig(configPath: runtimePath, from: previous, to: settings)
                }
            }
            stage = "log.chain.save"
            try ChainProxyConfigService.writeSettings(settings, workingDirectory: root)
            self.chainProxySettings = settings
            self.chainProxySettingsLoadFailed = false
            self.appendLog(level: "info", message: self.tr("log.chain.succeeded", self.tr(operation)))
            if wasRunning { await self.refreshFromAPI(includeSlowCalls: true) }
        } catch {
            self.logChainProxyFailure(operation: stage, error: error)
            if appliedToRuntime, let selectedURL {
                do {
                    let previousPath = try await self.runtimeConfigPath(for: selectedURL.path, using: previous)
                    try await self.reloadLocalRuntimeConfig(configPath: previousPath, from: settings, to: previous)
                    self.appendLog(level: "info", message: self.tr("log.chain.succeeded", self.tr("log.chain.rollback")))
                } catch {
                    self.logChainProxyFailure(operation: "log.chain.rollback", error: error)
                }
            }
            self.unavailableChainProxyFronts = previousUnavailable
            throw error
        }
    }

    func measureChainProxyLatency(node: ChainProxyNode) async throws -> Int {
        self.chainProxyLogRedactor.include(yaml: node.yaml)
        let frontYAML: String
        let binary: String
        do {
            try await self.beginRuntimeConfigUpdate()
            defer { self.isRuntimeConfigUpdating = false }
            let target = self.remoteMachineStore.activeTarget
            let mode = self.currentMode
            guard !self.isRemoteTarget, !self.isCoreActionProcessing, !self.modeSwitchInFlight, self.processManager.isRunning,
                  let selected = self.configService.selectedConfig,
                  let path = self.processManager.detectedBinaryPath
            else { throw ChainProxyLatencyError.unavailable }
            let source = try String(contentsOf: selected, encoding: .utf8)
            let response: ProxyGroupsResponse = try await self.clientOrThrow().request(.proxies)
            var selections = response.proxies.compactMapValues(\.now)
            if let settings = self.chainProxySettings, settings.enabled {
                selections["GLOBAL"] = selections[ChainProxyConfigService.globalFrontName(id: settings.id)]
            }
            guard let front = self.currentChainProxyFront else { throw ChainProxyConfigError.missingAirportFront }
            let workingDirectory = self.workingDirectoryManager.rootDirectoryURL
            let snapshotSelections = selections
            frontYAML = try await Task.detached {
                try ChainProxyLatencyService.airportSnapshot(
                    sourceYAML: source, selections: snapshotSelections, front: front, workingDirectory: workingDirectory)
            }.value
            guard target == self.remoteMachineStore.activeTarget, !self.isRemoteTarget,
                  !self.isCoreActionProcessing, !self.modeSwitchInFlight, self.currentMode == mode, self.processManager.isRunning,
                  self.configService.selectedConfig == selected,
                  try String(contentsOf: selected, encoding: .utf8) == source
            else { throw ChainProxyConfigError.sourceChanged }
            self.chainProxyLogRedactor.include(yaml: frontYAML)
            binary = path
        }
        return try await ChainProxyLatencyService.measure(
            node: node, frontYAML: frontYAML, binaryPath: binary,
            url: self.defaultHealthcheckURL, timeout: self.defaultHealthcheckTimeoutMilliseconds)
    }

    func logChainProxyFailure(operation: String, error: Error) {
        self.appendLog(level: "error", message: self.tr("log.chain.failed", self.tr(operation), self.coreErrorMessage(error)))
    }
}
