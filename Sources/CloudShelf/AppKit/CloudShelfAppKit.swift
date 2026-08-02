import AppKit
import CloudShelfCore
import UniformTypeIdentifiers

final class CloudShelfApplication: NSObject, NSApplicationDelegate {
    private var controller: FileManagerWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        let controller = FileManagerWindowController()
        self.controller = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

private enum RemoteClipboardOperation {
    case copy
    case move
}

private enum BrowserRow: Equatable {
    case parentDirectory
    case item(RemoteItem)

    var identifier: String {
        switch self {
        case .parentDirectory: return "__cloudshelf_parent_directory__"
        case .item(let item): return item.path
        }
    }

    var item: RemoteItem? {
        guard case .item(let item) = self else { return nil }
        return item
    }
}

private final class RemoteFilePromise: NSObject, @unchecked Sendable {
    let item: RemoteItem
    let client: any RemoteClient

    init(item: RemoteItem, client: any RemoteClient) {
        self.item = item
        self.client = client
    }
}

private final class FilePromiseCompletion: @unchecked Sendable {
    private let handler: (Error?) -> Void

    init(_ handler: @escaping (Error?) -> Void) { self.handler = handler }

    func finish(_ error: Error?) { handler(error) }
}

@MainActor
final class FileManagerWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSToolbarDelegate, NSFilePromiseProviderDelegate {
    fileprivate let store = WorkspaceStore()
    fileprivate let connectionTable = NSTableView()
    fileprivate let browserTable = NSTableView()
    fileprivate let transferTable = NSTableView()
    fileprivate let pathLabel = NSTextField(labelWithString: "/")
    fileprivate let connectionStatus = NSTextField(labelWithString: "未选择连接")
    private var selectedProfileID: UUID?
    private var session: RemoteSession?
    private var refreshTimer: Timer?
    private var clipboardItems: [RemoteItem] = []
    private var clipboardProfileID: UUID?
    private var clipboardOperation: RemoteClipboardOperation = .copy
    private var presentingError = false
    private var lastSessionError: String?
    private var displayedProfiles: [ConnectionProfile] = []
    private var displayedSessionID: UUID?
    private var displayedRows: [BrowserRow] = []
    private var displayedTransfers: [TransferTask] = []
    private var restoringConnectionSelection = false
    private var propertiesWindowController: RemoteItemPropertiesWindowController?
    private var syncRulesWindowController: SyncRulesWindowController?

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1240, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "CloudShelf"
        window.minSize = NSSize(width: 980, height: 620)
        super.init(window: window)
        window.contentViewController = FileManagerViewController(owner: self)
        configureMainMenu()
        configureToolbar()
        refreshTimer = Timer.scheduledTimer(timeInterval: 0.5, target: self, selector: #selector(refreshViews), userInfo: nil, repeats: true)
    }

    required init?(coder: NSCoder) { nil }

    func numberOfRows(in tableView: NSTableView) -> Int {
        if tableView === connectionTable { return store.profiles.count }
        if tableView === browserTable { return browserRows.count }
        return displayedTransfers.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = tableColumn?.identifier.rawValue ?? ""
        let text: String
        let icon: NSImage?
        if tableView === connectionTable {
            let profile = store.profiles[row]
            switch identifier {
            case "connection": text = profile.name
            case "protocol": text = profile.protocolType.rawValue
            default: text = ""
            }
            icon = symbol(profile.protocolType == .sftp ? "lock.shield" : "externaldrive.connected.to.line.below")
        } else if tableView === browserTable, row >= 0, row < browserRows.count {
            switch browserRows[row] {
            case .parentDirectory:
                switch identifier {
                case "name": text = ".."
                case "type": text = "上级目录"
                default: text = "-"
                }
                icon = identifier == "name" ? symbol("arrow.uturn.up") : nil
            case .item(let item):
                switch identifier {
                case "name": text = item.name
                case "modified": text = item.modifiedAt?.formatted(date: .abbreviated, time: .shortened) ?? "-"
                case "size": text = item.isDirectory ? "-" : item.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "-"
                case "type": text = item.isDirectory ? "文件夹" : (item.fileExtension.isEmpty ? "文件" : item.fileExtension.uppercased())
                default: text = ""
                }
                icon = identifier == "name" ? symbol(item.isDirectory ? "folder.fill" : "doc") : nil
            }
        } else {
            let transfer = displayedTransfers[row]
            if identifier == "progress" { return transferProgressCell(transfer) }
            switch identifier {
            case "transfer": text = transfer.title
            case "state": text = "\(transfer.connectionName) - \(transfer.detail)"
            case "speed": text = transferSpeedDescription(transfer)
            default: text = ""
            }
            icon = identifier == "transfer" ? symbol(transfer.status == .failed ? "xmark.circle.fill" : transfer.status == .succeeded ? "checkmark.circle.fill" : "arrow.left.arrow.right") : nil
        }
        return cell(identifier: NSUserInterfaceItemIdentifier("cell-\(identifier)"), text: text, image: icon)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard notification.object as? NSTableView === connectionTable else { return }
        guard !restoringConnectionSelection else { return }
        let row = connectionTable.selectedRow
        guard row >= 0, row < store.profiles.count else { return }
        let profile = store.profiles[row]
        selectedProfileID = profile.id
        Task { [weak self] in
            await self?.store.mount(profile)
            guard let self else { return }
            self.session = self.store.sessions[profile.id]
            self.refreshViews()
        }
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { true }

    func tableView(_ tableView: NSTableView, menuFor event: NSEvent) -> NSMenu? {
        let point = tableView.convert(event.locationInWindow, from: nil)
        let row = tableView.row(at: point)
        if row >= 0, !tableView.selectedRowIndexes.contains(row) {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }

        if tableView === browserTable { return browserContextMenu() }
        if tableView === connectionTable { return connectionContextMenu() }
        return nil
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        guard tableView === browserTable,
              let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL],
              let session else { return false }
        store.upload(urls, to: session)
        return true
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        tableView === browserTable && session != nil ? .copy : []
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        guard tableView === browserTable,
              row >= 0,
              row < browserRows.count,
              let item = browserRows[row].item,
              !item.isDirectory,
              let session else { return nil }
        let type = UTType(filenameExtension: item.fileExtension)?.identifier ?? UTType.data.identifier
        let provider = NSFilePromiseProvider(fileType: type, delegate: self)
        provider.userInfo = RemoteFilePromise(item: item, client: session.client)
        return provider
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        (filePromiseProvider.userInfo as? RemoteFilePromise)?.item.name ?? "CloudShelf 下载"
    }

    func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider,
        writePromiseTo url: URL,
        completionHandler: @escaping (Error?) -> Void
    ) {
        guard let promise = filePromiseProvider.userInfo as? RemoteFilePromise else {
            completionHandler(CloudShelfError.commandFailed("无法读取待拖出的远端文件。"))
            return
        }
        let completion = FilePromiseCompletion(completionHandler)
        let item = promise.item
        let client = promise.client
        let destination = url.appendingPathComponent(item.name)
        Task.detached {
            do {
                try await client.download(item, to: destination)
                completion.finish(nil)
            } catch {
                completion.finish(error)
            }
        }
    }

    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue {
        OperationQueue.main
    }

    @objc func openSelectedItem() {
        guard selectedBrowserRows.count == 1, let row = selectedBrowserRows.first, let session else { return }
        Task { [weak self] in
            switch row {
            case .parentDirectory:
                await session.goUp()
            case .item(let item) where item.isDirectory:
                await session.open(item)
            case .item:
                return
            }
            self?.refreshViews()
        }
    }

    @objc func refreshViews() {
        reloadConnectionTableIfNeeded()
        reloadBrowserTableIfNeeded()
        reloadTransferTableIfNeeded()
        pathLabel.stringValue = session?.location ?? "/"
        if let session {
            connectionStatus.stringValue = "\(session.profile.name)  |  \(session.profile.protocolType.rawValue)  |  \(session.isLoading ? "正在加载" : "已连接")"
        } else {
            connectionStatus.stringValue = "未选择连接"
        }
        showErrorIfNeeded()
    }

    private func reloadConnectionTableIfNeeded() {
        guard displayedProfiles != store.profiles else { return }
        displayedProfiles = store.profiles
        connectionTable.reloadData()

        guard let selectedProfileID,
              let row = store.profiles.firstIndex(where: { $0.id == selectedProfileID }),
              connectionTable.selectedRow != row else { return }
        restoringConnectionSelection = true
        connectionTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        restoringConnectionSelection = false
    }

