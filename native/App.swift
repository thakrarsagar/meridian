import AppKit
import Network

enum Style {
    static let width: CGFloat = 368
    static let height: CGFloat = 576
    static let inset: CGFloat = 20
    static let rowHeight: CGFloat = 44
    static let accent = NSColor.controlAccentColor
    static func label(_ text: String, size: CGFloat = 13, weight: NSFont.Weight = .regular,
                      color: NSColor = .labelColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        return field
    }
    static func icon(_ symbol: String, help: String, target: AnyObject, action: Selector) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: help)!, target: target, action: action)
        button.isBordered = false
        button.toolTip = help
        button.setAccessibilityLabel(help)
        return button
    }
    static func stack(_ views: [NSView], orientation: NSUserInterfaceLayoutOrientation = .vertical, spacing: CGFloat = 12) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = orientation
        stack.alignment = orientation == .vertical ? .leading : .centerY
        stack.spacing = spacing
        return stack
    }
}

final class AppModel {
    let core = Core()
    let http = SmallHTTP()
    let vpn = NativeVPN()
    var changed: (() -> Void)?
    var needsCredentials: (() -> Void)?
    private(set) var fetching = false
    private(set) var notice: String?
    private var recommendation: URLSessionDataTask?
    private var nativeGeneration: UInt64 = 0
    private var retry: DispatchWorkItem?
    private var retryDelay: Double = 3
    private var loaded = false
    private var cache: Cache?
    private let monitor = NWPathMonitor()
    private var online = true
    private var sleeping = false
    private struct Cache: Codable { let data: Data; let modified: String?; let checked: Date }
    private var cacheURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier!, isDirectory: true).appendingPathComponent("locations.json")
    }
    var state: ConnectionState { core.state }

    init() {
        vpn.statusChanged = { [weak self] status in
            guard let self else { return }
            let result = self.core.call(["op": "status", "generation": self.nativeGeneration, "status": status])
            if status == 3 { self.retryDelay = 3; self.retry?.cancel(); self.retry = nil }
            self.effects(result)
            self.changed?()
        }
        // Reading this app's saved UUID does not save, start, or stop a configuration.
        vpn.observe()
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                guard let self else { return }
                self.online = path.status == .satisfied
                if self.online { self.resumeAfterEvent() }
            }
        }
        monitor.start(queue: DispatchQueue(label: "Meridian.path", qos: .utility))
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.sleeping = true; self?.retry?.cancel(); self?.retry = nil
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.sleeping = false; self?.resumeAfterEvent()
        }
    }

    func firstOpen() {
        guard !loaded else { return }
        loaded = true
        if let data = try? Data(contentsOf: cacheURL), data.count < 800_000,
           let saved = try? JSONDecoder().decode(Cache.self, from: data), acceptCatalogue(saved.data) {
            cache = saved
            changed?()
        } else { refreshCatalogue() }
    }

    @discardableResult private func acceptCatalogue(_ data: Data) -> Bool {
        guard let payload = try? JSONSerialization.jsonObject(with: data) else { return false }
        return core.call(["op": "catalogue", "payload": payload])["ok"] as? Bool == true
    }

    func refreshCatalogue() {
        guard !fetching else { return }
        fetching = true; notice = nil; changed?()
        let url = URL(string: core.call(["op": "snapshot"])["catalogue_url"] as! String)!
        http.fetch(url, modified: cache?.modified) { [weak self] result in
            guard let self else { return }
            self.fetching = false
            do {
                let response = try result.get()
                let body: Data
                if response.status == 304, let cached = self.cache { body = cached.data }
                else if response.status == 200 { body = response.data }
                else { throw Credentials.error("The location cache is unavailable. Refresh again.") }
                guard self.acceptCatalogue(body) else { throw Credentials.error("Nord returned an invalid location list. The previous list is still available.") }
                let saved = Cache(data: body, modified: response.modified ?? self.cache?.modified, checked: Date())
                self.cache = saved
                do {
                    try FileManager.default.createDirectory(at: self.cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try JSONEncoder().encode(saved).write(to: self.cacheURL, options: .atomic)
                } catch { self.notice = "Locations loaded. The disk cache could not be saved." }
            } catch { self.notice = "Locations could not refresh. \(error.localizedDescription)" }
            self.changed?()
        }
    }

    func connect(_ location: Location) {
        do {
            guard try Credentials.load() != nil else { needsCredentials?(); return }
        } catch { notice = error.localizedDescription; changed?(); needsCredentials?(); return }
        guard vpn.available else { notice = "Native VPN controls are unavailable on this macOS version."; changed?(); return }
        recommendation?.cancel(); retry?.cancel(); retry = nil; notice = nil
        var command: [String: Any] = ["op": "connect", "country_id": location.country_id]
        if let city = location.city_id { command["city_id"] = city }
        let response = core.call(command)
        guard response["ok"] as? Bool == true, let url = response["url"] as? String else {
            notice = response["error"] as? String; changed?(); return
        }
        let generation = state.generation
        changed?()
        recommendation = http.fetch(URL(string: url)!, limit: 65_536) { [weak self] result in
            guard let self, self.state.generation == generation else { return }
            self.recommendation = nil
            do {
                let response = try result.get()
                let payload = try JSONSerialization.jsonObject(with: response.data)
                let reply = self.core.call(["op": "recommendation", "generation": generation, "payload": payload])
                guard reply["ok"] as? Bool == true else { throw Credentials.error(reply["error"] as? String ?? "Nord could not choose a server.") }
                self.effects(reply)
            } catch { self.fail(error.localizedDescription, generation: generation) }
            self.changed?()
        }
    }

    func disconnect() {
        recommendation?.cancel(); recommendation = nil; retry?.cancel(); retry = nil; notice = nil
        effects(core.call(["op": "disconnect"]))
        changed?()
    }

    private func effects(_ response: [String: Any]) {
        guard response["ignored"] as? Bool != true else { return }
        let generation = state.generation
        switch response["effect"] as? String {
        case "connect":
            nativeGeneration = generation
            do {
                guard let credentials = try Credentials.prepareForConnection(), let host = state.hostname else {
                    throw Credentials.error("Save your Nord service credentials in Settings before connecting.")
                }
                vpn.connect(host: host, username: credentials.username, passwordReference: credentials.reference) { [weak self] error in
                    guard let self, self.state.generation == generation else { return }
                    if let error { self.fail(error.localizedDescription, generation: generation) }
                    self.changed?()
                }
            } catch { fail(error.localizedDescription, generation: generation) }
        case "disconnect":
            nativeGeneration = generation
            vpn.disconnect { [weak self] error in
                guard let self, self.state.generation == generation else { return }
                if let error { self.fail(error.localizedDescription, generation: generation) }
                else { self.effects(self.core.call(["op": "status", "generation": generation, "status": 1])) }
                self.changed?()
            }
        case "resume_later": scheduleResume()
        default: break
        }
    }
    private func fail(_ message: String, generation: UInt64) {
        effects(core.call(["op": "failure", "generation": generation, "message": message]))
        changed?()
    }
    private func scheduleResume() {
        guard retry == nil, online, !sleeping, state.wanted else { return }
        let generation = state.generation
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.retry = nil
            guard self.state.generation == generation, self.online, !self.sleeping else { return }
            self.effects(self.core.call(["op": "resume"]))
            self.changed?()
        }
        retry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + retryDelay, execute: work)
        retryDelay = min(retryDelay * 2, 60)
    }
    private func resumeAfterEvent() {
        if state.phase == "reconnecting" { scheduleResume() }
    }
}

