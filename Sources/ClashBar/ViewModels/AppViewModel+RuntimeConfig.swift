import Foundation

@MainActor
extension AppViewModel {
    // Acquire only once per operation; the caller releases with defer on every exit path.
    // Chain saves and local node switches hold isLocalRuntimeChanging through waiting,
    // rollback and refresh; reloads and read-only snapshots use only this gate.
    func beginRuntimeConfigUpdate() async throws {
        while self.isRuntimeConfigUpdating {
            try await Task.sleep(for: .milliseconds(100))
        }
        try Task.checkCancellation()
        self.isRuntimeConfigUpdating = true
    }

    func waitForLocalRuntimeChange() async -> Bool {
        while self.isLocalRuntimeChanging {
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return false }
        }
        return !Task.isCancelled
    }

    func airportGroupName(_ group: String, proxies: [String: ProxyGroup], settings: ChainProxySettings?) -> String {
        guard group == "GLOBAL", let settings else { return group }
        let hidden = ChainProxyConfigService.globalFrontName(id: settings.id)
        return proxies[hidden] == nil ? group : hidden
    }

    func reloadLocalRuntimeConfig(
        configPath: String, from previous: ChainProxySettings?, to settings: ChainProxySettings?) async throws
    {
        guard !self.isRemoteTarget else { throw ChainProxyConfigError.sourceChanged }
        let client = try self.clientOrThrow()
        let expectedTunEnabled = self.isTunEnabled
        var selections: [String: String] = [:]
        let previousGlobal = previous.flatMap {
            $0.enabled ? ChainProxyConfigService.globalFrontName(id: $0.id) : nil
        }
        if previousGlobal != nil || settings?.enabled == true {
            let response: ProxyGroupsResponse = try await client.request(.proxies)
            let actualPreviousGlobal = previousGlobal.flatMap { response.proxies[$0] == nil ? nil : $0 }
            for proxy in response.proxies.values {
                guard proxy.type?.lowercased() == "selector", let selected = proxy.now,
                      proxy.all.contains(selected), actualPreviousGlobal == nil || proxy.name != "GLOBAL"
                else { continue }
                selections[proxy.name == actualPreviousGlobal ? "GLOBAL" : proxy.name] = selected
            }
        }
        try await client.requestNoResponse(.putConfigs(force: false, path: configPath, payload: nil))
        if !selections.isEmpty {
            let response: ProxyGroupsResponse = try await client.request(.proxies)
            for (group, selected) in selections {
                let name = self.airportGroupName(group, proxies: response.proxies, settings: settings)
                if response.proxies[name]?.type?.lowercased() == "selector",
                   response.proxies[name]?.all.contains(selected) == true
                {
                    try await client.requestNoResponse(.switchProxy(name: name, target: selected))
                }
            }
        }
        try await self.restoreTunAfterConfigReloadIfNeeded(expectedEnabled: expectedTunEnabled)
    }

    func restoreTunAfterConfigReloadIfNeeded(expectedEnabled: Bool) async throws {
        guard isRuntimeRunning else { return }
        try await self.patchTunConfig(enable: expectedEnabled)
        try await self.verifyTunRuntimeState(expectedEnabled: expectedEnabled)
        if isTunEnabled != expectedEnabled {
            isTunEnabled = expectedEnabled
            persistEditableSettingsSnapshot()
        }
    }

}