    private func reloadBrowserTableIfNeeded() {
        let currentSessionID = session?.id
        let currentRows = browserRows
        guard displayedSessionID != currentSessionID || displayedRows != currentRows else { return }
        let selectedIdentifiers = displayedSessionID == currentSessionID ? selectedBrowserRows.map(\.identifier) : []
        displayedSessionID = currentSessionID
        displayedRows = currentRows
        browserTable.reloadData()
        let selectedRows = IndexSet(currentRows.indices.filter { selectedIdentifiers.contains(currentRows[$0].identifier) })
        browserTable.selectRowIndexes(selectedRows, byExtendingSelection: false)
    }

    private func reloadTransferTableIfNeeded() {
        let currentTransfers = Array(store.transfers.suffix(8).reversed())
        guard displayedTransfers != currentTransfers else { return }
        displayedTransfers = currentTransfers
        transferTable.reloadData()
    }

    func addConnection() {
        let form = ConnectionForm()
        presentForm(title: "新建连接", form: form, actionTitle: "保存") { [weak self] in
            guard let self else { return }
            guard let profile = form.profile() else {
                self.presentError(form.validationError ?? "请检查连接设置。")
                return
            }
            Task {
                await self.store.save(profile: profile, secret: form.secret)
                self.selectedProfileID = profile.id
                await self.store.mount(profile)
                self.session = self.store.sessions[profile.id]
                self.refreshViews()
            }
        }
    }

    func editConnection() {
        guard let profile = selectedProfile else { return }
        let form = ConnectionForm(profile: profile)
        presentForm(title: "编辑连接", form: form, actionTitle: "保存") { [weak self] in
            guard let self else { return }
            guard let changed = form.profile(existing: profile) else {
                self.presentError(form.validationError ?? "请检查连接设置。")
                return
            }
            Task {
                self.store.unmount(profile)
                await self.store.save(profile: changed, secret: form.secret)
                await self.store.mount(changed)
                self.session = self.store.sessions[changed.id]
                self.refreshViews()
            }
        }
    }

