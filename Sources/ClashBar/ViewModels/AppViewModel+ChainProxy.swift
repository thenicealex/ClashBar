import Foundation

@MainActor
extension AppViewModel {
    func beginRuntimeConfigUpdate() async throws {
        while self.isRuntimeConfigUpdating {
            try await Task.sleep(for: .milliseconds(100))
        }
        try Task.checkCancellation()
        self.isRuntimeConfigUpdating = true
    }

    func waitForChainProxySave() async -> Bool {
        while self.isChainProxySaving {
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return false }
        }
        return !Task.isCancelled
    }

    func loadChainProxySettings() {
        do {
            self.chainProxySettings = try ChainProxyConfigService.readSettings(
                workingDirectory: self.workingDirectoryManager.rootDirectoryURL)
            self.chainProxySettingsLoadFailed = false
        } catch {
            self.chainProxySettingsLoadFailed = true
            self.appendLog(level: "error", message: self.tr("ui.chain.saved_load_failed"))
        }
    }

    func runtimeConfigPath(for configPath: String) async throws -> String {
        guard !self.chainProxySettingsLoadFailed else { throw ChainProxyConfigError.invalidSavedSettings }
        return try await self.runtimeConfigPath(for: configPath, using: self.chainProxySettings)
    }

    func runtimeConfigPath(for configPath: String, using settings: ChainProxySettings?) async throws -> String {
        let root = self.workingDirectoryManager.rootDirectoryURL
        return try await Task.detached {
            try ChainProxyConfigService.prepareRuntimeConfig(
                configURL: URL(fileURLWithPath: configPath), workingDirectory: root, settings: settings).path
        }.value
    }

    func saveChainProxySettings(enabled: Bool, front: ChainProxyNode, landing: ChainProxyNode) async throws {
        guard !self.isRemoteTarget, !self.isCoreActionProcessing, !self.isChainProxySaving else {
            throw ChainProxyConfigError.sourceChanged
        }
        self.isChainProxySaving = true
        defer { self.isChainProxySaving = false }
        try await self.beginRuntimeConfigUpdate()
        defer { self.isRuntimeConfigUpdating = false }
        guard !self.isRemoteTarget, !self.isCoreActionProcessing else {
            throw ChainProxyConfigError.sourceChanged
        }
        let previous = self.chainProxySettings
        let settings = ChainProxySettings(enabled: enabled, id: previous?.id ?? UUID(), front: front, landing: landing)
        let selectedURL = self.configService.selectedConfig
        let root = self.workingDirectoryManager.rootDirectoryURL
        let wasRunning = self.processManager.isRunning
        var appliedToRuntime = false

        do {
            if let selectedURL {
                let source = try Data(contentsOf: selectedURL)
                let runtimePath = try await self.runtimeConfigPath(for: selectedURL.path, using: settings)
                try await self.processManager.validateConfig(configPath: runtimePath)
                guard !self.isRemoteTarget, self.configService.selectedConfig == selectedURL,
                      !self.isCoreActionProcessing, try Data(contentsOf: selectedURL) == source
                else { throw ChainProxyConfigError.sourceChanged }
                if wasRunning {
                    // Mark before the request: an error response may arrive after the core applied the config.
                    appliedToRuntime = true
                    try await self.reloadLocalRuntimeConfig(configPath: runtimePath)
                }
            }
            try ChainProxyConfigService.writeSettings(settings, workingDirectory: root)
            self.chainProxySettings = settings
            self.chainProxySettingsLoadFailed = false
            if wasRunning { await self.refreshFromAPI(includeSlowCalls: true) }
        } catch {
            if appliedToRuntime, let selectedURL {
                do {
                    let previousPath = try await self.runtimeConfigPath(for: selectedURL.path, using: previous)
                    try await self.reloadLocalRuntimeConfig(configPath: previousPath)
                } catch {
                    self.appendLog(level: "error", message: self.tr("ui.chain.rollback_failed"))
                }
            }
            throw error
        }
    }
}
