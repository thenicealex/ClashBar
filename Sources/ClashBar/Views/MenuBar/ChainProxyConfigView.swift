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
    @State private var landingID = ""
    @State private var isApplying = false
    @State private var editorMode: ChainNodeEditorMode?
    @State private var isLibraryReadable = true
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            self.header
            if let mode = self.editorMode {
                ChainProxyNodeEditorView(node: mode.node, canSelectExit: !self.enabled, onSave: self.storeNode)
            } else {
                ScrollView {
                    self.form
                        .padding(.horizontal, contentPadding)
                        .padding(.bottom, contentPadding)
                        .padding(.trailing, T.space8)
                        .background(ChainProxyScrollStyle())
                }
                .scrollIndicators(.automatic)
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
            Divider().padding(.vertical, T.space8)
            self.nodeLibrary
            Divider().padding(.vertical, T.space8)
            Button { self.load() } label: {
                Label(self.tr("ui.chain.reload_nodes"), systemImage: "arrow.triangle.2.circlepath")
                    .font(.app(size: T.FontSize.body))
                    .foregroundStyle(self.nativePrimaryLabel)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: T.rowHeight)
            }
            .buttonStyle(.plain)
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
        VStack(alignment: .leading, spacing: T.space8) {
            HStack {
                Text(self.tr("ui.chain.nodes").uppercased())
                    .font(.app(size: T.FontSize.caption, weight: .medium))
                    .foregroundStyle(self.nativeSecondaryLabel)
                Spacer()
                Button { self.editorMode = .add } label: {
                    Label(self.tr("ui.chain.node_add"), systemImage: "plus")
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                .disabled(!self.isLibraryReadable)
            }
            if self.nodes.isEmpty {
                Text(self.tr("ui.chain.no_nodes"))
                    .font(.app(size: T.FontSize.caption))
                    .foregroundStyle(self.nativeSecondaryLabel)
                    .padding(.vertical, T.space8)
            }
            ForEach(self.nodes) { node in
                HStack(spacing: T.space8) {
                    Button { self.landingID = node.id } label: {
                        HStack(spacing: T.space8) {
                            Image(systemName: "link")
                                .foregroundStyle(self.landingID == node.id ? Color.green : self.nativePurple)
                                .font(.app(size: T.FontSize.title3))
                            VStack(alignment: .leading, spacing: T.space4) {
                                Text(node.name)
                                    .font(.app(size: T.FontSize.body, weight: .semibold))
                                    .foregroundStyle(self.nativePrimaryLabel)
                                Text(self.nodeSummary(node))
                                    .font(.app(size: T.FontSize.caption))
                                    .foregroundStyle(self.nativeSecondaryLabel)
                            }
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .contentShape(Rectangle())
                    }
                    .disabled(self.enabled)
                    .help(self.tr("ui.chain.landing"))
                    .accessibilityAddTraits(self.landingID == node.id ? .isSelected : [])
                    ChainProxyNodeLatencyView(node: node)
                    Button { self.editorMode = .edit(node) } label: {
                        Image(systemName: "pencil")
                            .frame(width: 24, height: T.rowHeight)
                    }
                    .help(self.tr("ui.chain.node_edit"))
                    .disabled(self.nodeIsInUse(node))
                    Button { self.removeNode(node) } label: {
                        Image(systemName: "trash")
                            .frame(width: 24, height: T.rowHeight)
                    }
                    .help(self.tr("ui.action.delete"))
                    .disabled(self.nodeIsInUse(node))
                }
                .buttonStyle(.plain)
                .padding(T.space8)
                .background(self.landingID == node.id ? Color.accentColor.opacity(0.3) : .clear,
                            in: RoundedRectangle(cornerRadius: T.cornerRadius))
                .disabled(!self.isLibraryReadable)
            }
        }
    }

    private func nodeSummary(_ node: ChainProxyNode) -> String {
        let proxy = (try? Yams.load(yaml: node.yaml)) as? [String: Any] ?? [:]
        return "\(String(describing: proxy["type"] ?? "").uppercased()) · \(proxy["server"] ?? ""):\(proxy["port"] ?? "")"
    }

    private func node(for id: String) -> ChainProxyNode? {
        self.nodes.first(where: { $0.id == id })
    }

    private var enabled: Bool {
        self.appViewModel.chainProxySettings?.enabled ?? false
    }

    private func nodeIsInUse(_ node: ChainProxyNode) -> Bool {
        guard let settings = self.appViewModel.chainProxySettings, settings.enabled else { return false }
        return settings.landing.id == node.id
    }

    private func load() {
        let settings = self.appViewModel.chainProxySettings
        self.isLibraryReadable = true
        self.errorMessage = nil
        let previousSelection = self.landingID
        do {
            self.nodes = try ChainProxyConfigService.readNodes(
                workingDirectory: self.appViewModel.workingDirectoryManager.rootDirectoryURL, settings: settings)
        } catch {
            self.nodes = settings.map { [$0.landing] } ?? []
            self.isLibraryReadable = false
            self.appViewModel.logChainProxyFailure(operation: "log.chain.load_nodes", error: error)
            self.errorMessage = self.tr("ui.chain.nodes_load_failed")
        }
        for node in self.nodes { self.appViewModel.chainProxyLogRedactor.include(yaml: node.yaml) }
        self.landingID = settings.flatMap { self.node(for: $0.landing.id)?.id }
            ?? self.node(for: previousSelection)?.id ?? ""
    }

    private func storeNode(_ node: ChainProxyNode, selectExit: Bool) throws {
        self.appViewModel.chainProxyLogRedactor.include(yaml: node.yaml)
        var next = self.nodes
        if let index = next.firstIndex(where: { $0.id == node.id }) { next[index] = node } else { next.append(node) }
        try ChainProxyConfigService.writeNodes(
            next, workingDirectory: self.appViewModel.workingDirectoryManager.rootDirectoryURL)
        self.nodes = next
        if selectExit || self.landingID.isEmpty { self.landingID = node.id }
        self.editorMode = nil
    }

    private func removeNode(_ node: ChainProxyNode) {
        do {
            let next = self.nodes.filter { $0.id != node.id }
            try ChainProxyConfigService.writeNodes(
                next, workingDirectory: self.appViewModel.workingDirectoryManager.rootDirectoryURL)
            self.nodes = next
            if self.landingID == node.id { self.landingID = "" }
        } catch {
            self.appViewModel.logChainProxyFailure(operation: "log.chain.save_nodes", error: error)
            self.errorMessage = self.tr("ui.chain.nodes_save_failed")
        }
    }

    private func setEnabled(_ enabled: Bool) {
        guard !self.isApplying, !self.appViewModel.isChainProxySaving, enabled != self.enabled else { return }
        let settings = self.appViewModel.chainProxySettings
        let landing = enabled ? self.node(for: self.landingID) : settings?.landing
        guard let landing else {
            self.appViewModel.logChainProxyFailure(
                operation: "log.chain.enable", error: ChainProxyConfigError.invalidSelection)
            self.errorMessage = self.tr("ui.chain.invalid_selection")
            return
        }
        self.isApplying = true
        self.errorMessage = nil
        Task { @MainActor in
            defer { self.isApplying = false }
            do {
                try await self.appViewModel.saveChainProxySettings(enabled: enabled, landing: landing)
            } catch {
                self.errorMessage = self.tr("ui.chain.save_failed", self.appViewModel.coreErrorMessage(error))
            }
        }
    }
}