    @objc func removeConnection() {
        guard let profile = selectedProfile else { return }
        let alert = NSAlert()
        alert.messageText = "移除 \(profile.name)？"
        alert.informativeText = "这会删除保存的连接和钥匙串凭据，不会改动远端文件。"
        alert.addButton(withTitle: "移除")
        alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window!) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            Task {
                await self.store.delete(profile: profile)
                self.selectedProfileID = nil
                self.session = nil
                self.refreshViews()
            }
        }
    }

    func reloadFolder() {
        guard let session else { return }
        Task { [weak self] in await session.reload(); self?.refreshViews() }
    }

    func goUp() {
        guard let session else { return }
        Task { [weak self] in await session.goUp(); self?.refreshViews() }
    }

    func connectSelected() {
        guard let profile = selectedProfile else { return }
        Task { [weak self] in
            guard let self else { return }
            await self.store.mount(profile)
            self.session = self.store.sessions[profile.id]
            self.refreshViews()
        }
    }

    func disconnectSelected() {
        guard let profile = selectedProfile else { return }
        store.unmount(profile)
        session = nil
        refreshViews()
    }

    func newFolder() {
        guard let session else { return }
        prompt(title: "新建文件夹", message: "在 \(session.location) 中创建文件夹", placeholder: "文件夹名称") { [weak self] name in
            guard let self else { return }
            Task { await self.store.createFolder(name, in: session); self.refreshViews() }
        }
    }

    func rename() {
        guard let item = selectedItems.first, selectedItems.count == 1, let session else { return }
        prompt(title: "重命名", message: item.name, placeholder: "新名称", value: item.name) { [weak self] name in
            guard let self else { return }
            Task { await self.store.rename(item, to: name, in: session); self.refreshViews() }
        }
    }

    func deleteItems() {
        let items = selectedItems
        guard !items.isEmpty, let session else { return }
        let alert = NSAlert()
        alert.messageText = "删除已选择的 \(items.count) 项？"
        alert.informativeText = "删除会立即作用于远端服务器。"
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window!) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            Task { await self.store.delete(items, in: session); self.refreshViews() }
        }
    }

    func chooseUploads() {
        guard let session else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "上传"
        panel.beginSheetModal(for: window!) { [weak self] response in
            guard response == .OK, let self else { return }
            self.store.upload(panel.urls, to: session)
        }
    }

    func chooseDownloads() {
        let items = selectedItems
        guard !items.isEmpty, let session else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "下载到此处"
        panel.beginSheetModal(for: window!) { [weak self] response in
            guard response == .OK, let destination = panel.url, let self else { return }
            self.store.download(items, to: destination, from: session)
        }
    }

    func copyItems() { moveOrCopy(isMove: false) }
    func moveItems() { moveOrCopy(isMove: true) }

    func configureSync() {
        guard let profile = selectedProfile, let session else {
            presentError("请先连接服务器，再配置同步规则。")
            return
        }
        syncRulesWindowController?.close()
        let controller = SyncRulesWindowController(
            profile: profile,
            session: session,
            saveRules: { [weak self] rules in
                guard let self else { return }
                Task {
                    await self.store.replaceSyncRules(rules, for: profile.id)
                    self.refreshViews()
                }
            },
            runRule: { [weak self] ruleID in
                guard let self, let latest = self.store.profile(id: profile.id),
                      let rule = latest.syncRules.first(where: { $0.id == ruleID }) else { return }
                self.store.sync(profile: latest, rule: rule)
            }
        )
        syncRulesWindowController = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    func runSync() {
        guard let profile = selectedProfile else { return }
        let rules = profile.syncRules.filter(\.isEnabled)
        guard !rules.isEmpty else {
            configureSync()
            return
        }
        rules.forEach { store.sync(profile: profile, rule: $0) }
    }

    private func moveOrCopy(isMove: Bool) {
        let items = selectedItems
        guard !items.isEmpty, let session else { return }
        prompt(title: isMove ? "移动到文件夹" : "复制到文件夹", message: "输入远端目标文件夹。", placeholder: "/目标文件夹", value: session.location) { [weak self] destination in
            guard let self else { return }
            if isMove { self.store.move(items, to: RemotePath.normalized(destination), from: session) }
            else { self.store.copy(items, to: RemotePath.normalized(destination), from: session) }
        }
    }

    private var selectedProfile: ConnectionProfile? {
        selectedProfileID.flatMap { store.profile(id: $0) }
    }

    private var browserRows: [BrowserRow] {
        guard let session else { return [] }
        let items = session.items.map(BrowserRow.item)
        return session.location == "/" ? items : [.parentDirectory] + items
    }

    private var selectedBrowserRows: [BrowserRow] {
        browserTable.selectedRowIndexes.compactMap { index in
            guard index >= 0, index < browserRows.count else { return nil }
            return browserRows[index]
        }
    }

    private var selectedItems: [RemoteItem] {
        selectedBrowserRows.compactMap(\.item)
    }

    private func browserContextMenu() -> NSMenu {
        let menu = NSMenu(title: "文件")
        let hasParentRow = selectedBrowserRows.contains(.parentDirectory)
        let items = selectedItems
        let hasItems = !items.isEmpty
        let canOpen = items.count == 1 && items[0].isDirectory
        let canShowProperties = items.count == 1

        if hasParentRow {
            menu.addItem(contextMenuItem("返回上级目录", #selector(openSelectedItem), enabled: true))
            menu.addItem(.separator())
            menu.addItem(contextMenuItem("刷新", #selector(reloadAction), enabled: session != nil))
            return menu
        }

        menu.addItem(contextMenuItem("打开", #selector(openSelectedItem), enabled: canOpen))
        menu.addItem(contextMenuItem("下载", #selector(downloadAction), enabled: hasItems))
        menu.addItem(.separator())
        menu.addItem(contextMenuItem("剪切", #selector(cutSelectionAction), key: "x", enabled: hasItems))
        menu.addItem(contextMenuItem("复制", #selector(copySelectionAction), key: "c", enabled: hasItems))
        menu.addItem(contextMenuItem("粘贴", #selector(pasteSelectionAction), key: "v", enabled: session != nil && !clipboardItems.isEmpty))
        menu.addItem(.separator())
        menu.addItem(contextMenuItem("重命名", #selector(renameAction), enabled: items.count == 1))
        menu.addItem(contextMenuItem("复制到指定文件夹", #selector(copyAction), enabled: hasItems))
        menu.addItem(contextMenuItem("移动到指定文件夹", #selector(moveAction), enabled: hasItems))
        menu.addItem(contextMenuItem("删除", #selector(deleteAction), key: "\u{8}", enabled: hasItems))
        menu.addItem(.separator())
        menu.addItem(contextMenuItem("属性", #selector(propertiesAction), key: "i", enabled: canShowProperties))
        return menu
    }

    private func connectionContextMenu() -> NSMenu {
        let menu = NSMenu(title: "连接")
        let hasProfile = selectedProfile != nil
        menu.addItem(contextMenuItem("连接", #selector(connectAction), enabled: hasProfile))
        menu.addItem(contextMenuItem("断开连接", #selector(disconnectAction), enabled: hasProfile && session != nil))
        menu.addItem(.separator())
        menu.addItem(contextMenuItem("编辑连接", #selector(editAction), enabled: hasProfile))
        menu.addItem(contextMenuItem("移除连接", #selector(removeConnection), enabled: hasProfile))
        menu.addItem(.separator())
        menu.addItem(contextMenuItem("新建连接", #selector(addAction), enabled: true))
        return menu
    }

    private func contextMenuItem(
        _ title: String,
        _ action: Selector,
        key: String = "",
        enabled: Bool
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        if !key.isEmpty { item.keyEquivalentModifierMask = [.command] }
        item.target = self
        item.isEnabled = enabled
        return item
    }

    private func showErrorIfNeeded() {
        if let message = store.lastError, !presentingError {
            // A failed initial connection is recorded on both the session and store.
            // Mark it handled here so the same failure is not presented twice.
            if message == session?.errorMessage { lastSessionError = message }
            presentError(message) { [weak self] in self?.store.lastError = nil }
            return
        }
        guard let message = session?.errorMessage else {
            lastSessionError = nil
            return
        }
        guard message != lastSessionError, !presentingError else { return }
        lastSessionError = message
        presentError(message)
    }

    private func presentError(_ message: String, completion: (() -> Void)? = nil) {
        guard let window else { return }
        presentingError = true
        let alert = NSAlert()
        alert.messageText = "操作失败"
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        alert.beginSheetModal(for: window) { [weak self] _ in
            self?.presentingError = false
            completion?()
        }
    }

    private func activeTextEditor() -> NSTextView? {
        (NSApp.keyWindow?.firstResponder ?? window?.firstResponder) as? NSTextView
    }

    func copySelection() {
        if let editor = activeTextEditor() { editor.copy(nil); return }
        guard let session, !selectedItems.isEmpty else {
            store.lastError = "请选择要复制的远端文件。"
            return
        }
        clipboardItems = selectedItems
        clipboardProfileID = session.profile.id
        clipboardOperation = .copy
        connectionStatus.stringValue = "已复制 \(clipboardItems.count) 项，可在目标文件夹粘贴。"
    }

    func cutSelection() {
        if let editor = activeTextEditor() { editor.cut(nil); return }
        guard let session, !selectedItems.isEmpty else {
            store.lastError = "请选择要剪切的远端文件。"
            return
        }
        clipboardItems = selectedItems
        clipboardProfileID = session.profile.id
        clipboardOperation = .move
        connectionStatus.stringValue = "已剪切 \(clipboardItems.count) 项，可在目标文件夹粘贴。"
    }

    func pasteSelection() {
        if let editor = activeTextEditor() { editor.paste(nil); return }
        guard let session else {
            store.lastError = "请先连接并打开一个远端文件夹。"
            return
        }
        guard !clipboardItems.isEmpty else {
            store.lastError = "远端剪贴板为空。"
            return
        }
        guard clipboardProfileID == session.profile.id else {
            store.lastError = "暂不支持在不同服务器之间直接粘贴，请先下载再上传。"
            return
        }
        switch clipboardOperation {
        case .copy: store.copy(clipboardItems, to: session.location, from: session)
        case .move:
            store.move(clipboardItems, to: session.location, from: session)
            clipboardItems = []
            clipboardProfileID = nil
        }
    }

    func selectAll() {
        if let editor = activeTextEditor() { editor.selectAll(nil); return }
        let itemRows = browserRows.indices.filter { browserRows[$0].item != nil }
        browserTable.selectRowIndexes(IndexSet(itemRows), byExtendingSelection: false)
    }

    func showProperties() {
        guard let item = selectedItems.first, selectedItems.count == 1, let session else { return }
        propertiesWindowController?.close()
        let controller = RemoteItemPropertiesWindowController(
            item: item,
            connectionName: session.profile.name,
            protocolName: session.profile.protocolType.rawValue,
            client: session.client
        )
        propertiesWindowController = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    private func configureToolbar() {
        let toolbar = NSToolbar(identifier: "CloudShelfToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        window?.toolbar = toolbar
    }

    private func configureMainMenu() {
        let main = NSMenu()
        main.addItem(applicationMenu())
        main.addItem(menu(title: "连接", items: [
            menuItem("新建连接", #selector(addAction), key: "n"),
            menuItem("编辑连接", #selector(editAction), key: "e"),
            .separator(),
            menuItem("连接", #selector(connectAction)),
            menuItem("断开连接", #selector(disconnectAction)),
            .separator(),
            menuItem("删除连接", #selector(removeConnection), key: "", modifiers: [])
        ]))
        main.addItem(menu(title: "编辑", items: [
            menuItem("剪切", #selector(cutSelectionAction), key: "x"),
            menuItem("复制", #selector(copySelectionAction), key: "c"),
            menuItem("粘贴", #selector(pasteSelectionAction), key: "v"),
            .separator(),
            menuItem("全选", #selector(selectAllAction), key: "a")
        ]))
        main.addItem(menu(title: "文件", items: [
            menuItem("新建文件夹", #selector(folderAction), key: "n", modifiers: [.command, .shift]),
            menuItem("上传", #selector(uploadAction), key: "u"),
            menuItem("下载", #selector(downloadAction), key: "d"),
            .separator(),
            menuItem("重命名", #selector(renameAction)),
            menuItem("属性", #selector(propertiesAction), key: "i"),
            menuItem("复制到指定文件夹", #selector(copyAction)),
            menuItem("移动到指定文件夹", #selector(moveAction)),
            menuItem("删除", #selector(deleteAction), key: "\u{8}")
        ]))
        main.addItem(menu(title: "视图", items: [
            menuItem("上级目录", #selector(upAction), key: "\u{F700}"),
            menuItem("刷新", #selector(reloadAction), key: "r"),
            .separator(),
            menuItem("显示或隐藏工具栏", #selector(toggleToolbarAction), key: "t", modifiers: [.command, .option])
        ]))
        main.addItem(menu(title: "同步", items: [
            menuItem("配置自动同步", #selector(configureSyncAction)),
            menuItem("立即同步", #selector(syncAction))
        ]))
        main.addItem(menu(title: "帮助", items: [
            menuItem("中文使用说明", #selector(showChineseReadme))
        ]))
        NSApp.mainMenu = main
    }

    private func applicationMenu() -> NSMenuItem {
        let item = NSMenuItem(title: "CloudShelf", action: nil, keyEquivalent: "")
        let app = NSMenu(title: "CloudShelf")
        app.addItem(menuItem("关于 CloudShelf", #selector(showAbout)))
        app.addItem(.separator())
        let quit = NSMenuItem(title: "退出 CloudShelf", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        app.addItem(quit)
        item.submenu = app
        return item
    }

    private func menu(title: String, items: [NSMenuItem]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: title)
        items.forEach(submenu.addItem)
        item.submenu = submenu
        return item
    }

    private func menuItem(
        _ title: String,
        _ action: Selector,
        key: String = "",
        modifiers: NSEvent.ModifierFlags = [.command]
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = self
        return item
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarDefaultItemIdentifiers(toolbar) }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            NSToolbarItem.Identifier("add"), NSToolbarItem.Identifier("edit"), .flexibleSpace,
            NSToolbarItem.Identifier("up"), NSToolbarItem.Identifier("reload"), NSToolbarItem.Identifier("folder"),
            NSToolbarItem.Identifier("upload"), NSToolbarItem.Identifier("download"), NSToolbarItem.Identifier("copy"),
            NSToolbarItem.Identifier("move"), NSToolbarItem.Identifier("delete"), NSToolbarItem.Identifier("sync")
        ]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        switch itemIdentifier.rawValue {
        case "add": item.label = "新建连接"; item.toolTip = "新建连接"; item.image = symbol("plus"); item.target = self; item.action = #selector(addAction)
        case "edit": item.label = "编辑"; item.toolTip = "编辑所选连接"; item.image = symbol("slider.horizontal.3"); item.target = self; item.action = #selector(editAction)
        case "up": item.label = "上级"; item.toolTip = "返回上级目录"; item.image = symbol("arrow.up"); item.target = self; item.action = #selector(upAction)
        case "reload": item.label = "刷新"; item.toolTip = "刷新当前目录"; item.image = symbol("arrow.clockwise"); item.target = self; item.action = #selector(reloadAction)
        case "folder": item.label = "新建文件夹"; item.toolTip = "新建文件夹"; item.image = symbol("folder.badge.plus"); item.target = self; item.action = #selector(folderAction)
        case "upload": item.label = "上传"; item.toolTip = "上传文件或文件夹"; item.image = symbol("arrow.up.doc"); item.target = self; item.action = #selector(uploadAction)
        case "download": item.label = "下载"; item.toolTip = "下载所选文件"; item.image = symbol("arrow.down.doc"); item.target = self; item.action = #selector(downloadAction)
        case "copy": item.label = "复制"; item.toolTip = "复制到指定文件夹"; item.image = symbol("doc.on.doc"); item.target = self; item.action = #selector(copyAction)
        case "move": item.label = "移动"; item.toolTip = "移动到指定文件夹"; item.image = symbol("folder.badge.gearshape"); item.target = self; item.action = #selector(moveAction)
        case "delete": item.label = "删除"; item.toolTip = "删除所选文件"; item.image = symbol("trash"); item.target = self; item.action = #selector(deleteAction)
        case "sync": item.label = "同步"; item.toolTip = "配置或执行自动同步"; item.image = symbol("arrow.triangle.2.circlepath"); item.target = self; item.action = #selector(syncAction)
        default: return nil
        }
        return item
    }

    @objc fileprivate func addAction() { addConnection() }
    @objc fileprivate func editAction() { editConnection() }
    @objc fileprivate func connectAction() { connectSelected() }
    @objc fileprivate func disconnectAction() { disconnectSelected() }
    @objc fileprivate func upAction() { goUp() }
    @objc fileprivate func reloadAction() { reloadFolder() }
    @objc fileprivate func folderAction() { newFolder() }
    @objc fileprivate func uploadAction() { chooseUploads() }
    @objc fileprivate func downloadAction() { chooseDownloads() }
    @objc fileprivate func renameAction() { rename() }
    @objc fileprivate func cutSelectionAction() { cutSelection() }
    @objc fileprivate func copySelectionAction() { copySelection() }
    @objc fileprivate func pasteSelectionAction() { pasteSelection() }
    @objc fileprivate func selectAllAction() { selectAll() }
    @objc fileprivate func copyAction() { copyItems() }
    @objc fileprivate func moveAction() { moveItems() }
    @objc fileprivate func deleteAction() { deleteItems() }
    @objc fileprivate func propertiesAction() { showProperties() }
    @objc fileprivate func syncAction() { runSync() }
    @objc fileprivate func configureSyncAction() { configureSync() }
    @objc fileprivate func toggleToolbarAction() { window?.toggleToolbarShown(self) }

    @objc private func showAbout() {
        let alert = NSAlert()
        alert.messageText = "CloudShelf"
        alert.informativeText = "远程文件工作区。"
        alert.runModal()
    }

    @objc private func showChineseReadme() {
        let alert = NSAlert()
        alert.messageText = "CloudShelf 使用说明"
        alert.informativeText = "1. 选择“连接 > 新建连接”添加服务器。\n2. 在左侧选择服务器并浏览文件。\n3. 使用“文件”菜单上传、下载、移动、复制或删除。\n4. 使用“同步”菜单设置本地文件夹的自动同步。\n\n完整中文说明位于项目目录的 README.zh-CN.md。"
        alert.runModal()
    }

    private func presentForm(title: String, form: NSView, actionTitle: String, completion: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.accessoryView = form
        alert.addButton(withTitle: actionTitle)
        alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window!) { response in if response == .alertFirstButtonReturn { completion() } }
    }

    private func prompt(title: String, message: String, placeholder: String, value: String = "", completion: @escaping (String) -> Void) {
        let input = NSTextField(string: value)
        input.placeholderString = placeholder
        input.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.accessoryView = input
        alert.addButton(withTitle: "继续")
        alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window!) { response in
            let value = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if response == .alertFirstButtonReturn, !value.isEmpty { completion(value) }
        }
    }

    private func cell(identifier: NSUserInterfaceItemIdentifier, text: String, image: NSImage?) -> NSTableCellView {
        let reusable = browserTable.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
        let view = reusable ?? NSTableCellView()
        if view.identifier == nil {
            view.identifier = identifier
            let textField = NSTextField(labelWithString: "")
            textField.translatesAutoresizingMaskIntoConstraints = false
            view.textField = textField
            view.addSubview(textField)
            if image != nil {
                let imageView = NSImageView()
                imageView.translatesAutoresizingMaskIntoConstraints = false
                imageView.imageScaling = .scaleProportionallyDown
                view.imageView = imageView
                view.addSubview(imageView)
                NSLayoutConstraint.activate([
                    imageView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 4),
                    imageView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
                    imageView.widthAnchor.constraint(equalToConstant: 17),
                    imageView.heightAnchor.constraint(equalToConstant: 17),
                    textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 7)
                ])
            } else {
                textField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 4).isActive = true
            }
            NSLayoutConstraint.activate([
                textField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -4),
                textField.centerYAnchor.constraint(equalTo: view.centerYAnchor)
            ])
        }
        view.textField?.stringValue = text
        view.imageView?.image = image
        return view
    }

    private func transferProgressCell(_ transfer: TransferTask) -> NSTableCellView {
        let identifier = NSUserInterfaceItemIdentifier("transfer-progress")
        let reusable = transferTable.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
        let view = reusable ?? NSTableCellView()
        if view.identifier == nil {
            view.identifier = identifier
            let progress = NSProgressIndicator()
            progress.translatesAutoresizingMaskIntoConstraints = false
            progress.style = .bar
            progress.controlSize = .small
            progress.identifier = NSUserInterfaceItemIdentifier("progress-indicator")
            let label = NSTextField(labelWithString: "")
            label.translatesAutoresizingMaskIntoConstraints = false
            label.alignment = .right
            label.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            label.identifier = NSUserInterfaceItemIdentifier("progress-label")
            view.addSubview(progress)
            view.addSubview(label)
            NSLayoutConstraint.activate([
                progress.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 4),
                progress.centerYAnchor.constraint(equalTo: view.centerYAnchor),
                progress.trailingAnchor.constraint(equalTo: label.leadingAnchor, constant: -8),
                label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -4),
                label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
                label.widthAnchor.constraint(equalToConstant: 42)
            ])
        }

        let progress = view.subviews.compactMap { $0 as? NSProgressIndicator }.first
        let label = view.subviews.compactMap { $0 as? NSTextField }.first
        if let total = transfer.totalBytes, total > 0 {
            progress?.stopAnimation(nil)
            progress?.isIndeterminate = false
            progress?.minValue = 0
            progress?.maxValue = Double(total)
            progress?.doubleValue = Double(min(transfer.completedBytes, total))
            label?.stringValue = "\(Int((Double(transfer.completedBytes) / Double(total)) * 100))%"
        } else if transfer.status == .running {
            progress?.isIndeterminate = true
            progress?.startAnimation(nil)
            label?.stringValue = "处理中"
        } else {
            progress?.stopAnimation(nil)
            progress?.isIndeterminate = false
            progress?.minValue = 0
            progress?.maxValue = 1
            progress?.doubleValue = transfer.status == .succeeded ? 1 : 0
            label?.stringValue = transfer.status == .succeeded ? "完成" : "-"
        }
        return view
    }

    private func transferSpeedDescription(_ transfer: TransferTask) -> String {
        guard let speed = transfer.bytesPerSecond, speed > 0 else { return "-" }
        return "\(ByteCountFormatter.string(fromByteCount: Int64(speed), countStyle: .file))/秒"
    }

    private func symbol(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)
    }
}

@MainActor
private final class RemoteItemPropertiesWindowController: NSWindowController {
    private let item: RemoteItem
    private let connectionName: String
    private let protocolName: String
    private let client: any RemoteClient
    private let sizeValue = NSTextField(labelWithString: "")
    private var sizeTask: Task<Void, Never>?

    private lazy var calculateSizeButton: NSButton = {
        let button = NSButton(title: "计算文件夹大小", target: self, action: #selector(calculateFolderSize))
        button.bezelStyle = .rounded
        return button
    }()

    init(item: RemoteItem, connectionName: String, protocolName: String, client: any RemoteClient) {
        self.item = item
        self.connectionName = connectionName
        self.protocolName = protocolName
        self.client = client
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 320),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "属性 - \(item.name)"
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        super.init(window: panel)
        panel.contentView = makeContentView(panel: panel)
    }

    required init?(coder: NSCoder) { nil }

    deinit { sizeTask?.cancel() }

    private func makeContentView(panel: NSPanel) -> NSView {
        let root = NSView()
        let image = NSImageView(image: NSImage(systemSymbolName: item.isDirectory ? "folder.fill" : "doc", accessibilityDescription: nil) ?? NSImage())
        image.contentTintColor = item.isDirectory ? .systemBlue : .secondaryLabelColor
        image.imageScaling = .scaleProportionallyDown
        image.translatesAutoresizingMaskIntoConstraints = false
        image.widthAnchor.constraint(equalToConstant: 34).isActive = true
        image.heightAnchor.constraint(equalToConstant: 34).isActive = true

        let title = NSTextField(labelWithString: item.name)
        title.font = NSFont.systemFont(ofSize: 16, weight: .semibold)
        title.lineBreakMode = .byTruncatingMiddle
        let subtitle = NSTextField(labelWithString: typeDescription)
        subtitle.font = NSFont.systemFont(ofSize: 12)
        subtitle.textColor = .secondaryLabelColor
        let titleStack = NSStackView(views: [title, subtitle])
        titleStack.orientation = .vertical
        titleStack.spacing = 2
        let header = NSStackView(views: [image, titleStack])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 12

        sizeValue.stringValue = item.isDirectory ? "尚未计算" : byteCount(item.size)
        let details = NSStackView(views: [
            detailRow("名称", item.name),
            detailRow("类型", typeDescription),
            detailRow("位置", item.path),
            detailRow("大小", valueField: sizeValue),
            detailRow("修改日期", item.modifiedAt?.formatted(date: .long, time: .shortened) ?? "服务器未提供"),
            detailRow("连接", "\(connectionName)（\(protocolName)）")
        ])
        details.orientation = .vertical
        details.spacing = 8

        let closeButton = NSButton(title: "关闭", target: panel, action: #selector(NSWindow.performClose(_:)))
        closeButton.bezelStyle = .rounded
        let actions = NSStackView()
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.addArrangedSubview(item.isDirectory ? calculateSizeButton : NSView())
        actions.addArrangedSubview(NSView())
        actions.addArrangedSubview(closeButton)
        actions.arrangedSubviews[1].setContentHuggingPriority(.defaultLow, for: .horizontal)
        actions.arrangedSubviews[1].setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [header, details, actions])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -22),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            details.widthAnchor.constraint(equalTo: stack.widthAnchor),
            actions.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        return root
    }

    private var typeDescription: String {
        guard !item.isDirectory else { return "文件夹" }
        return item.fileExtension.isEmpty ? "文件" : "\(item.fileExtension.uppercased()) 文件"
    }

    private func detailRow(_ label: String, _ value: String) -> NSStackView {
        let valueField = NSTextField(wrappingLabelWithString: value)
        valueField.lineBreakMode = .byTruncatingMiddle
        return detailRow(label, valueField: valueField)
    }

    private func detailRow(_ label: String, valueField: NSTextField) -> NSStackView {
        let labelField = NSTextField(labelWithString: label)
        labelField.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        labelField.textColor = .secondaryLabelColor
        labelField.alignment = .right
        labelField.widthAnchor.constraint(equalToConstant: 78).isActive = true
        valueField.font = NSFont.systemFont(ofSize: 12)
        valueField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [labelField, valueField])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 12
        return row
    }

    @objc private func calculateFolderSize() {
        guard item.isDirectory, sizeTask == nil else { return }
        sizeValue.stringValue = "正在计算…"
        calculateSizeButton.isEnabled = false
        sizeTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await Self.directorySize(at: self.item.path, client: self.client)
                guard !Task.isCancelled else { return }
                self.sizeValue.stringValue = ByteCountFormatter.string(fromByteCount: result.bytes, countStyle: .file)
                    + "（\(result.entries) 项）"
                    + (result.itemsWithoutSize == 0 ? "" : "，\(result.itemsWithoutSize) 项未提供大小")
            } catch is CancellationError {
                return
            } catch {
                self.sizeValue.stringValue = "无法计算：\(error.localizedDescription)"
            }
            self.calculateSizeButton.isEnabled = true
            self.sizeTask = nil
        }
    }

    nonisolated private static func directorySize(
        at rootPath: String,
        client: any RemoteClient
    ) async throws -> (bytes: Int64, entries: Int, itemsWithoutSize: Int) {
        var pendingPaths = [rootPath]
        var visitedPaths = Set([rootPath])
        var bytes: Int64 = 0
        var entries = 0
        var itemsWithoutSize = 0

        while let path = pendingPaths.popLast() {
            try Task.checkCancellation()
            for child in try await client.list(at: path) {
                try Task.checkCancellation()
                entries += 1
                guard entries <= 100_000 else {
                    throw CloudShelfError.commandFailed("文件夹包含超过 100,000 项，已停止计算大小。")
                }
                if child.isDirectory {
                    if visitedPaths.insert(child.path).inserted { pendingPaths.append(child.path) }
                } else if let size = child.size {
                    guard size <= Int64.max - bytes else {
                        throw CloudShelfError.commandFailed("文件夹大小超出可显示范围。")
                    }
                    bytes += size
                } else {
                    itemsWithoutSize += 1
                }
            }
        }
        return (bytes, entries, itemsWithoutSize)
    }

    private func byteCount(_ bytes: Int64?) -> String {
        bytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "服务器未提供"
    }
}

@MainActor
private final class FileManagerViewController: NSViewController {
    private unowned let owner: FileManagerWindowController

    init(owner: FileManagerWindowController) {
        self.owner = owner
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let root = NSView()
        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(split)
        NSLayoutConstraint.activate([
            split.leadingAnchor.constraint(equalTo: root.leadingAnchor), split.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            split.topAnchor.constraint(equalTo: root.topAnchor), split.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])

        let sidebar = makeSidebar()
        let content = makeContent()
        split.addArrangedSubview(sidebar)
        split.addArrangedSubview(content)
        split.setPosition(255, ofDividerAt: 0)
        self.view = root
    }

    private func makeSidebar() -> NSView {
        let container = NSView()
        let title = NSTextField(labelWithString: "连接")
        title.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        title.textColor = .secondaryLabelColor
        let scroll = scrollView(for: owner.connectionTable)
        owner.connectionTable.delegate = owner
        owner.connectionTable.dataSource = owner
        owner.connectionTable.headerView = nil
        owner.connectionTable.rowHeight = 38
        owner.connectionTable.addTableColumn(column("connection", title: "名称", width: 175))
        owner.connectionTable.addTableColumn(column("protocol", title: "协议", width: 70))
        let button = NSButton(title: "新建连接", target: owner, action: #selector(FileManagerWindowController.addAction))
        button.bezelStyle = .rounded
        let remove = NSButton(title: "移除", target: owner, action: #selector(FileManagerWindowController.removeConnection))
        remove.bezelStyle = .rounded
        let row = NSStackView(views: [button, remove])
        row.orientation = .horizontal
        row.spacing = 8
        let stack = NSStackView(views: [title, scroll, row])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14), stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 14), stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        return container
    }

    private func makeContent() -> NSView {
        let container = NSView()
        owner.pathLabel.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        owner.pathLabel.lineBreakMode = .byTruncatingMiddle
        owner.connectionStatus.font = NSFont.systemFont(ofSize: 12)
        owner.connectionStatus.textColor = .secondaryLabelColor
        let top = NSStackView(views: [owner.pathLabel, NSView(), owner.connectionStatus])
        top.orientation = .horizontal
        top.alignment = .centerY
        top.translatesAutoresizingMaskIntoConstraints = false
        let browserScroll = scrollView(for: owner.browserTable)
        owner.browserTable.delegate = owner
        owner.browserTable.dataSource = owner
        owner.browserTable.rowHeight = 28
        owner.browserTable.target = owner
        owner.browserTable.doubleAction = #selector(FileManagerWindowController.openSelectedItem)
        owner.browserTable.registerForDraggedTypes([.fileURL])
        owner.browserTable.addTableColumn(column("name", title: "名称", width: 380))
        owner.browserTable.addTableColumn(column("modified", title: "修改时间", width: 160))
        owner.browserTable.addTableColumn(column("size", title: "大小", width: 95))
        owner.browserTable.addTableColumn(column("type", title: "类型", width: 110))
        let transferTitle = NSTextField(labelWithString: "传输")
        transferTitle.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        transferTitle.textColor = .secondaryLabelColor
        let transferScroll = scrollView(for: owner.transferTable)
        owner.transferTable.delegate = owner
        owner.transferTable.dataSource = owner
        owner.transferTable.headerView = nil
        owner.transferTable.rowHeight = 27
        owner.transferTable.addTableColumn(column("transfer", title: "任务", width: 185))
        owner.transferTable.addTableColumn(column("state", title: "状态", width: 315))
        owner.transferTable.addTableColumn(column("progress", title: "进度", width: 165))
        owner.transferTable.addTableColumn(column("speed", title: "速率", width: 115))
        let stack = NSStackView(views: [top, browserScroll, transferTitle, transferScroll])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 9
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14), stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 12), stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
            top.widthAnchor.constraint(equalTo: stack.widthAnchor), browserScroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            transferScroll.widthAnchor.constraint(equalTo: stack.widthAnchor), browserScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 300),
            transferScroll.heightAnchor.constraint(equalToConstant: 130)
        ])
        return container
    }

    private func scrollView(for table: NSTableView) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = table
        return scroll
    }

    private func column(_ id: String, title: String, width: CGFloat) -> NSTableColumn {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
        column.title = title
        column.width = width
        column.minWidth = id == "name" ? 180 : 65
        return column
    }
}

private final class ConnectionForm: NSView {
    private let name = NSTextField(string: "")
    private let protocolBox = NSPopUpButton()
    private let serverURL = NSTextField(string: "")
    private let username = NSTextField(string: "")
    private let authentication = NSPopUpButton()
    private let secretField = NSSecureTextField(string: "")
    private let keyPath = NSTextField(string: "")
    private let hostKeyPolicy = NSPopUpButton()
    private let authenticationTitles = ["密码", "SSH Agent", "私钥"]
    private let hostKeyTitles = ["严格校验", "首次接受新密钥"]

    var secret: String? {
        let value = secretField.stringValue
        return value.isEmpty ? nil : value
    }

    var validationError: String? {
        guard !name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "请填写连接名称。"
        }
        guard let protocolType = RemoteProtocol(rawValue: protocolBox.titleOfSelectedItem ?? "") else {
            return "请选择连接协议。"
        }
        return Self.urlValidationError(serverURL.stringValue, for: protocolType)
    }

    init(profile: ConnectionProfile? = nil) {
        super.init(frame: NSRect(x: 0, y: 0, width: 440, height: 272))
        protocolBox.addItems(withTitles: RemoteProtocol.allCases.map(\.rawValue))
        protocolBox.target = self
        protocolBox.action = #selector(protocolChanged)
        authentication.addItems(withTitles: authenticationTitles)
        hostKeyPolicy.addItems(withTitles: hostKeyTitles)
        serverURL.toolTip = "请输入包含协议、主机、端口和路径的完整 URL。"
        secretField.placeholderString = profile == nil ? "输入密码" : "留空则保留已保存的密码"
        secretField.toolTip = "为保护密码，编辑连接时不会显示钥匙串中的现有密码。"
        layout(rows: [
            ("名称", name), ("协议", protocolBox), ("服务器 URL", serverURL), ("用户名", username),
            ("认证方式", authentication), (profile == nil ? "密码" : "密码（留空不改）", secretField),
            ("私钥路径", keyPath), ("主机密钥", hostKeyPolicy)
        ])
        if let profile {
            name.stringValue = profile.name
            protocolBox.selectItem(withTitle: profile.protocolType.rawValue)
            serverURL.stringValue = Self.urlString(for: profile)
            username.stringValue = profile.username
            authentication.selectItem(at: Self.authenticationIndex(profile.authentication))
            keyPath.stringValue = profile.privateKeyPath ?? ""
            hostKeyPolicy.selectItem(at: Self.hostKeyIndex(profile.hostKeyPolicy))
        } else {
            protocolBox.selectItem(withTitle: RemoteProtocol.sftp.rawValue)
            hostKeyPolicy.selectItem(at: Self.hostKeyIndex(.acceptNew))
        }
        updateURLPresentation()
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize { NSSize(width: 440, height: 272) }

    func profile(existing: ConnectionProfile? = nil) -> ConnectionProfile? {
        guard let protocolType = RemoteProtocol(rawValue: protocolBox.titleOfSelectedItem ?? ""),
              let method = Self.authentication(at: authentication.indexOfSelectedItem),
              let keyPolicy = Self.hostKeyPolicy(at: hostKeyPolicy.indexOfSelectedItem),
              validationError == nil else { return nil }
        let address = serverURL.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return ConnectionProfile(
            id: existing?.id ?? UUID(), name: name.stringValue, protocolType: protocolType, host: address,
            port: protocolType.defaultPort, username: username.stringValue, basePath: "/",
            authentication: protocolType == .sftp ? method : .password,
            privateKeyPath: keyPath.stringValue.isEmpty ? nil : keyPath.stringValue,
            useTLS: protocolType.defaultTLS, hostKeyPolicy: keyPolicy,
            createdAt: existing?.createdAt ?? .now, syncRules: existing?.syncRules ?? []
        )
    }

    private func layout(rows: [(String, NSView)]) {
        let views = rows.map { label, field -> [NSView] in
            let text = NSTextField(labelWithString: label)
            text.alignment = .right
            return [text, field]
        }
        let grid = NSGridView(views: views)
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 8
        grid.columnSpacing = 10
        grid.xPlacement = .fill
        grid.yPlacement = .center
        grid.column(at: 0).width = 110
        grid.column(at: 1).width = 300
        addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: leadingAnchor), grid.trailingAnchor.constraint(equalTo: trailingAnchor),
            grid.topAnchor.constraint(equalTo: topAnchor), grid.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    @objc private func protocolChanged() {
        updateURLPresentation()
    }

    private func updateURLPresentation() {
        guard let type = RemoteProtocol(rawValue: protocolBox.titleOfSelectedItem ?? "") else { return }
        switch type {
        case .ftp:
            serverURL.placeholderString = "ftp://files.example.com:21/目录"
        case .sftp:
            serverURL.placeholderString = "sftp://files.example.com:22/目录"
        case .webDAV:
            serverURL.placeholderString = "http://[IPv6]:5244/dav"
        }
    }

    private static func urlValidationError(_ value: String, for protocolType: RemoteProtocol) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              let host = components.host, !host.isEmpty,
              components.query == nil, components.fragment == nil else {
            return "请输入包含协议和主机的完整服务器 URL。"
        }
        guard components.password == nil else {
            return "请在密码字段填写密码，不要把密码写入 URL。"
        }
        switch protocolType {
        case .ftp:
            return (scheme == "ftp" || scheme == "ftps") ? nil : "FTP 连接请使用 ftp:// 或 ftps:// URL。"
        case .sftp:
            return scheme == "sftp" ? nil : "SFTP 连接请使用 sftp:// URL。"
        case .webDAV:
            return (scheme == "http" || scheme == "https") ? nil : "WebDAV 连接请使用 http:// 或 https:// URL。"
        }
    }

    private static func urlString(for profile: ConnectionProfile) -> String {
        let stored = profile.host.trimmingCharacters(in: .whitespacesAndNewlines)
        if stored.contains("://") { return stored }

        var components = URLComponents()
        switch profile.protocolType {
        case .ftp: components.scheme = profile.useTLS ? "ftps" : "ftp"
        case .sftp: components.scheme = "sftp"
        case .webDAV: components.scheme = profile.useTLS ? "https" : "http"
        }
        components.host = stored
        components.port = profile.port
        components.path = profile.basePath
        return components.url?.absoluteString ?? stored
    }

    private static func authenticationIndex(_ method: AuthenticationMethod) -> Int {
        switch method {
        case .password: return 0
        case .sshAgent: return 1
        case .privateKey: return 2
        }
    }

    private static func authentication(at index: Int) -> AuthenticationMethod? {
        switch index {
        case 0: return .password
        case 1: return .sshAgent
        case 2: return .privateKey
        default: return nil
        }
    }

    private static func hostKeyIndex(_ policy: HostKeyPolicy) -> Int {
        switch policy {
        case .strict: return 0
        case .acceptNew: return 1
        }
    }

    private static func hostKeyPolicy(at index: Int) -> HostKeyPolicy? {
        switch index {
        case 0: return .strict
        case 1: return .acceptNew
        default: return nil
        }
    }
}

@MainActor
private final class SyncRulesWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private let profile: ConnectionProfile
    private let client: any RemoteClient
    private let saveRules: ([SyncRule]) -> Void
    private let runRule: (UUID) -> Void
    private let table = NSTableView()
    private var rules: [SyncRule]
    private var ruleEditor: SyncRuleEditorWindowController?

    init(
        profile: ConnectionProfile,
        session: RemoteSession,
        saveRules: @escaping ([SyncRule]) -> Void,
        runRule: @escaping (UUID) -> Void
    ) {
        self.profile = profile
        self.client = session.client
        self.rules = profile.syncRules
        self.saveRules = saveRules
        self.runRule = runRule
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 470),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "同步管理 - \(profile.name)"
        super.init(window: window)
        window.contentView = makeContentView(window: window)
    }

    required init?(coder: NSCoder) { nil }

    func numberOfRows(in tableView: NSTableView) -> Int { rules.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row >= 0, row < rules.count else { return nil }
        let rule = rules[row]
        let identifier = tableColumn?.identifier.rawValue ?? ""
        let text: String
        switch identifier {
        case "local": text = rule.localFolder
        case "remote": text = rule.remoteFolder
        case "direction": text = syncActionsText(rule)
        case "schedule":
            let changeMode = rule.syncOnLocalChanges == true ? "变更后自动" : ""
            text = changeMode.isEmpty ? "每 \(rule.intervalMinutes) 分钟" : "\(changeMode) + 每 \(rule.intervalMinutes) 分钟"
        case "state": text = rule.isEnabled ? "已启用" : "已停用"
        case "last": text = rule.lastSyncedAt?.formatted(date: .abbreviated, time: .shortened) ?? "从未"
        default: text = ""
        }
        return textCell(identifier: NSUserInterfaceItemIdentifier("sync-\(identifier)"), text: text)
    }

    func tableViewSelectionDidChange(_ notification: Notification) { }

    @objc private func addRule() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "选择本地文件夹"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let localFolder = panel.url?.path, let self else { return }
            self.openRuleEditor(localFolder: localFolder, existing: nil, index: nil)
        }
    }

    @objc private func editRule() {
        let row = table.selectedRow
        guard row >= 0, row < rules.count else { return }
        openRuleEditor(localFolder: rules[row].localFolder, existing: rules[row], index: row)
    }

    @objc private func removeRule() {
        let row = table.selectedRow
        guard row >= 0, row < rules.count else { return }
        rules.remove(at: row)
        persistRules()
        table.reloadData()
    }

    @objc private func toggleRule() {
        let row = table.selectedRow
        guard row >= 0, row < rules.count else { return }
        rules[row].isEnabled.toggle()
        persistRules()
        table.reloadData()
    }

    @objc private func runSelectedRule() {
        let row = table.selectedRow
        guard row >= 0, row < rules.count, rules[row].isEnabled else { return }
        runRule(rules[row].id)
    }

    private func openRuleEditor(localFolder: String, existing: SyncRule?, index: Int?) {
        ruleEditor?.close()
        let editor = SyncRuleEditorWindowController(
            localFolder: localFolder,
            existing: existing,
            client: client,
            saveRule: { [weak self] rule in
                guard let self else { return }
                if let index { self.rules[index] = rule } else { self.rules.append(rule) }
                self.persistRules()
                self.table.reloadData()
            }
        )
        ruleEditor = editor
        editor.showWindow(nil)
        editor.window?.makeKeyAndOrderFront(nil)
    }

    private func persistRules() { saveRules(rules) }

    private func makeContentView(window: NSWindow) -> NSView {
        table.delegate = self
        table.dataSource = self
        table.rowHeight = 30
        table.addTableColumn(column("local", title: "本地文件夹", width: 210))
        table.addTableColumn(column("remote", title: "远端文件夹", width: 135))
        table.addTableColumn(column("direction", title: "同步操作", width: 220))
        table.addTableColumn(column("schedule", title: "执行方式", width: 145))
        table.addTableColumn(column("state", title: "状态", width: 70))
        table.addTableColumn(column("last", title: "上次同步", width: 120))
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = table

        let add = NSButton(title: "添加规则", target: self, action: #selector(addRule))
        let edit = NSButton(title: "编辑", target: self, action: #selector(editRule))
        let remove = NSButton(title: "移除", target: self, action: #selector(removeRule))
        let toggle = NSButton(title: "启用/停用", target: self, action: #selector(toggleRule))
        let run = NSButton(title: "立即执行", target: self, action: #selector(runSelectedRule))
        let close = NSButton(title: "完成", target: window, action: #selector(NSWindow.performClose(_:)))
        [add, edit, remove, toggle, run, close].forEach { $0.bezelStyle = .rounded }
        let controls = NSStackView(views: [add, edit, remove, toggle, run, NSView(), close])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 8
        controls.arrangedSubviews[5].setContentHuggingPriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [scroll, controls])
        stack.orientation = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        let root = NSView()
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            controls.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        return root
    }

    private func column(_ id: String, title: String, width: CGFloat) -> NSTableColumn {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
        column.title = title
        column.width = width
        column.minWidth = 60
        return column
    }

    private func textCell(identifier: NSUserInterfaceItemIdentifier, text: String) -> NSTableCellView {
        let reusable = table.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
        let view = reusable ?? NSTableCellView()
        if view.identifier == nil {
            view.identifier = identifier
            let textField = NSTextField(labelWithString: "")
            textField.translatesAutoresizingMaskIntoConstraints = false
            textField.lineBreakMode = .byTruncatingMiddle
            view.textField = textField
            view.addSubview(textField)
            NSLayoutConstraint.activate([
                textField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 4),
                textField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -4),
                textField.centerYAnchor.constraint(equalTo: view.centerYAnchor)
            ])
        }
        view.textField?.stringValue = text
        return view
    }

    private func syncActionsText(_ rule: SyncRule) -> String {
        var actions: [String] = []
        if rule.uploadsLocalChanges { actions.append("本地上传") }
        if rule.downloadsRemoteChanges { actions.append("远端下载") }
        if rule.propagatesLocalDeletes { actions.append("本地删除 -> 远端") }
        if rule.propagatesRemoteDeletes { actions.append("远端删除 -> 本地") }
        return actions.isEmpty ? "未选择" : actions.joined(separator: "、")
    }
}

@MainActor
private final class SyncRuleEditorWindowController: NSWindowController {
    private let localFolder: String
    private let existing: SyncRule?
    private let client: any RemoteClient
    private let saveRule: (SyncRule) -> Void
    private let remote = NSTextField(string: "/")
    private let interval = NSPopUpButton()
    private let uploadLocalChanges = NSButton(checkboxWithTitle: "本地新增和修改上传到远端", target: nil, action: nil)
    private let downloadRemoteChanges = NSButton(checkboxWithTitle: "远端新增和修改下载到本地", target: nil, action: nil)
    private let deleteRemoteWhenLocalDeleted = NSButton(checkboxWithTitle: "本地删除时删除远端对应项目", target: nil, action: nil)
    private let deleteLocalWhenRemoteDeleted = NSButton(checkboxWithTitle: "远端删除时删除本地对应项目", target: nil, action: nil)
    private let watchChanges = NSButton(checkboxWithTitle: "检测到本地文件夹变化后自动同步", target: nil, action: nil)
    private var folderPicker: RemoteFolderPickerWindowController?

    init(localFolder: String, existing: SyncRule?, client: any RemoteClient, saveRule: @escaping (SyncRule) -> Void) {
        self.localFolder = localFolder
        self.existing = existing
        self.client = client
        self.saveRule = saveRule
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 345),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = existing == nil ? "添加同步规则" : "编辑同步规则"
        super.init(window: window)
        interval.addItems(withTitles: ["5 分钟", "15 分钟", "30 分钟", "1 小时"])
        applyExistingRule()
        window.contentView = makeContentView(window: window)
    }

    required init?(coder: NSCoder) { nil }

    @objc private func chooseRemoteFolder() {
        folderPicker?.close()
        let picker = RemoteFolderPickerWindowController(client: client, initialPath: remote.stringValue) { [weak self] path in
            self?.remote.stringValue = path
        }
        folderPicker = picker
        picker.showWindow(nil)
        picker.window?.makeKeyAndOrderFront(nil)
    }

    @objc private func save() {
        let local = localFolder.trimmingCharacters(in: .whitespacesAndNewlines)
        let remoteFolder = remote.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !local.isEmpty, !remoteFolder.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "请填写本地和远端文件夹。"
            alert.beginSheetModal(for: window!) { _ in }
            return
        }
        let uploadsLocal = uploadLocalChanges.state == .on
        let downloadsRemote = downloadRemoteChanges.state == .on
        let deletesRemote = deleteRemoteWhenLocalDeleted.state == .on
        let deletesLocal = deleteLocalWhenRemoteDeleted.state == .on
        guard uploadsLocal || downloadsRemote || deletesRemote || deletesLocal else {
            let alert = NSAlert()
            alert.messageText = "请至少选择一项同步操作。"
            alert.beginSheetModal(for: window!) { _ in }
            return
        }
        let directionValue: SyncDirection = uploadsLocal && downloadsRemote ? .bidirectional : downloadsRemote ? .downloadOnly : .uploadOnly
        let minutes = [5, 15, 30, 60][max(0, interval.indexOfSelectedItem)]
        let rule = SyncRule(
            id: existing?.id ?? UUID(),
            localFolder: local,
            remoteFolder: remoteFolder,
            direction: directionValue,
            conflictPolicy: existing?.conflictPolicy ?? .keepNewest,
            intervalMinutes: minutes,
            isEnabled: existing?.isEnabled ?? true,
            syncOnLocalChanges: watchChanges.state == .on,
            uploadLocalChanges: uploadsLocal,
            downloadRemoteChanges: downloadsRemote,
            deleteRemoteWhenLocalDeleted: deletesRemote,
            deleteLocalWhenRemoteDeleted: deletesLocal,
            lastSyncedAt: existing?.lastSyncedAt
        )
        saveRule(rule)
        close()
    }

    private func applyExistingRule() {
        guard let existing else {
            interval.selectItem(at: 1)
            uploadLocalChanges.state = .on
            return
        }
        remote.stringValue = existing.remoteFolder
        uploadLocalChanges.state = existing.uploadsLocalChanges ? .on : .off
        downloadRemoteChanges.state = existing.downloadsRemoteChanges ? .on : .off
        deleteRemoteWhenLocalDeleted.state = existing.propagatesLocalDeletes ? .on : .off
        deleteLocalWhenRemoteDeleted.state = existing.propagatesRemoteDeletes ? .on : .off
        let intervalIndex = [5, 15, 30, 60].firstIndex(of: existing.intervalMinutes) ?? 1
        interval.selectItem(at: intervalIndex)
        watchChanges.state = existing.syncOnLocalChanges == true ? .on : .off
    }

    private func makeContentView(window: NSWindow) -> NSView {
        let local = NSTextField(labelWithString: localFolder)
        local.lineBreakMode = .byTruncatingMiddle
        let remotePicker = NSButton(title: "选择…", target: self, action: #selector(chooseRemoteFolder))
        remotePicker.bezelStyle = .rounded
        let remoteRow = NSStackView(views: [remote, remotePicker])
        remoteRow.orientation = .horizontal
        remoteRow.spacing = 8
        let syncActions = NSStackView(views: [
            uploadLocalChanges,
            downloadRemoteChanges,
            deleteRemoteWhenLocalDeleted,
            deleteLocalWhenRemoteDeleted
        ])
        syncActions.orientation = .vertical
        syncActions.alignment = .leading
        syncActions.spacing = 6
        let fields: [(String, NSView)] = [
            ("本地文件夹", local),
            ("远端文件夹", remoteRow),
            ("同步操作", syncActions),
            ("执行频率", interval),
            ("自动同步", watchChanges)
        ]
        let grid = NSGridView(views: fields.map { label, field in
            let labelField = NSTextField(labelWithString: label)
            labelField.alignment = .right
            return [labelField, field]
        })
        grid.rowSpacing = 10
        grid.columnSpacing = 12
        grid.xPlacement = .fill
        grid.yPlacement = .center
        grid.column(at: 0).width = 95
        grid.column(at: 1).width = 360

        let save = NSButton(title: "保存", target: self, action: #selector(save))
        save.bezelStyle = .rounded
        let cancel = NSButton(title: "取消", target: window, action: #selector(NSWindow.performClose(_:)))
        cancel.bezelStyle = .rounded
        let actions = NSStackView(views: [NSView(), cancel, save])
        actions.orientation = .horizontal
        actions.spacing = 8
        actions.arrangedSubviews[0].setContentHuggingPriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [grid, actions])
        stack.orientation = .vertical
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        let root = NSView()
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18),
            grid.widthAnchor.constraint(equalTo: stack.widthAnchor),
            actions.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        return root
    }
}

@MainActor
private final class RemoteFolderPickerWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private let client: any RemoteClient
    private let chooseFolder: (String) -> Void
    private let table = NSTableView()
    private let pathLabel = NSTextField(labelWithString: "/")
    private let statusLabel = NSTextField(labelWithString: "")
    private var location: String
    private var items: [RemoteItem] = []

    init(client: any RemoteClient, initialPath: String, chooseFolder: @escaping (String) -> Void) {
        self.client = client
        self.location = RemotePath.normalized(initialPath)
        self.chooseFolder = chooseFolder
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 550, height: 420),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "选择远端文件夹"
        super.init(window: window)
        window.contentView = makeContentView(window: window)
        reload()
    }

    required init?(coder: NSCoder) { nil }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row >= 0, row < items.count else { return nil }
        let item = items[row]
        let identifier = tableColumn?.identifier.rawValue ?? ""
        let text = identifier == "modified" ? (item.modifiedAt?.formatted(date: .abbreviated, time: .shortened) ?? "-") : item.name
        let reusable = table.makeView(withIdentifier: NSUserInterfaceItemIdentifier("picker-\(identifier)"), owner: self) as? NSTableCellView
        let view = reusable ?? NSTableCellView()
        if view.identifier == nil {
            view.identifier = NSUserInterfaceItemIdentifier("picker-\(identifier)")
            let label = NSTextField(labelWithString: "")
            label.translatesAutoresizingMaskIntoConstraints = false
            view.textField = label
            view.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 4),
                label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -4),
                label.centerYAnchor.constraint(equalTo: view.centerYAnchor)
            ])
        }
        view.textField?.stringValue = text
        return view
    }

    @objc private func openSelectedFolder() {
        let row = table.selectedRow
        guard row >= 0, row < items.count else { return }
        location = items[row].path
        reload()
    }

    @objc private func goUp() {
        guard location != "/" else { return }
        location = RemotePath.parent(of: location)
        reload()
    }

    @objc private func reload() {
        pathLabel.stringValue = location
        statusLabel.stringValue = "正在加载…"
        Task { [weak self] in
            guard let self else { return }
            do {
                self.items = try await self.client.list(at: self.location).filter(\.isDirectory)
                self.statusLabel.stringValue = "\(self.items.count) 个文件夹"
            } catch {
                self.items = []
                self.statusLabel.stringValue = "加载失败：\(error.localizedDescription)"
            }
            self.table.reloadData()
        }
    }

    @objc private func chooseCurrentFolder() {
        chooseFolder(location)
        close()
    }

    private func makeContentView(window: NSWindow) -> NSView {
        pathLabel.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        pathLabel.lineBreakMode = .byTruncatingMiddle
        statusLabel.textColor = .secondaryLabelColor
        let up = NSButton(title: "上级", target: self, action: #selector(goUp))
        let refresh = NSButton(title: "刷新", target: self, action: #selector(reload))
        let choose = NSButton(title: "选择此文件夹", target: self, action: #selector(chooseCurrentFolder))
        let cancel = NSButton(title: "取消", target: window, action: #selector(NSWindow.performClose(_:)))
        [up, refresh, choose, cancel].forEach { $0.bezelStyle = .rounded }
        let top = NSStackView(views: [pathLabel, NSView(), up, refresh])
        top.orientation = .horizontal
        top.alignment = .centerY
        top.spacing = 8
        top.arrangedSubviews[1].setContentHuggingPriority(.defaultLow, for: .horizontal)

        table.delegate = self
        table.dataSource = self
        table.rowHeight = 28
        table.target = self
        table.doubleAction = #selector(openSelectedFolder)
        let name = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        name.title = "文件夹"
        name.width = 345
        let modified = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("modified"))
        modified.title = "修改时间"
        modified.width = 155
        table.addTableColumn(name)
        table.addTableColumn(modified)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = table

        let bottom = NSStackView(views: [statusLabel, NSView(), cancel, choose])
        bottom.orientation = .horizontal
        bottom.alignment = .centerY
        bottom.spacing = 8
        bottom.arrangedSubviews[1].setContentHuggingPriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [top, scroll, bottom])
        stack.orientation = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        let root = NSView()
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18),
            top.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            bottom.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        return root
    }
}