final class LocationCell: NSTableCellView {
    let flag = Style.label("", size: 22)
    let title = Style.label("", weight: .medium)
    let detail = Style.label("", size: 11, color: .secondaryLabelColor)
    override init(frame: NSRect) {
        super.init(frame: frame)
        let labels = Style.stack([title, detail], spacing: 2)
        let row = Style.stack([flag, labels], orientation: .horizontal, spacing: 12)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            row.centerYAnchor.constraint(equalTo: centerYAnchor), flag.widthAnchor.constraint(equalToConstant: 28)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    func set(_ location: Location, isChild: Bool) {
        flag.stringValue = location.flag
        title.stringValue = isChild && location.city == nil ? "Any city" : location.city ?? location.country
        detail.stringValue = isChild && location.city == nil ? "Recommended server" : location.subtitle
        setAccessibilityLabel("\(title.stringValue), \(detail.stringValue)")
    }
}

// NSOutlineView needs stable object identities for its country and city items.
final class LocationItem: NSObject {
    let location: Location
    let children: [LocationItem]
    init(_ location: Location, children: [LocationItem] = []) {
        self.location = location; self.children = children
    }
    static func countries(from all: [Location], matching matches: [Location]) -> [LocationItem] {
        let ids = Set(matches.map(\.country_id))
        let cities = Dictionary(grouping: matches.filter { $0.city_id != nil }, by: \.country_id)
        return all.filter { $0.city_id == nil && ids.contains($0.country_id) }.map { country in
            let choices = cities[country.country_id] ?? []
            return LocationItem(country, children: choices.isEmpty ? [] : [LocationItem(country)] + choices.map { LocationItem($0) })
        }
    }
}

final class PopoverController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSSearchFieldDelegate {
    let model: AppModel
    var showSettings: (() -> Void)?
    let search = NSSearchField()
    private let table = NSOutlineView()
    private let headline = Style.label("Disconnected", size: 23, weight: .semibold)
    private let statusIcon = NSImageView()
    private let detail = Style.label("Your regular connection is in use.", size: 12, color: .secondaryLabelColor)
    private let locationLabel = Style.label("Choose a location to connect", size: 12, color: .secondaryLabelColor)
    private let connect = NSButton(title: "Connect", target: nil, action: nil)
    private let stop = NSButton(title: "Disconnect", target: nil, action: nil)
    private let summary = Style.label("Loading locations", size: 11, color: .secondaryLabelColor)
    private let empty = Style.label("Loading locations…", size: 13, color: .secondaryLabelColor)
    private let refresh = NSButton()
    private var countries: [LocationItem] = []
    private var expandedCountries: Set<Int> = []
    private var previousQuery = ""
    private var selected: Location?
    private var rendering = false

