import SwiftUI

// swiftlint:disable:next type_name
private typealias T = MenuBarLayoutTokens

private let panelHeight: CGFloat = 500
private let contentPadding: CGFloat = T.space8 * 2

struct ChainProxyConfigView: TranslatingView {
    @EnvironmentObject var appViewModel: AppViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var snapshot: ChainProxyConfigSnapshot?
    @State private var frontID = ""
    @State private var landingID = ""
    @State private var enabled = true
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var saved = false

    var body: some View {
        VStack(spacing: 0) {
            self.header
            ScrollView {
                self.form
                    .padding(.horizontal, contentPadding)
                    .padding(.bottom, contentPadding)
            }
            .scrollIndicators(.hidden)
            self.actions
                .padding(.horizontal, contentPadding)
                .padding(.bottom, contentPadding)
        }
        .background(self.nativeControlFill)
        .frame(width: T.panelWidth, height: panelHeight)
        .disabled(self.appViewModel.isChainProxySaving)
        .interactiveDismissDisabled(self.appViewModel.isChainProxySaving)
        .task { await self.load(initial: true) }
    }

    private var header: some View {
        HStack(spacing: T.space6) {
            Label(self.tr("ui.chain.title"), systemImage: "link")
                .font(.app(size: T.FontSize.title3, weight: .semibold))
                .foregroundStyle(self.nativePrimaryLabel)
            Spacer()
            Button {
                self.dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.app(size: T.FontSize.title3, weight: .semibold))
                    .foregroundStyle(self.nativeTertiaryLabel)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help(self.tr("ui.chain.close"))
        }
        .padding([.horizontal, .top], contentPadding)
        .padding(.bottom, T.space6 * 2)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: T.space8 * 2) {
            Text(self.tr("ui.chain.description"))
                .font(.app(size: T.FontSize.callout))
                .foregroundStyle(self.nativeSecondaryLabel)
                .fixedSize(horizontal: false, vertical: true)
            Toggle(self.tr("ui.chain.enabled"), isOn: self.$enabled)
                .toggleStyle(.switch)
                .controlSize(.regular)
                .font(.app(size: T.FontSize.body, weight: .medium))
                .foregroundStyle(self.nativePrimaryLabel)

            self.nodePicker(title: self.tr("ui.chain.front"), selection: self.$frontID, excluding: self.landingID)
            self.nodePicker(title: self.tr("ui.chain.landing"), selection: self.$landingID, excluding: self.frontID)
            if let front = self.node(for: self.frontID), let landing = self.node(for: self.landingID) {
                Text(self.tr("ui.chain.path", front.name, landing.name))
                    .font(.app(size: T.FontSize.caption))
                    .foregroundStyle(self.nativeSecondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if self.isLoading {
                ProgressView(self.tr("ui.chain.loading"))
                    .font(.app(size: T.FontSize.callout))
            } else if let snapshot {
                Text(self.tr("ui.chain.source", snapshot.sourceURL.lastPathComponent))
                    .font(.app(size: T.FontSize.caption))
                    .foregroundStyle(self.nativeSecondaryLabel)
                if self.choices.count < 2 {
                    Text(self.tr("ui.chain.no_nodes"))
                        .font(.app(size: T.FontSize.caption))
                        .foregroundStyle(self.nativeSecondaryLabel)
                }
                if !snapshot.unavailableProviders.isEmpty {
                    Text(self.tr("ui.chain.unavailable", snapshot.unavailableProviders.joined(separator: ", ")))
                        .font(.app(size: T.FontSize.caption))
                        .foregroundStyle(self.nativeSecondaryLabel)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if self.appViewModel.chainProxySettingsLoadFailed {
                Text(self.tr("ui.chain.saved_load_failed"))
                    .font(.app(size: T.FontSize.caption))
                    .foregroundStyle(self.nativeCritical)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.app(size: T.FontSize.caption))
                    .foregroundStyle(self.nativeCritical)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if self.saved {
                Text(self.tr("ui.chain.saved"))
                    .font(.app(size: T.FontSize.caption))
                    .foregroundStyle(self.nativeSecondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var actions: some View {
        HStack(spacing: T.space8) {
            Button(self.tr("ui.chain.refresh")) {
                Task { await self.load() }
            }
            .appBorderedButtonStyle()
            .disabled(self.isLoading || self.appViewModel.isChainProxySaving)
            Button {
                Task { await self.save() }
            } label: {
                Text(self.tr("ui.chain.apply"))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, T.space8)
            }
            .appBorderedButtonStyle(prominent: true)
            .keyboardShortcut(.defaultAction)
            .disabled(!self.canSave)
        }
        .font(.app(size: T.FontSize.body, weight: .medium))
        .controlSize(.large)
    }

    private var choices: [(id: String, node: ChainProxyNode)] {
        var result: [(id: String, node: ChainProxyNode)] = []
        if let settings = self.appViewModel.chainProxySettings {
            result += [("saved/front", settings.front), ("saved/landing", settings.landing)]
        }
        result += (self.snapshot?.nodes ?? []).map { ("available/\($0.id)", $0) }
        return result
    }

    private func node(for id: String) -> ChainProxyNode? {
        self.choices.first(where: { $0.id == id })?.node
    }

    private var canSave: Bool {
        guard let front = self.node(for: self.frontID), let landing = self.node(for: self.landingID) else {
            return false
        }
        return !self.isLoading && !self.appViewModel.isChainProxySaving
            && !self.appViewModel.isRemoteTarget && !self.appViewModel.isCoreActionProcessing
            && front.id != landing.id
    }

    private func nodePicker(title: String, selection: Binding<String>, excluding: String) -> some View {
        Picker(title, selection: selection) {
            Text(self.tr("ui.chain.choose")).tag("")
            ForEach(self.choices, id: \.id) { choice in
                if choice.node.id != self.node(for: excluding)?.id {
                    let suffix = choice.id.hasPrefix("saved/") ? self.tr("ui.chain.saved_node") : choice.node.source
                    Text("\(choice.node.name) · \(suffix)").tag(choice.id)
                }
            }
        }
        .pickerStyle(.menu)
        .controlSize(.large)
        .font(.app(size: T.FontSize.body))
        .foregroundStyle(self.nativePrimaryLabel)
    }

    @MainActor
    private func load(initial: Bool = false) async {
        guard !self.isLoading, !self.appViewModel.isChainProxySaving else { return }
        self.isLoading = true
        self.errorMessage = nil
        self.saved = false
        if initial, let settings = self.appViewModel.chainProxySettings {
            self.enabled = settings.enabled
            self.frontID = "saved/front"
            self.landingID = "saved/landing"
        }
        defer { self.isLoading = false }
        guard !self.appViewModel.isRemoteTarget, let configURL = self.appViewModel.configService.selectedConfig else {
            self.snapshot = nil
            if self.appViewModel.chainProxySettings == nil { self.errorMessage = self.tr("ui.chain.load_failed") }
            return
        }
        let root = self.appViewModel.workingDirectoryManager.rootDirectoryURL
        do {
            let loaded = try await Task.detached {
                try ChainProxyConfigService.load(configURL: configURL, workingDirectory: root)
            }.value
            guard !Task.isCancelled else { return }
            guard !self.appViewModel.isRemoteTarget, self.appViewModel.configService.selectedConfig == configURL else {
                throw ChainProxyConfigError.sourceChanged
            }
            self.snapshot = loaded
            if self.node(for: self.frontID) == nil { self.frontID = "" }
            if self.node(for: self.landingID) == nil { self.landingID = "" }
        } catch {
            self.snapshot = nil
            self.errorMessage = self.tr("ui.chain.load_failed")
        }
    }

    @MainActor
    private func save() async {
        guard self.canSave,
              let front = self.node(for: self.frontID),
              let landing = self.node(for: self.landingID)
        else {
            return
        }
        self.errorMessage = nil
        self.saved = false
        do {
            try await self.appViewModel.saveChainProxySettings(enabled: self.enabled, front: front, landing: landing)
            self.frontID = "saved/front"
            self.landingID = "saved/landing"
            self.saved = true
        } catch {
            self.errorMessage = self.tr("ui.chain.save_failed", self.appViewModel.coreErrorMessage(error))
        }
    }
}