private struct ChainProxyNodeLatencyView: TranslatingView {
    @EnvironmentObject var appViewModel: AppViewModel
    let node: ChainProxyNode

    @State private var samples: [Int] = []
    @State private var isHovered = false
    @State private var isTesting = false
    @State private var testTask: Task<Void, Never>?
    @State private var failureMessage: String?

    var body: some View {
        Button(action: self.testLatency) {
            Group {
                if self.isTesting {
                    ProgressView().controlSize(.mini)
                } else if self.isHovered || self.samples.isEmpty {
                    Image(systemName: "gauge.with.dots.needle.50percent")
                        .foregroundStyle(self.samples.last == 0 ? self.nativeCritical : self.nativeSecondaryLabel)
                } else {
                    self.delayBadge(samples: self.samples, fallbackText: self.tr("ui.common.timeout"), showsHistory: true)
                }
            }
            .frame(width: 52, height: T.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(self.isTesting)
        .help(self.failureMessage ?? self.tr("ui.action.test_latency"))
        .accessibilityLabel(self.tr("ui.action.test_latency"))
        .accessibilityValue(self.samples.last.map {
            $0 == 0 ? self.tr("ui.common.timeout") : self.tr("ui.common.latency_ms", $0)
        } ?? "")
        .onHover { self.isHovered = $0 }
        .onChange(of: self.node) { _ in self.reset() }
        .onDisappear { self.reset() }
    }

    private func reset() {
        self.testTask?.cancel()
        self.testTask = nil
        self.isTesting = false
        self.samples = []
        self.failureMessage = nil
    }

    private func testLatency() {
        guard !self.isTesting else { return }
        self.isTesting = true
        self.failureMessage = nil
        let node = self.node
        self.testTask = Task { @MainActor in
            var delay = 0
            do {
                delay = try await self.appViewModel.measureChainProxyLatency(node: node)
            } catch {
                if !Task.isCancelled {
                    self.appViewModel.logChainProxyFailure(operation: "log.chain.latency", error: error)
                    self.failureMessage = self.appViewModel.coreErrorMessage(error)
                }
            }
            guard !Task.isCancelled else { return }
            self.samples = Array((self.samples + [delay]).suffix(ProxyDelayHistory.limit))
            self.isTesting = false
            self.testTask = nil
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
    let canSelectExit: Bool
    let onSave: (ChainProxyNode, Bool) throws -> Void

    @State private var mode: ChainProxyNodeInputMode = .manual
    @State private var form = ChainProxyNodeForm()
    @State private var name = ""
    @State private var yaml = "type: socks5\nserver: ''\nport: 1080\n"
    @State private var link = ""
    @State private var parsedNode: ChainProxyNode?
    @State private var showsPreview = true
    @State private var selectExit = false
    @State private var errorMessage: String?

    private var resolvedName: String {
        let proxy = (try? Yams.load(yaml: self.yaml)) as? [String: Any]
        if self.mode == .yaml, let yamlName = (proxy?["name"] as? String)?.trimmedNonEmpty {
            return yamlName
        }
        return self.name.trimmedNonEmpty ?? ""
    }

    private var canSave: Bool {
        switch self.mode {
        case .manual:
            return self.name.trimmedNonEmpty != nil && self.form.server.trimmedNonEmpty != nil
                && Int(self.form.port).map { (1...65535).contains($0) } == true
        case .link, .yaml:
            return self.parsedNode != nil
        }
    }

    var body: some View {
        VStack(spacing: T.space8) {
            HStack(spacing: T.space4) {
                ForEach(self.node == nil ? ChainProxyNodeInputMode.allCases : [.manual, .yaml], id: \.self) { mode in
                    Button { self.changeMode(mode) } label: {
                        Text(self.tr("ui.chain.input.\(mode.rawValue)"))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, T.space8)
                            .foregroundStyle(self.mode == mode ? self.nativePrimaryLabel : self.nativeSecondaryLabel)
                            .background(self.mode == mode ? self.nativeControlFill : .clear, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if self.mode != .yaml {
                        self.field("ui.chain.node_name", hint: self.mode == .manual ? "ui.chain.required" : "ui.chain.optional") {
                            TextField(self.tr(self.mode == .manual ? "ui.chain.name_placeholder" : "ui.chain.name_detected"),
                                      text: self.$name)
                        }
                    }
                    switch self.mode {
                    case .manual: self.manualForm
                    case .link: self.linkInput
                    case .yaml: self.yamlInput
                    }
                    if self.mode != .manual, let parsedNode {
                        self.preview(parsedNode)
                    }
                    if self.node == nil, self.canSelectExit, self.canSave {
                        Toggle(self.tr("ui.chain.select_exit"), isOn: self.$selectExit)
                            .toggleStyle(.checkbox)
                        self.caption("ui.chain.select_exit_hint")
                    }
                    if let errorMessage {
                        Text(errorMessage)
                            .font(.app(size: T.FontSize.caption))
                            .foregroundStyle(self.nativeCritical)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, T.space8)
                .padding(.trailing, T.space8)
                .background(ChainProxyScrollStyle())
            }
            .scrollIndicators(.automatic)
            Divider()
            HStack(spacing: T.space8) {
                if self.mode == .manual {
                    Button(self.tr("ui.chain.reset"), action: self.reset)
                        .buttonStyle(.plain)
                        .frame(width: 90, height: T.rowHeight)
                        .overlay(Capsule().stroke(self.nativeControlBorder, lineWidth: 1))
                }
                Button(action: self.save) {
                    Label(self.tr(self.node == nil ? "ui.chain.node_add" : "ui.action.save"),
                          systemImage: self.node == nil ? "plus" : "checkmark")
                        .frame(maxWidth: .infinity)
                        .frame(height: T.rowHeight)
                }
                .buttonStyle(ChainProxyPrimaryButtonStyle())
                .disabled(!self.canSave)
            }
        }
        .font(.app(size: T.FontSize.body))
        .padding(.horizontal, contentPadding)
        .padding(.bottom, contentPadding)
        .onAppear { self.reset() }
    }

    private func caption(_ key: String) -> some View {
        Text(self.tr(key))
            .font(.app(size: T.FontSize.caption))
            .foregroundStyle(self.nativeSecondaryLabel)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func section(_ key: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Divider()
            Text(self.tr(key).uppercased())
                .font(.app(size: T.FontSize.caption, weight: .medium))
                .foregroundStyle(self.nativeSecondaryLabel)
        }
    }

    private func field<Content: View>(_ key: String, hint: String? = nil,
                                      @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: T.space4) {
            HStack(spacing: T.space4) {
                Text(self.tr(key))
                if let hint { self.caption(hint) }
            }
            content()
                .textFieldStyle(.plain)
                .padding(.horizontal, 10)
                .frame(height: T.rowHeight)
                .overlay(Capsule().stroke(self.nativeControlBorder, lineWidth: 1))
        }
    }

    private var manualForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            self.section("ui.chain.connection")
            self.field("ui.chain.protocol") {
                Picker(self.tr("ui.chain.protocol"), selection: self.$form.type) {
                    Text("SOCKS5").tag("socks5")
                    Text("HTTP").tag("http")
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity)
                .disabled(self.node != nil)
            }
            HStack(alignment: .top, spacing: T.space8) {
                self.field("ui.chain.server") { TextField("proxy.example.com", text: self.$form.server) }
                self.field("ui.chain.port") { TextField("1080", text: self.$form.port) }
                    .frame(width: 90)
            }
            self.section("ui.chain.authentication")
            self.field("ui.chain.username") { TextField("", text: self.$form.username) }
            self.field("ui.chain.password") { SecureField("", text: self.$form.password) }
            self.section("ui.chain.security")
            Toggle(isOn: self.$form.tls) {
                VStack(alignment: .leading, spacing: T.space4) {
                    Text(self.tr("ui.chain.tls")).fontWeight(.semibold)
                    self.caption("ui.chain.tls_hint")
                }
            }
            .toggleStyle(.checkbox)
        }
    }

    private var linkInput: some View {
        VStack(alignment: .leading, spacing: T.space8) {
            HStack {
                Text(self.tr("ui.chain.input.link"))
                Spacer()
                self.exampleButton {
                    self.link = "socks5://demo:example-password@sg.example.com:1080#Singapore%20Proxy"
                }
            }
            self.textArea(self.$link, height: 80)
                .onChange(of: self.link) { _ in self.invalidate() }
            HStack {
                self.caption("ui.chain.link_protocols")
                Spacer()
                Button(self.tr("ui.chain.clear")) { self.link = "" }
                    .buttonStyle(.plain)
            }
            Button(action: self.parseLink) {
                Label(self.tr("ui.chain.link_parse"), systemImage: "viewfinder")
                    .frame(maxWidth: .infinity)
                    .frame(height: T.rowHeight)
                    .overlay(Capsule().stroke(self.nativeControlBorder, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .disabled(self.link.trimmedNonEmpty == nil)
        }
    }

    private var yamlInput: some View {
        VStack(alignment: .leading, spacing: T.space8) {
            HStack {
                Text(self.tr("ui.chain.node_config"))
                Spacer()
                self.exampleButton {
                    self.yaml = "name: Singapore Proxy\ntype: socks5\nserver: sg.example.com\nport: 1080\nusername: demo\npassword: example-password\nudp: true\n"
                    self.name = ""
                }
            }
            VStack(spacing: T.space8) {
                HStack {
                    Label("node.yaml", systemImage: "doc.badge.gearshape")
                    Spacer()
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(self.yaml, forType: .string)
                    } label: { Image(systemName: "doc.on.doc") }
                    .help(self.tr("ui.chain.copy"))
                    Button { self.yaml = "" } label: { Image(systemName: "trash") }
                        .help(self.tr("ui.chain.clear"))
                }
                .buttonStyle(.plain)
                self.textArea(self.$yaml, height: 170)
                    .font(.system(size: T.FontSize.callout, design: .monospaced))
                    .onChange(of: self.yaml) { _ in self.invalidate() }
                HStack {
                    if self.parsedNode != nil {
                        Label(self.tr("ui.chain.valid"), systemImage: "checkmark.circle")
                            .foregroundStyle(.green)
                    } else {
                        self.caption("ui.chain.not_validated")
                    }
                    Spacer()
                    Text(self.tr("ui.chain.yaml_stats", self.yaml.components(separatedBy: "\n").count, self.yaml.count))
                        .foregroundStyle(self.nativeSecondaryLabel)
                }
                .font(.app(size: T.FontSize.caption))
            }
            .padding(T.space8)
            .background(self.nativeControlFill, in: RoundedRectangle(cornerRadius: T.cornerRadius))
            Button(action: self.validateYAML) {
                Label(self.tr("ui.chain.yaml_validate"), systemImage: "checkmark")
                    .frame(maxWidth: .infinity)
                    .frame(height: T.rowHeight)
                    .overlay(Capsule().stroke(self.nativeControlBorder, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .disabled(self.yaml.trimmedNonEmpty == nil)
        }
    }

    private func textArea(_ text: Binding<String>, height: CGFloat) -> some View {
        TextEditor(text: text)
            .scrollContentBackground(.hidden)
            .scrollIndicators(.automatic)
            .background(ChainProxyScrollStyle(isTextEditor: true))
            .padding(T.space6)
            .frame(height: height)
            .overlay(RoundedRectangle(cornerRadius: T.cornerRadius)
                .stroke(self.nativeControlBorder, lineWidth: 1))
    }

    private func exampleButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(self.tr("ui.chain.use_example"), systemImage: "doc.badge.gearshape")
                .font(.app(size: T.FontSize.caption))
        }
        .buttonStyle(.plain)
    }

    private func preview(_ node: ChainProxyNode) -> some View {
        let proxy = (try? Yams.load(yaml: node.yaml)) as? [String: Any] ?? [:]
        return VStack(alignment: .leading, spacing: T.space8) {
            Divider()
            Button { self.showsPreview.toggle() } label: {
                HStack {
                    Label(self.tr("ui.chain.node_preview"), systemImage: "checkmark.circle")
                    Spacer()
                    Image(systemName: self.showsPreview ? "chevron.up" : "chevron.down")
                }
                .font(.app(size: T.FontSize.caption))
            }
            .buttonStyle(.plain)
            if self.showsPreview {
                VStack(alignment: .leading, spacing: T.space8) {
                    Label(self.mode == .link ? self.name.trimmedNonEmpty ?? node.name : node.name,
                          systemImage: "server.rack")
                        .font(.app(size: T.FontSize.body, weight: .semibold))
                    Text(verbatim: "\(String(describing: proxy["type"] ?? "").uppercased()) · \(proxy["server"] ?? ""):\(proxy["port"] ?? "")")
                        .textSelection(.enabled)
                    Divider()
                    HStack {
                        self.caption("ui.chain.authentication")
                        Spacer()
                        Text(self.tr(proxy["username"] != nil || proxy["password"] != nil
                                     ? "ui.chain.configured" : "ui.chain.none"))
                    }
                    HStack {
                        Text("UDP")
                        Spacer()
                        Text(self.tr(proxy["udp"] as? Bool == true ? "ui.chain.active" : "ui.chain.disabled"))
                    }
                }
                .font(.app(size: T.FontSize.caption))
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(self.nativeControlFill, in: RoundedRectangle(cornerRadius: T.cornerRadius))
            }
        }
    }

    private func invalidate() {
        self.parsedNode = nil
        self.errorMessage = nil
    }

    private func parseLink() {
        do {
            let node = try ChainProxyNodeLink.parse(self.link)
            self.yaml = node.yaml
            self.parsedNode = node
            self.errorMessage = nil
        } catch {
            self.parsedNode = nil
            self.errorMessage = self.tr("ui.chain.link_invalid")
        }
    }

    private func validateYAML() {
        do {
            let node = try ChainProxyConfigService.makeNode(name: self.resolvedName, yaml: self.yaml)
            self.parsedNode = node
            self.errorMessage = nil
        } catch {
            self.parsedNode = nil
            self.errorMessage = self.tr("ui.chain.node_invalid")
        }
    }

    private func reset() {
        self.form = ChainProxyNodeForm()
        self.name = self.node?.name ?? ""
        self.yaml = self.node?.yaml ?? "type: socks5\nserver: ''\nport: 1080\n"
        self.link = ""
        self.selectExit = false
        self.invalidate()
        if let node = self.node {
            if let form = try? ChainProxyNodeForm(yaml: node.yaml) {
                self.form = form
            } else {
                self.mode = .yaml
                self.validateYAML()
            }
        }
    }

    private func changeMode(_ mode: ChainProxyNodeInputMode) {
        guard mode != self.mode else { return }
        do {
            if self.mode == .manual { self.yaml = try self.form.yaml(preserving: self.yaml) }
            if self.mode == .yaml { self.name = self.resolvedName }
            if mode == .manual { self.form = try ChainProxyNodeForm(yaml: self.yaml) }
            self.mode = mode
            self.invalidate()
        } catch {
            self.errorMessage = self.appViewModel.coreErrorMessage(
                error as? ChainProxyConfigError ?? .invalidNodeConfig)
        }
    }

    private func save() {
        guard self.canSave else { return }
        do {
            let yaml = self.mode == .manual ? try self.form.yaml(preserving: self.yaml) : self.yaml
            let name = self.mode == .link ? self.name.trimmedNonEmpty ?? self.parsedNode?.name ?? "" : self.resolvedName
            let node = try ChainProxyConfigService.makeNode(
                id: self.node?.id ?? UUID().uuidString, name: name, yaml: yaml)
            try self.onSave(node, self.canSelectExit && self.selectExit)
        } catch {
            self.appViewModel.chainProxyLogRedactor.include(yaml: self.yaml)
            self.appViewModel.logChainProxyFailure(operation: "log.chain.save_nodes", error: error)
            if let error = error as? ChainProxyConfigError {
                self.errorMessage = self.appViewModel.coreErrorMessage(error)
            } else {
                self.errorMessage = self.tr("ui.chain.nodes_save_failed")
            }
        }
    }
}

private struct ChainProxyPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(self.isEnabled ? Color(nsColor: .controlBackgroundColor) : .secondary)
            .background(self.isEnabled ? Color.primary.opacity(configuration.isPressed ? 0.75 : 1)
                        : Color.secondary.opacity(0.15), in: Capsule())
    }
}

// Configure newly mounted scroll views as well as the initial popover content.
private struct ChainProxyScrollStyle: NSViewRepresentable {
    var isTextEditor = false

    func makeNSView(context: Context) -> ScrollStyleView {
        let view = ScrollStyleView()
        view.isTextEditor = self.isTextEditor
        return view
    }

    func updateNSView(_ nsView: ScrollStyleView, context: Context) {
        nsView.isTextEditor = self.isTextEditor
        nsView.scheduleConfiguration()
    }

    final class ScrollStyleView: NSView {
        var isTextEditor = false

        private var targetScrollView: NSScrollView? {
            guard self.isTextEditor else { return self.enclosingScrollView }
            // A TextEditor's background is beside its scroll view, not inside it.
            var ancestor = self.superview
            while let container = ancestor {
                var stack = container.subviews
                while let view = stack.popLast() {
                    if let scrollView = view as? NSScrollView, scrollView.documentView is NSTextView {
                        return scrollView
                    }
                    stack.append(contentsOf: view.subviews)
                }
                ancestor = container.superview
            }
            return nil
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            self.scheduleConfiguration()
        }

        func scheduleConfiguration() {
            DispatchQueue.main.async { [weak self] in
                guard let scrollView = self?.targetScrollView else { return }
                scrollView.scrollerStyle = .overlay
                scrollView.autohidesScrollers = true
                scrollView.hasVerticalScroller = true
                scrollView.hasHorizontalScroller = false
                scrollView.verticalScroller?.controlSize = .small
            }
        }
    }
}
