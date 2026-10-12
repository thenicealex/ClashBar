import SwiftUI
import Yams

// swiftlint:disable:next type_name
private typealias T = MenuBarLayoutTokens

private let panelHeight: CGFloat = 500
private let contentPadding: CGFloat = T.space8

private enum ChainNodeEditorMode {
    case add
    case edit(ChainProxyNode)

    var node: ChainProxyNode? {
        if case let .edit(node) = self { return node }
        return nil
    }
}

struct ChainProxyConfigView: TranslatingView {
    @EnvironmentObject var appViewModel: AppViewModel
    let onDismiss: () -> Void

    @State private var nodes: [ChainProxyNode] = []
    @State private var frontID = ""
    @State private var landingID = ""
    @State private var isApplying = false
    @State private var editorMode: ChainNodeEditorMode?
    @State private var isLibraryReadable = true
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            self.header
            if let mode = self.editorMode {
                ChainProxyNodeEditorView(node: mode.node, onSave: self.storeNode)
            } else {
                ScrollView {
                    self.form
                        .padding(.horizontal, contentPadding)
                        .padding(.bottom, contentPadding)
                }
                .scrollIndicators(.hidden)
            }
        }
        .frame(width: T.panelWidth - T.space8 * 2, height: panelHeight)
        .disabled(self.isApplying || self.appViewModel.isChainProxySaving || self.appViewModel.isCoreActionProcessing)
        .onAppear { self.load() }
    }

    private var header: some View {
        ZStack {
            HStack(spacing: T.space6) {
                Image(systemName: "link")
                    .foregroundStyle(self.nativePurple)
                Text(self.headerTitle)
                    .foregroundStyle(self.nativePrimaryLabel)
            }
            .font(.app(size: T.FontSize.title3, weight: .semibold))
            HStack {
                Button {
                    if self.editorMode != nil { self.editorMode = nil } else { self.onDismiss() }
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.app(size: T.FontSize.title3, weight: .medium))
                        .foregroundStyle(self.nativeSecondaryLabel)
                        .frame(width: T.rowHeight, height: T.rowHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .help(self.tr(self.editorMode == nil ? "ui.chain.close" : "ui.action.cancel"))
                Spacer()
            }
        }
        .frame(height: T.rowHeight)
        .padding(.horizontal, contentPadding)
        .padding(.vertical, T.space8)
    }

    private var headerTitle: String {
        guard let mode = self.editorMode else { return self.tr("ui.chain.title") }
        return self.tr(mode.node == nil ? "ui.chain.node_add" : "ui.chain.node_edit")
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: T.space8) {
            Toggle(self.tr("ui.chain.enabled"), isOn: Binding(
                get: { self.enabled }, set: self.setEnabled))
                .toggleStyle(ChainProxyToggleStyle())
                .font(.app(size: T.FontSize.body, weight: .medium))
                .foregroundStyle(self.nativePrimaryLabel)
                .frame(height: T.rowHeight)
            VStack(alignment: .leading, spacing: T.space8) {
                self.nodeLibrary
                self.nodePicker(title: self.tr("ui.chain.front"), selection: self.$frontID, excluding: self.landingID)
                    .disabled(self.enabled)
                self.nodePicker(title: self.tr("ui.chain.landing"), selection: self.$landingID, excluding: self.frontID)
                    .disabled(self.enabled)
                if let front = self.node(for: self.frontID), let landing = self.node(for: self.landingID) {
                    Text(self.tr("ui.chain.path", front.name, landing.name))
                        .font(.app(size: T.FontSize.caption))
                        .foregroundStyle(self.nativeSecondaryLabel)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if self.appViewModel.chainProxySettingsLoadFailed {
                Text(self.tr("ui.chain.saved_load_failed"))
                    .font(.app(size: T.FontSize.caption))
                    .foregroundStyle(self.nativeCritical)
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.app(size: T.FontSize.caption))
                    .foregroundStyle(self.nativeCritical)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var nodeLibrary: some View {
        VStack(alignment: .leading, spacing: T.space6) {
            HStack {
                Text(self.tr("ui.chain.nodes"))
                    .font(.app(size: T.FontSize.body, weight: .semibold))
                    .foregroundStyle(self.nativePrimaryLabel)
                Spacer()
                Button { self.editorMode = .add } label: {
                    Label(self.tr("ui.chain.node_add"), systemImage: "plus")
                        .font(.app(size: T.FontSize.body, weight: .medium))
                        .padding(.horizontal, T.space8)
                        .padding(.vertical, T.space4)
                        .background(self.nativeControlFill, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!self.isLibraryReadable)
            }
            if self.nodes.isEmpty {
                Text(self.tr("ui.chain.no_nodes"))
                    .font(.app(size: T.FontSize.caption))
                    .foregroundStyle(self.nativeSecondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, T.space8)
            }
            ForEach(self.nodes) { node in
                HStack(spacing: T.space8) {
                    Text(node.name)
                        .font(.app(size: T.FontSize.body))
                        .foregroundStyle(self.nativePrimaryLabel)
                        .lineLimit(1)
                    Spacer()
                    Button { self.editorMode = .edit(node) } label: {
                        Image(systemName: "pencil")
                    }
                    .help(self.tr("ui.chain.node_edit"))
                    .disabled(self.nodeIsInUse(node))
                    Button(role: .destructive) { self.removeNode(node) } label: {
                        Image(systemName: "trash")
                    }
                    .help(self.tr("ui.action.delete"))
                    .disabled(self.nodeIsInUse(node))
                }
                .frame(minHeight: T.compactRowHeight)
                .buttonStyle(.borderless)
                .disabled(!self.isLibraryReadable)
            }
        }
        .padding(T.space8)
        .background(self.nativeControlFill, in: RoundedRectangle(cornerRadius: T.cornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: T.cornerRadius)
                .stroke(self.nativeControlBorder, lineWidth: T.stroke)
        }
    }

    private func node(for id: String) -> ChainProxyNode? {
        self.nodes.first(where: { $0.id == id })
    }

    private var enabled: Bool {
        self.appViewModel.chainProxySettings?.enabled ?? false
    }

    private func nodeIsInUse(_ node: ChainProxyNode) -> Bool {
        guard let settings = self.appViewModel.chainProxySettings, settings.enabled else { return false }
        return settings.front.id == node.id || settings.landing.id == node.id
    }

    private func nodePicker(title: String, selection: Binding<String>, excluding: String) -> some View {
        VStack(alignment: .leading, spacing: T.space4) {
            Text(title)
                .font(.app(size: T.FontSize.body, weight: .medium))
                .foregroundStyle(self.nativePrimaryLabel)
            Picker(title, selection: selection) {
                Text(self.tr("ui.chain.choose")).tag("")
                ForEach(self.nodes.filter { $0.id != excluding }) { node in
                    Text(node.name).tag(node.id)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.regular)
            .font(.app(size: T.FontSize.body))
            .foregroundStyle(self.nativePrimaryLabel)
            .frame(maxWidth: .infinity)
            .frame(height: T.rowHeight)
        }
    }

    private func load() {
        let settings = self.appViewModel.chainProxySettings
        do {
            self.nodes = try ChainProxyConfigService.readNodes(
                workingDirectory: self.appViewModel.workingDirectoryManager.rootDirectoryURL, settings: settings)
        } catch {
            self.nodes = settings.map { [$0.front, $0.landing] } ?? []
            self.isLibraryReadable = false
            self.errorMessage = self.tr("ui.chain.nodes_load_failed")
        }
        self.frontID = settings.flatMap { self.node(for: $0.front.id)?.id } ?? ""
        self.landingID = settings.flatMap { self.node(for: $0.landing.id)?.id } ?? ""
    }

    private func storeNode(_ node: ChainProxyNode) throws {
        var next = self.nodes
        if let index = next.firstIndex(where: { $0.id == node.id }) { next[index] = node } else { next.append(node) }
        try ChainProxyConfigService.writeNodes(
            next, workingDirectory: self.appViewModel.workingDirectoryManager.rootDirectoryURL)
        self.nodes = next
        if self.frontID.isEmpty { self.frontID = node.id }
        else if self.landingID.isEmpty, self.frontID != node.id { self.landingID = node.id }
        self.editorMode = nil
    }

    private func removeNode(_ node: ChainProxyNode) {
        do {
            let next = self.nodes.filter { $0.id != node.id }
            try ChainProxyConfigService.writeNodes(
                next, workingDirectory: self.appViewModel.workingDirectoryManager.rootDirectoryURL)
            self.nodes = next
            if self.frontID == node.id { self.frontID = "" }
            if self.landingID == node.id { self.landingID = "" }
        } catch {
            self.errorMessage = self.tr("ui.chain.nodes_save_failed")
        }
    }

    private func setEnabled(_ enabled: Bool) {
        guard !self.isApplying, !self.appViewModel.isChainProxySaving, enabled != self.enabled else { return }
        let settings = self.appViewModel.chainProxySettings
        let front = enabled ? self.node(for: self.frontID) : settings?.front
        let landing = enabled ? self.node(for: self.landingID) : settings?.landing
        guard let front, let landing, front.id != landing.id else {
            self.errorMessage = self.tr("ui.chain.invalid_selection")
            return
        }
        self.isApplying = true
        self.errorMessage = nil
        Task { @MainActor in
            defer { self.isApplying = false }
            do {
                try await self.appViewModel.saveChainProxySettings(enabled: enabled, front: front, landing: landing)
            } catch {
                self.errorMessage = self.tr("ui.chain.save_failed", self.appViewModel.coreErrorMessage(error))
            }
        }
    }
}

private struct ChainProxyToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: T.space8) {
                configuration.label
                Capsule()
                    .fill(configuration.isOn ? Color.blue : Color.secondary.opacity(0.4))
                    .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                        Circle()
                            .fill(.white)
                            .frame(width: 18, height: 18)
                            .padding(2)
                    }
                    .frame(width: 38, height: 22)
            }
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: T.AnimationDuration.quick), value: configuration.isOn)
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
                .toggleStyle(.switch)
        }
    }
}

