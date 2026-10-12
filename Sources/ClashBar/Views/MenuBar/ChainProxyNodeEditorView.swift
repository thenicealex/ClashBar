import SwiftUI
import Yams

// swiftlint:disable:next type_name
private typealias T = MenuBarLayoutTokens

private enum ChainProxyNodeInputMode: String, CaseIterable {
    case manual, link, yaml
}

struct ChainProxyNodeEditorView: TranslatingView {
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
        .padding(.horizontal, T.space8)
        .padding(.bottom, T.space8)
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
                Menu {
                    Button("SOCKS5") { self.form.type = "socks5" }
                    Button("HTTP") { self.form.type = "http" }
                } label: {
                    HStack {
                        Text(self.form.type == "socks5" ? "SOCKS5" : "HTTP")
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down")
                    }
                    .frame(height: T.rowHeight)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .frame(maxWidth: .infinity)
                .background(self.nativeControlFill, in: Capsule())
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
