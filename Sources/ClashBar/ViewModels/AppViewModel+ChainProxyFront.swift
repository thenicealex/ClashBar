import Foundation

@MainActor
extension AppViewModel {
    var currentChainProxyFront: ChainProxyFrontSelection? {
        self.configService.selectedConfig.flatMap {
            let key = ChainProxyConfigService.frontKey(for: $0)
            return self.unavailableChainProxyFronts.contains(key) ? nil : self.chainProxyFrontSelections[key]
        }
    }

    var isChainProxyActive: Bool {
        !self.isRemoteTarget && !self.chainProxySettingsLoadFailed && self.chainProxySettings?.enabled == true && self.currentChainProxyFront != nil
    }

    // The caller holds the local transaction marker and runtime gate through rollback.
    func selectChainProxyFront(group: String, node: String, configURL: URL) async throws {
        let root = self.workingDirectoryManager.rootDirectoryURL
        let key = ChainProxyConfigService.frontKey(for: configURL)
        let previous = self.chainProxyFrontSelections[key]
        let source = try Data(contentsOf: configURL)
        let client = try self.clientOrThrow()
        let response: ProxyGroupsResponse = try await client.request(.proxies)
        let name = self.airportGroupName(group, proxies: response.proxies, settings: self.chainProxySettings)
        guard let current = response.proxies[name], current.all.contains(node), let oldNode = current.now,
              !node.isEmpty
        else { throw ChainProxyConfigError.missingAirportFront }
        var resolved = node
        var visited: Set<String> = []
        while let next = response.proxies[resolved]?.now {
            guard visited.insert(resolved).inserted else { throw ChainProxyConfigError.missingAirportFront }
            resolved = next
        }
        let bypass = ["DIRECT", "REJECT", "REJECT-DROP", "PASS"].contains(resolved)
            || ["direct", "reject", "reject-drop", "pass"].contains(response.proxies[resolved]?.type?.lowercased() ?? "")
        let front = bypass ? nil : ChainProxyFrontSelection(group: group, node: node)
        var updated = self.chainProxyFrontSelections
        updated[key] = front
        var applied = false
        var stage = "log.chain.apply"
        do {
            guard self.configService.selectedConfig == configURL, !self.isRemoteTarget else {
                throw ChainProxyConfigError.sourceChanged
            }
            try await client.requestNoResponse(.switchProxy(name: name, target: node))
            if let settings = self.chainProxySettings, settings.enabled,
               previous?.group != front?.group || self.unavailableChainProxyFronts.contains(key) {
                let runtime = try ChainProxyConfigService.prepareRuntimeConfig(
                    configURL: configURL, workingDirectory: root, settings: settings, front: front)
                guard front == nil || runtime.isChained else { throw ChainProxyConfigError.missingAirportFront }
                try await self.processManager.validateConfig(configPath: runtime.url.path)
                guard self.configService.selectedConfig == configURL, !self.isRemoteTarget,
                      try Data(contentsOf: configURL) == source
                else { throw ChainProxyConfigError.sourceChanged }
                applied = true
                try await self.reloadLocalRuntimeConfig(configPath: runtime.url.path, from: settings, to: settings)
            }
            guard self.configService.selectedConfig == configURL, !self.isRemoteTarget,
                  try Data(contentsOf: configURL) == source
            else { throw ChainProxyConfigError.sourceChanged }
            stage = "log.chain.save"
            try ChainProxyConfigService.writeFrontSelections(updated, workingDirectory: root)
            self.chainProxyFrontSelections = updated
            self.unavailableChainProxyFronts.remove(key)
            if front == nil, self.chainProxySettings?.enabled == true { self.appendLog(level: "warning", message: self.tr("ui.chain.front_missing")) }
        } catch {
            self.logChainProxyFailure(operation: stage, error: error)
            if applied {
                do {
                    let runtime = try ChainProxyConfigService.prepareRuntimeConfig(
                        configURL: configURL, workingDirectory: root, settings: self.chainProxySettings, front: previous)
                    try await self.reloadLocalRuntimeConfig(
                        configPath: runtime.url.path, from: self.chainProxySettings, to: self.chainProxySettings)
                } catch { self.logChainProxyFailure(operation: "log.chain.rollback", error: error) }
            }
            // Selection restoration remains useful even when runtime rollback fails.
            do {
                let response: ProxyGroupsResponse = try await client.request(.proxies)
                let rollbackGroup = self.airportGroupName(group, proxies: response.proxies, settings: self.chainProxySettings)
                try await client.requestNoResponse(.switchProxy(name: rollbackGroup, target: oldNode))
            } catch { self.logChainProxyFailure(operation: "log.chain.rollback", error: error) }
            throw error
        }
    }

    func restoreChainProxyFrontSelection() async throws {
        guard await self.waitForLocalRuntimeChange() else { throw CancellationError() }
        guard !self.isRemoteTarget else { return }
        self.isLocalRuntimeChanging = true
        defer { self.isLocalRuntimeChanging = false }
        try await self.beginRuntimeConfigUpdate()
        defer { self.isRuntimeConfigUpdating = false }
        guard let front = self.currentChainProxyFront, let config = self.configService.selectedConfig else { return }
        let target = self.remoteMachineStore.activeTarget
        let client = try self.clientOrThrow()
        let response: ProxyGroupsResponse = try await client.request(.proxies)
        guard target == self.remoteMachineStore.activeTarget, !self.isRemoteTarget,
              self.configService.selectedConfig == config, self.currentChainProxyFront == front else {
            throw ChainProxyConfigError.sourceChanged
        }
        let name = self.airportGroupName(front.group, proxies: response.proxies, settings: self.chainProxySettings)
        guard response.proxies[name]?.all.contains(front.node) == true else {
            throw ChainProxyConfigError.missingAirportFront
        }
        try await client.requestNoResponse(.switchProxy(name: name, target: front.node))
    }

}