private enum ChainProxyNodeInputMode: String, CaseIterable {
    case manual, link, yaml
}

private struct ChainProxyNodeEditorView: TranslatingView {
    @EnvironmentObject var appViewModel: AppViewModel
    let node: ChainProxyNode?
    let onSave: (ChainProxyNode) throws -> Void

    @State private var mode: ChainProxyNodeInputMode = .manual
    @State private var form = ChainProxyNodeForm()
    @State private var name = ""
    @State private var yaml = "type: socks5\nserver: ''\nport: 1080\n"
    @State private var link = ""
    @State private var isLinkParsed = false
    @State private var linkSummary = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: T.space8) {
            Picker("", selection: Binding(get: { self.mode }, set: self.changeMode)) {
                ForEach(self.node == nil ? ChainProxyNodeInputMode.allCases : [.manual, .yaml], id: \.self) { mode in
                    Text(self.tr("ui.chain.input.\(mode.rawValue)")).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            TextField(self.tr("ui.chain.node_name"), text: self.$name)
                .textFieldStyle(.roundedBorder)
            ScrollView {
                VStack(alignment: .leading, spacing: T.space8) {
                    switch self.mode {
                    case .manual:
                        self.manualForm
                    case .link:
                        self.linkInput
                    case .yaml:
                        Text(self.tr("ui.chain.node_config"))
                            .foregroundStyle(self.nativeSecondaryLabel)
                        TextEditor(text: self.$yaml)
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 250)
                            .overlay {
                                RoundedRectangle(cornerRadius: T.cornerRadius)
                                    .stroke(self.nativeControlBorder, lineWidth: T.stroke)
                            }
                    }
                    if let errorMessage {
                        Text(errorMessage)
                            .font(.app(size: T.FontSize.caption))
                            .foregroundStyle(self.nativeCritical)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .scrollIndicators(.hidden)
            Button(action: self.save) {
                Text(self.tr(self.node == nil ? "ui.chain.node_add" : "ui.action.save"))
                    .font(.app(size: T.FontSize.body, weight: .medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, T.space8)
            }
            .buttonStyle(ChainProxyPrimaryButtonStyle())
            .disabled(self.name.trimmedNonEmpty == nil || (self.mode == .link && !self.isLinkParsed))
        }
        .font(.app(size: T.FontSize.body))
        .padding(.horizontal, contentPadding)
        .padding(.bottom, contentPadding)
        .onAppear {
            guard let node = self.node else { return }
            self.name = node.name
            self.yaml = node.yaml
            if let form = try? ChainProxyNodeForm(yaml: node.yaml) {
                self.form = form
            } else {
                self.mode = .yaml
            }
        }
    }

    private var manualForm: some View {
        VStack(alignment: .leading, spacing: T.space8) {
            Picker(self.tr("ui.chain.protocol"), selection: self.$form.type) {
                Text("SOCKS5").tag("socks5")
                Text("HTTP").tag("http")
            }
            .pickerStyle(.menu)
            .disabled(self.node != nil)
            TextField(self.tr("ui.chain.server"), text: self.$form.server)
            TextField(self.tr("ui.chain.port"), text: self.$form.port)
            TextField(self.tr("ui.chain.username"), text: self.$form.username)
            SecureField(self.tr("ui.chain.password"), text: self.$form.password)
            Toggle(self.tr("ui.chain.tls"), isOn: self.$form.tls)
                .toggleStyle(.switch)
        }
        .textFieldStyle(.roundedBorder)
    }

    private var linkInput: some View {
        VStack(alignment: .leading, spacing: T.space8) {
            Text(self.tr("ui.chain.link_hint"))
                .font(.app(size: T.FontSize.caption))
                .foregroundStyle(self.nativeSecondaryLabel)
            TextEditor(text: self.$link)
                .scrollContentBackground(.hidden)
                .frame(height: 100)
                .overlay {
                    RoundedRectangle(cornerRadius: T.cornerRadius)
                        .stroke(self.nativeControlBorder, lineWidth: T.stroke)
                }
                .onChange(of: self.link) { _ in self.isLinkParsed = false }
            Button(self.tr("ui.chain.link_parse")) {
                do {
                    let node = try ChainProxyNodeLink.parse(self.link)
                    self.yaml = node.yaml
                    self.name = node.name
                    let proxy = try Yams.load(yaml: node.yaml) as? [String: Any] ?? [:]
                    self.linkSummary = "\(proxy["type"] ?? "") · \(proxy["server"] ?? ""):\(proxy["port"] ?? "")"
                    self.isLinkParsed = true
                    self.errorMessage = nil
                } catch {
                    self.isLinkParsed = false
                    self.errorMessage = self.tr("ui.chain.link_invalid")
                }
            }
            .appBorderedButtonStyle()
            if self.isLinkParsed {
                Text(self.linkSummary)
                    .font(.app(size: T.FontSize.callout))
                    .foregroundStyle(self.nativeSecondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func changeMode(_ mode: ChainProxyNodeInputMode) {
        do {
            if self.mode == .manual { self.yaml = try self.form.yaml(preserving: self.yaml) }
            if mode == .manual { self.form = try ChainProxyNodeForm(yaml: self.yaml) }
            if mode == .link { self.isLinkParsed = false }
            self.mode = mode
            self.errorMessage = nil
        } catch {
            self.errorMessage = self.appViewModel.coreErrorMessage(
                error as? ChainProxyConfigError ?? .invalidNodeConfig)
        }
    }

    private func save() {
        do {
            let yaml = self.mode == .manual ? try self.form.yaml(preserving: self.yaml) : self.yaml
            let node = try ChainProxyConfigService.makeNode(
                id: self.node?.id ?? UUID().uuidString, name: self.name, yaml: yaml)
            try self.onSave(node)
        } catch {
            if let error = error as? ChainProxyConfigError {
                self.errorMessage = self.appViewModel.coreErrorMessage(error)
            } else {
                self.errorMessage = self.tr("ui.chain.nodes_save_failed")
            }
        }
    }
}

private struct ChainProxyPrimaryButtonStyle: ButtonStyle {
    static let color = Color(red: 59 / 255, green: 130 / 255, blue: 246 / 255)

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white.opacity(self.isEnabled ? 1 : 0.6))
            .background(
                Self.color.opacity(self.isEnabled ? (configuration.isPressed ? 0.75 : self.isHovered ? 0.9 : 1) : 0.45),
                in: RoundedRectangle(cornerRadius: T.cornerRadius))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: T.AnimationDuration.quick), value: self.isHovered)
            .animation(.easeOut(duration: T.AnimationDuration.quick), value: configuration.isPressed)
            .onHover { self.isHovered = $0 }
    }
}