    init(model: AppModel) { self.model = model; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError() }
    override func loadView() {
        let root = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: Style.width, height: Style.height))
        root.material = .popover; root.blendingMode = .behindWindow
        view = root
        let brand = Style.stack([Style.label("Meridian", size: 15, weight: .semibold), Style.label("Native IKEv2", size: 11, color: .secondaryLabelColor)], spacing: 2)
        let settings = Style.icon("gearshape", help: "Settings", target: self, action: #selector(settingsPressed))
        let header = Style.stack([brand, NSView(), settings], orientation: .horizontal)
        statusIcon.image = NSImage(systemSymbolName: "power.circle", accessibilityDescription: "Disconnected")
        statusIcon.contentTintColor = .secondaryLabelColor
        statusIcon.symbolConfiguration = .init(pointSize: 23, weight: .regular)
        let statusRow = Style.stack([statusIcon, headline], orientation: .horizontal, spacing: 9)
        detail.maximumNumberOfLines = 3; detail.lineBreakMode = .byWordWrapping
        detail.preferredMaxLayoutWidth = Style.width - 2 * Style.inset
        locationLabel.lineBreakMode = .byTruncatingTail
        connect.target = self; connect.action = #selector(connectPressed)
        connect.bezelStyle = .rounded; connect.controlSize = .large
        connect.bezelColor = Style.accent
        connect.keyEquivalent = "\r"
        stop.target = self; stop.action = #selector(disconnectPressed); stop.bezelStyle = .rounded
        stop.controlSize = .large
        let actions = Style.stack([connect, stop], orientation: .horizontal, spacing: 8)
        let status = Style.stack([statusRow, detail, locationLabel, actions], spacing: 10)
        search.placeholderString = "Search countries and cities"
        search.controlSize = .large; search.delegate = self
        search.sendsSearchStringImmediately = true
        search.setAccessibilityLabel("Search countries and cities")
        let separator = NSBox(); separator.boxType = .separator
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("location"))
        table.addTableColumn(column); table.headerView = nil; table.rowHeight = Style.rowHeight
        table.outlineTableColumn = column
        table.indentationPerLevel = 16
        table.intercellSpacing = NSSize(width: 0, height: 2); table.backgroundColor = .clear
        table.style = .plain; table.selectionHighlightStyle = .regular
        table.dataSource = self; table.delegate = self
        table.target = self; table.doubleAction = #selector(connectPressed)
        table.setAccessibilityLabel("Nord IKEv2 locations")
        let scroll = NSScrollView(); scroll.documentView = table
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.drawsBackground = false; scroll.borderType = .noBorder
        let list = NSView(); list.addSubview(scroll); list.addSubview(empty)
        scroll.translatesAutoresizingMaskIntoConstraints = false; empty.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: list.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: list.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: list.topAnchor), scroll.bottomAnchor.constraint(equalTo: list.bottomAnchor),
            empty.centerXAnchor.constraint(equalTo: list.centerXAnchor), empty.centerYAnchor.constraint(equalTo: list.centerYAnchor)
        ])
        let refreshButton = Style.icon("arrow.clockwise", help: "Refresh locations", target: self, action: #selector(refreshPressed))
        refresh.title = ""; refresh.image = refreshButton.image; refresh.isBordered = false
        refresh.target = self; refresh.action = #selector(refreshPressed); refresh.toolTip = "Refresh locations"
        refresh.setAccessibilityLabel("Refresh locations")
        let quit = Style.icon("power", help: "Quit Meridian", target: self, action: #selector(quitPressed))
        let footer = Style.stack([summary, NSView(), refresh, quit], orientation: .horizontal, spacing: 12)
        let layout = Style.stack([header, status, separator, search, list, footer], spacing: 16)
        layout.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(layout)
        for child in [header, status, separator, search, list, footer] {
            child.translatesAutoresizingMaskIntoConstraints = false
            child.widthAnchor.constraint(equalTo: layout.widthAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            layout.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Style.inset),
            layout.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Style.inset),
            layout.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            layout.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
            actions.widthAnchor.constraint(equalTo: status.widthAnchor), connect.widthAnchor.constraint(greaterThanOrEqualToConstant: 164),
            detail.widthAnchor.constraint(equalTo: status.widthAnchor), locationLabel.widthAnchor.constraint(equalTo: status.widthAnchor),
            list.heightAnchor.constraint(greaterThanOrEqualToConstant: 170)
        ])
        model.changed = { [weak self] in self?.render() }
        render()
    }
    override func viewWillAppear() { super.viewWillAppear(); model.firstOpen(); render() }
    override func viewDidAppear() { super.viewDidAppear(); view.window?.makeFirstResponder(search) }

    func render() {
        guard isViewLoaded else { return }
        let state = model.state
        let labels: [String: (String, String, String)] = [
            "disconnected": ("Disconnected", "Your regular connection is in use.", "power.circle"),
            "resolving": ("Finding a server", "Choosing an available IKEv2 connection.", "network"),
            "connecting": ("Connecting", "Waiting for Nord to confirm the connection.", "arrow.triangle.2.circlepath.circle"),
            "connected": ("Connected", state.hostname ?? "Native IKEv2 connection is active.", "checkmark.shield.fill"),
            "reconnecting": ("Reconnecting", "Restoring your chosen connection.", "arrow.triangle.2.circlepath.circle"),
            "disconnecting": ("Disconnecting", "Waiting for the connection to stop.", "power.circle"),
            "failed": ("Could not connect", state.error ?? "Retry your requested location.", "exclamationmark.circle")
        ]
        let info = labels[state.phase] ?? labels["disconnected"]!
        headline.stringValue = state.phase == "failed" && !state.wanted ? "Could not disconnect" : info.0
        statusIcon.image = NSImage(systemSymbolName: info.2, accessibilityDescription: info.0)
        statusIcon.contentTintColor = state.phase == "connected" ? .systemGreen : state.phase == "failed" ? .systemOrange : .secondaryLabelColor
        detail.stringValue = model.notice ?? info.1
        detail.textColor = model.notice == nil && state.phase != "failed" ? .secondaryLabelColor : .labelColor
        locationLabel.stringValue = state.requested?.title ?? selected?.title ?? "Choose a location to connect"
        let busy = ["resolving", "connecting", "reconnecting", "disconnecting"].contains(state.phase)
        connect.title = state.phase == "failed" ? "Retry" : state.phase == "connected" ? "Switch location" : "Connect"
        connect.isEnabled = !busy && (selected != nil || state.requested != nil)
        stop.isHidden = !state.wanted && !["connected", "disconnecting", "failed"].contains(state.phase)
        stop.title = busy && state.phase != "disconnecting" ? "Cancel" : "Disconnect"
        stop.isEnabled = state.phase != "disconnecting"
        let previous = selected
        let previousItem = table.selectedRow >= 0 ? table.item(atRow: table.selectedRow) : nil
        let previousIsChild = previousItem.map { table.parent(forItem: $0) != nil } ?? false
        let all = model.core.search("")
        let matches = model.core.search(search.stringValue)
        countries = LocationItem.countries(from: all, matching: matches)
        if search.stringValue != previousQuery && !search.stringValue.isEmpty {
            expandedCountries.formUnion(countries.filter { !$0.children.isEmpty }.map { $0.location.country_id })
        }
        previousQuery = search.stringValue
        rendering = true
        table.reloadData()
        for country in countries where expandedCountries.contains(country.location.country_id) {
            table.expandItem(country)
        }
        if let previous, let index = (0..<table.numberOfRows).first(where: { row in
            guard let item = table.item(atRow: row) as? LocationItem else { return false }
            return item.location == previous && (table.parent(forItem: item) != nil) == previousIsChild
        }) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        } else { table.deselectAll(nil) }
        rendering = false
        if model.fetching { summary.stringValue = "Refreshing locations…" }
        else if search.stringValue.isEmpty {
            summary.stringValue = "\(all.filter { $0.city_id == nil }.count) countries · \(all.filter { $0.city != nil || $0.single_city != nil }.count) cities"
        } else { summary.stringValue = "\(countries.count) matching \(countries.count == 1 ? "country" : "countries")" }
        refresh.isEnabled = !model.fetching
        empty.isHidden = !countries.isEmpty
        empty.stringValue = model.fetching ? "Loading locations…" : all.isEmpty ? "Refresh to load locations" : "No matching locations"
    }
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        ((item as? LocationItem)?.children ?? countries).count
    }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        ((item as? LocationItem)?.children ?? countries)[index]
    }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        !(item as! LocationItem).children.isEmpty
    }
    func outlineView(_ outlineView: NSOutlineView, shouldExpandItem item: Any) -> Bool {
        if !rendering { expandedCountries.insert((item as! LocationItem).location.country_id) }
        return true
    }
    func outlineView(_ outlineView: NSOutlineView, shouldCollapseItem item: Any) -> Bool {
        if !rendering { expandedCountries.remove((item as! LocationItem).location.country_id) }
        return true
    }
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("cell")
        let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? LocationCell ?? LocationCell(frame: .zero)
        cell.identifier = identifier
        cell.set((item as! LocationItem).location, isChild: outlineView.parent(forItem: item) != nil)
        return cell
    }
    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !rendering, table.selectedRow >= 0, let item = table.item(atRow: table.selectedRow) as? LocationItem else { return }
        selected = item.location
        render()
    }
    func controlTextDidChange(_ obj: Notification) { render() }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.moveDown(_:)) || commandSelector == #selector(NSResponder.moveUp(_:)) {
            guard table.numberOfRows > 0 else { return true }
            let delta = commandSelector == #selector(NSResponder.moveDown(_:)) ? 1 : -1
            let index = max(0, min(table.numberOfRows - 1, table.selectedRow + delta))
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            table.scrollRowToVisible(index); return true
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) { connectPressed(); return true }
        return false
    }
    @objc private func connectPressed() {
        guard connect.isEnabled else { return }
        if let location = selected ?? model.state.requested { model.connect(location) }
    }
    @objc private func disconnectPressed() { model.disconnect() }
    @objc private func settingsPressed() { showSettings?() }
    @objc private func refreshPressed() { model.refreshCatalogue() }
    @objc private func quitPressed() { NSApp.terminate(nil) }
}

