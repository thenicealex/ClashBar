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
        .disabled(self.isApplying || self.appViewModel.isLocalRuntimeChanging || self.appViewModel.isCoreActionProcessing)
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
            if self.appViewModel.currentChainProxyFront == nil {
                Text(self.tr("ui.chain.front_missing"))
                    .font(.app(size: T.FontSize.caption))
                    .foregroundStyle(self.nativeSecondaryLabel)
            }
            Toggle(self.tr("ui.chain.enabled"), isOn: Binding(
                get: { self.enabled }, set: self.setEnabled))
                .toggleStyle(ChainProxyToggleStyle(isActive: self.appViewModel.isChainProxyActive))
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
                HStack(spacing: T.space4) {
                    Button { self.landingID = node.id } label: {
                        HStack(spacing: T.space8) {
                            Image(systemName: "link")
                                .foregroundStyle(self.landingID == node.id ? Color.green : self.nativePurple)
                                .font(.app(size: T.FontSize.title3))
                            VStack(alignment: .leading, spacing: T.space4) {
                                Text(node.name)
                                    .font(.app(size: T.FontSize.callout, weight: .semibold))
                                    .foregroundStyle(self.nativePrimaryLabel)
                                Text(self.nodeSummary(node))
                                    .font(.app(size: T.FontSize.caption - 1))
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
        guard !self.isApplying, !self.appViewModel.isLocalRuntimeChanging, enabled != self.enabled else { return }
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
            .frame(width: 52, height: T.rowHeight, alignment: .trailing)
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
        .onChange(of: self.appViewModel.selectedConfigName) { _ in self.reset() }
        .onChange(of: self.appViewModel.currentChainProxyFront) { _ in self.reset() }
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
    let isActive: Bool
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: T.space8) {
                configuration.label
                Capsule()
                    .fill(configuration.isOn && self.isActive ? Color.blue : Color.secondary.opacity(0.4))
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

// Configure newly mounted scroll views as well as the initial popover content.
struct ChainProxyScrollStyle: NSViewRepresentable {
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