final class SettingsController: NSWindowController, NSWindowDelegate {
    let model: AppModel
    var showLocations: (() -> Void)?
    private let username = NSTextField()
    private let password = NSSecureTextField()
    private let result = Style.label("", size: 12, color: .secondaryLabelColor)
    private let certificate = NSButton(title: "Set up Nord certificate…", target: nil, action: nil)
    private let signIn = NSButton(title: "Sign in with Nord Account", target: nil, action: nil)
    private let save = NSButton(title: "Save credentials", target: nil, action: nil)
    private let chooseLocation = NSButton(title: "Choose a location", target: nil, action: nil)
    private let manual = NSButton(title: "Enter IKEv2 credentials manually", target: nil, action: nil)
    private let activity = NSProgressIndicator()
    private var manualFields: NSStackView!
    private var layout: NSStackView!
    private lazy var account = NordAccount(http: model.http, openBrowser: { [weak self] url, completion in
        guard let window = self?.window else {
            completion(.failure(NordAccount.SignInError.browserUnavailable)); return {}
        }
        let browser = AccountBrowser(anchor: window)
        browser.open(url, completion: completion)
        return { browser.cancel() }
    })
    init(model: AppModel) {
        self.model = model
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 560),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Meridian Settings"; window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        let intro = Style.label("Nord Account", size: 21, weight: .semibold)
        let browserHelp = Style.label("Sign in once through your browser. Meridian fetches your IKEv2 credentials and keeps them in Keychain.", size: 12, color: .secondaryLabelColor)
        browserHelp.maximumNumberOfLines = 3; browserHelp.preferredMaxLayoutWidth = 392
        browserHelp.lineBreakMode = .byWordWrapping
        signIn.target = self; signIn.action = #selector(signInPressed)
        signIn.bezelStyle = .rounded; signIn.controlSize = .large; signIn.bezelColor = Style.accent
        manual.target = self; manual.action = #selector(toggleManual)
        manual.isBordered = false; manual.contentTintColor = .secondaryLabelColor
        manual.setAccessibilityLabel("Show manual IKEv2 setup")
        manual.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)
        manual.imagePosition = .imageLeading
        chooseLocation.target = self; chooseLocation.action = #selector(chooseLocationPressed)
        chooseLocation.bezelStyle = .rounded; chooseLocation.controlSize = .large
        chooseLocation.isHidden = true
        let explanation = Style.label("Use the service username and password from Nord's manual setup page. These differ from your account email and password.", size: 12, color: .secondaryLabelColor)
        explanation.maximumNumberOfLines = 3; explanation.preferredMaxLayoutWidth = 392
        explanation.lineBreakMode = .byWordWrapping
        username.placeholderString = "IKEv2 service username"; username.setAccessibilityLabel("Nord IKEv2 service username")
        password.placeholderString = "IKEv2 service password"; password.setAccessibilityLabel("Nord IKEv2 service password")
        username.controlSize = .large; password.controlSize = .large
        let account = NSButton(title: "Get IKEv2 service credentials ↗", target: self, action: #selector(openAccount))
        account.isBordered = false; account.contentTintColor = Style.accent
        save.target = self; save.action = #selector(savePressed)
        save.bezelStyle = .rounded; save.controlSize = .large
        let stored = Style.label("Saved in your login Keychain. Never sent to the location catalogue.", size: 11, color: .secondaryLabelColor)
        stored.maximumNumberOfLines = 2; stored.preferredMaxLayoutWidth = 392
        stored.lineBreakMode = .byWordWrapping
        let separator = NSBox(); separator.boxType = .separator
        certificate.target = self; certificate.action = #selector(certificatePressed); certificate.bezelStyle = .rounded
        let guide = NSButton(title: "Nord setup guide ↗", target: self, action: #selector(openGuide))
        guide.isBordered = false; guide.contentTintColor = Style.accent
        let certificateRow = Style.stack([certificate, guide], orientation: .horizontal, spacing: 12)
        result.maximumNumberOfLines = 3; result.preferredMaxLayoutWidth = 392
        result.lineBreakMode = .byWordWrapping
        activity.style = .spinning; activity.controlSize = .small
        activity.isDisplayedWhenStopped = false; activity.isHidden = true
        activity.setAccessibilityLabel("Signing in to Nord Account")
        let progress = Style.stack([activity, result], orientation: .horizontal, spacing: 8)
        manualFields = Style.stack([explanation, account, username, password, save, stored], spacing: 12)
        manualFields.isHidden = true
        layout = Style.stack([intro, browserHelp, signIn, progress, chooseLocation, manual, manualFields, separator, certificateRow], spacing: 12)
        layout.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(layout)
        for child in [browserHelp, manualFields!, explanation, username, password, stored, separator, progress] { child.widthAnchor.constraint(equalTo: layout.widthAnchor).isActive = true }
        NSLayoutConstraint.activate([
            layout.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 24),
            layout.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -24),
            layout.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 24),
            layout.bottomAnchor.constraint(lessThanOrEqualTo: window.contentView!.bottomAnchor, constant: -20)
        ])
        if let saved = try? Credentials.load() {
            username.stringValue = saved.username; password.placeholderString = "Saved in Keychain"
            result.stringValue = "Service credentials saved in Keychain."
            credentialsReady()
        }
        self.account.progress = { [weak self] text in
            self?.result.stringValue = text; self?.result.textColor = .secondaryLabelColor
        }
        resizeToFit(); window.center()
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func signInPressed() {
        if account.isSigningIn { account.cancel(); return }
        signIn.title = "Cancel sign-in"
        activity.isHidden = false; activity.startAnimation(nil)
        chooseLocation.isHidden = true
        manual.isEnabled = false
        username.isEnabled = false; password.isEnabled = false; save.isEnabled = false
        resizeToFit()
        account.signIn { [weak self] response in
            guard let self else { return }
            self.signIn.title = "Sign in with Nord Account"
            self.activity.stopAnimation(nil); self.activity.isHidden = true
            self.manual.isEnabled = true
            self.username.isEnabled = true; self.password.isEnabled = true; self.save.isEnabled = true
            switch response {
            case .success:
                if let saved = try? Credentials.load() { self.username.stringValue = saved.username }
                self.password.stringValue = ""; self.password.placeholderString = "Saved in Keychain"
                self.result.stringValue = "Ready. Your IKEv2 credentials are saved in Keychain."
                self.result.textColor = .secondaryLabelColor
                self.credentialsReady()
                NSApp.activate(ignoringOtherApps: true)
                self.window?.makeKeyAndOrderFront(nil)
            case .failure(let error):
                self.result.stringValue = error.localizedDescription
                self.result.textColor = (error as? NordAccount.SignInError) == .cancelled ? .secondaryLabelColor : .systemRed
            }
            self.resizeToFit()
        }
    }
    private func credentialsReady() {
        chooseLocation.isHidden = false; chooseLocation.bezelColor = Style.accent
        signIn.title = "Update credentials"; signIn.bezelColor = nil
    }
    private func resizeToFit() {
        guard let window else { return }
        window.contentView?.layoutSubtreeIfNeeded()
        let content = NSRect(x: 0, y: 0, width: 440, height: layout.fittingSize.height + 48)
        var frame = window.frameRect(forContentRect: content)
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        window.setFrame(frame, display: true)
    }
    @objc private func toggleManual() {
        manualFields.isHidden.toggle()
        manual.image = NSImage(systemSymbolName: manualFields.isHidden ? "chevron.right" : "chevron.down", accessibilityDescription: nil)
        manual.setAccessibilityLabel(manualFields.isHidden ? "Show manual IKEv2 setup" : "Hide manual IKEv2 setup")
        resizeToFit()
    }
    @objc private func chooseLocationPressed() { close(); showLocations?() }
    func windowWillClose(_ notification: Notification) { account.cancel() }
    @objc private func savePressed() {
        do {
            try Credentials.save(username: username.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), password: password.stringValue)
            password.stringValue = ""; password.placeholderString = "Saved in Keychain"
            result.stringValue = "Credentials saved. Choose a location and click Connect."
            result.textColor = .secondaryLabelColor
            credentialsReady()
        } catch { result.stringValue = error.localizedDescription; result.textColor = .systemRed }
        resizeToFit()
    }
    @objc private func openAccount() { NSWorkspace.shared.open(URL(string: "https://my.nordaccount.com/dashboard/nordvpn/")!) }
    @objc private func openGuide() { NSWorkspace.shared.open(NordCertificate.guide) }
    @objc private func certificatePressed() {
        let alert = NSAlert()
        alert.messageText = "Trust Nord's certificate for VPN authentication?"
        alert.informativeText = "Meridian will download the reviewed NordVPN root certificate and trust it for EAP and IPsec in your login Keychain. It will not enable website trust. macOS may ask for your password."
        alert.addButton(withTitle: "Set up certificate"); alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window!) { [weak self] answer in
            guard let self, answer == .alertFirstButtonReturn else { return }
            self.certificate.isEnabled = false; self.result.stringValue = "Downloading Nord's certificate…"
            self.model.http.fetch(NordCertificate.download, limit: 16_384) { [weak self] response in
                guard let self else { return }
                self.certificate.isEnabled = true
                do {
                    try NordCertificate.install(response.get().data)
                    self.result.stringValue = "Nord's certificate is ready for VPN authentication."
                    self.result.textColor = .secondaryLabelColor
                } catch { self.result.stringValue = error.localizedDescription; self.result.textColor = .systemRed }
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var item: NSStatusItem!
    private var popover: NSPopover!
    private var settings: SettingsController?
    private var previewWindow: NSWindow?
    private var model: AppModel!
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installMenu()
        model = AppModel()
        let controller = PopoverController(model: model)
        controller.showSettings = { [weak self] in self?.openSettings() }
        model.needsCredentials = { [weak self] in self?.openSettings() }
        popover = NSPopover(); popover.contentSize = NSSize(width: Style.width, height: Style.height)
        popover.behavior = .transient; popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        popover.contentViewController = controller
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "globe.europe.africa", accessibilityDescription: "Meridian")
        item.button?.image?.isTemplate = true
        item.button?.target = self; item.button?.action = #selector(togglePopover)
        item.button?.toolTip = "Meridian · Disconnected"
        item.button?.setAccessibilityLabel("Meridian")
        controller.loadViewIfNeeded()
        let render = model.changed
        model.changed = { [weak self] in
            render?()
            guard let self else { return }
            let state = self.model.state
            let symbol = state.phase == "connected" ? "checkmark.shield" : state.phase == "failed" ? "exclamationmark.shield" : "globe.europe.africa"
            self.item.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Meridian \(state.phase)")
            self.item.button?.image?.isTemplate = true
            self.item.button?.toolTip = "Meridian · \(state.phase.capitalized)"
        }
        if ProcessInfo.processInfo.arguments.contains("--preview") {
            // A regular window exposes the same content to accessibility-based UI verification.
            NSApp.setActivationPolicy(.regular)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Style.width, height: Style.height),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Meridian Preview"; window.contentViewController = controller
            window.isReleasedWhenClosed = false; window.center(); window.makeKeyAndOrderFront(nil)
            previewWindow = window
            NSApp.activate(ignoringOtherApps: true)
        }
    }
    private func installMenu() {
        let menu = NSMenu()
        let app = NSMenuItem(); let submenu = NSMenu()
        submenu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        submenu.addItem(.separator())
        submenu.addItem(withTitle: "Quit Meridian", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        app.submenu = submenu; menu.addItem(app)
        let edit = NSMenuItem(); let editing = NSMenu(title: "Edit")
        for (title, action, key) in [("Cut", #selector(NSText.cut(_:)), "x"), ("Copy", #selector(NSText.copy(_:)), "c"), ("Paste", #selector(NSText.paste(_:)), "v"), ("Select All", #selector(NSText.selectAll(_:)), "a")] {
            editing.addItem(withTitle: title, action: action, keyEquivalent: key)
        }
        edit.submenu = editing; menu.addItem(edit); NSApp.mainMenu = menu
    }
    @objc func togglePopover() {
        guard let button = item.button else { return }
        if popover.isShown { popover.performClose(nil) }
        else {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }
    @objc func openSettings() {
        popover?.performClose(nil)
        if settings == nil {
            settings = SettingsController(model: model)
            settings?.showLocations = { [weak self] in
                guard let self else { return }
                if let previewWindow = self.previewWindow { previewWindow.makeKeyAndOrderFront(nil) }
                else { self.togglePopover() }
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        settings?.showWindow(nil); settings?.window?.makeKeyAndOrderFront(nil)
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let previewWindow { previewWindow.makeKeyAndOrderFront(nil) }
        else if !popover.isShown { togglePopover() }
        return true
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if model?.state.wanted == true || model?.state.phase == "connected" {
            let alert = NSAlert(); alert.messageText = "Quit Meridian?"
            alert.informativeText = "The current VPN connection will stay as it is. Automatic reconnects stop when Meridian quits."
            alert.addButton(withTitle: "Quit"); alert.addButton(withTitle: "Cancel")
            if alert.runModal() != .alertFirstButtonReturn { return .terminateCancel }
        }
        return .terminateNow
    }
}

private func selfCheck() -> Int32 {
    let core = Core()
    let catalogue: [[String: Any]] = [
        ["id": 81, "name": "Germany", "code": "DE", "cities": [["id": 1, "name": "Berlin"], ["id": 2, "name": "Munich"]]],
        ["id": 195, "name": "Singapore", "code": "SG", "cities": [["id": 3, "name": "Singapore"]]]
    ]
    guard core.call(["op": "catalogue", "payload": catalogue])["ok"] as? Bool == true,
          core.search("ber de").count == 1, core.state.phase == "disconnected",
          core.search("sg").count == 1, core.search("sg").first?.subtitle == "Recommended server",
          core.search("Germany").first?.title == "Germany · Any city",
          core.search("Germany").first?.subtitle == "Any city · Recommended server",
          core.search("ber de").first?.subtitle == "Germany · City" else { return 1 }
    let countries = LocationItem.countries(from: core.search(""), matching: core.search(""))
    let citySearch = LocationItem.countries(from: core.search(""), matching: core.search("ber de"))
    guard countries.count == 2, countries[0].children.count == 3, countries[1].children.isEmpty,
          countries[0].children.first?.location.city == nil,
          citySearch.count == 1, citySearch[0].location.country == "Germany",
          citySearch[0].children.count == 2, citySearch[0].children[1].location.city == "Berlin" else { return 1 }
    let native = NativeVPN()
    print("PASS: Rust FFI, catalogue, search, country/city hierarchy, initial disconnected state; native controls available=\(native.available). No VPN, Keychain, trust, or network writes.")
    return 0
}

private func checkCatalogue() {
    let core = Core()
    let http = SmallHTTP()
    let catalogueURL = URL(string: core.call(["op": "snapshot"])["catalogue_url"] as! String)!
    http.fetch(catalogueURL) { result in
        do {
            let response = try result.get()
            let payload = try JSONSerialization.jsonObject(with: response.data)
            guard core.call(["op": "catalogue", "payload": payload])["ok"] as? Bool == true else {
                throw Credentials.error("Catalogue validation failed.")
            }
            let locations = core.search("")
            guard let first = locations.first else { throw Credentials.error("No locations.") }
            let request = core.call(["op": "connect", "country_id": first.country_id])
            let url = URL(string: request["url"] as! String)!
            http.fetch(url, limit: 65_536) { recommendation in
                do {
                    let server = try recommendation.get()
                    let payload = try JSONSerialization.jsonObject(with: server.data)
                    let checked = core.call(["op": "recommendation", "generation": core.state.generation, "payload": payload])
                    guard checked["effect"] as? String == "connect" else { throw Credentials.error("Recommendation validation failed.") }
                    http.fetch(catalogueURL, modified: response.modified) { conditional in
                        do {
                            let refreshed = try conditional.get()
                            guard refreshed.status == 304 || refreshed.status == 200 else { throw Credentials.error("Conditional fetch failed.") }
                            let metrics: [String: Any] = ["countries": locations.filter { $0.city_id == nil }.count,
                                "cities": locations.filter { $0.city != nil || $0.single_city != nil }.count, "catalogue_decoded_bytes": response.data.count,
                                "recommendation_decoded_bytes": server.data.count, "conditional_status": refreshed.status,
                                "requests": http.requestCount, "transferred_body_bytes": http.receivedBytes,
                                "vpn_operations": 0]
                            print(String(decoding: try JSONSerialization.data(withJSONObject: metrics, options: [.sortedKeys]), as: UTF8.self))
                            exit(0)
                        } catch { fputs("Catalogue check failed: \(error.localizedDescription)\n", stderr); exit(1) }
                    }
                } catch { fputs("Catalogue check failed: \(error.localizedDescription)\n", stderr); exit(1) }
            }
        } catch { fputs("Catalogue check failed: \(error.localizedDescription)\n", stderr); exit(1) }
    }
    RunLoop.main.run()
}

@main
enum Meridian {
    static func main() {
        if ProcessInfo.processInfo.arguments.contains("--self-check") {
            exit(selfCheck())
        }
        if ProcessInfo.processInfo.arguments.contains("--check-catalogue") { checkCatalogue(); return }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
