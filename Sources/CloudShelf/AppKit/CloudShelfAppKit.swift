import AppKit
import CloudShelfCore

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

@MainActor
final class FileManagerWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSToolbarDelegate {
    fileprivate let store = WorkspaceStore()
    fileprivate let connectionTable = NSTableView()
    fileprivate let browserTable = NSTableView()
    fileprivate let transferTable = NSTableView()
    fileprivate let pathLabel = NSTextField(labelWithString: "/")
    fileprivate let connectionStatus = NSTextField(labelWithString: "No connection selected")
    private var selectedProfileID: UUID?
    private var session: RemoteSession?
    private var refreshTimer: Timer?

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
        if tableView === browserTable { return session?.items.count ?? 0 }
        return min(8, store.transfers.count)
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
        } else if tableView === browserTable, let item = session?.items[row] {
            switch identifier {
            case "name": text = item.name
            case "modified": text = item.modifiedAt?.formatted(date: .abbreviated, time: .shortened) ?? "-"
            case "size": text = item.isDirectory ? "-" : item.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "-"
            case "type": text = item.isDirectory ? "Folder" : (item.fileExtension.isEmpty ? "File" : item.fileExtension.uppercased())
            default: text = ""
            }
            icon = identifier == "name" ? symbol(item.isDirectory ? "folder.fill" : "doc") : nil
        } else {
            let transfer = Array(store.transfers.suffix(8).reversed())[row]
            switch identifier {
            case "transfer": text = transfer.title
            case "state": text = "\(transfer.connectionName) - \(transfer.detail)"
            default: text = ""
            }
            icon = identifier == "transfer" ? symbol(transfer.status == .failed ? "xmark.circle.fill" : transfer.status == .succeeded ? "checkmark.circle.fill" : "arrow.left.arrow.right") : nil
        }
        return cell(identifier: NSUserInterfaceItemIdentifier("cell-\(identifier)"), text: text, image: icon)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard notification.object as? NSTableView === connectionTable else { return }
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

    @objc func openSelectedItem() {
        guard let item = selectedItems.first, item.isDirectory, let session else { return }
        Task { [weak self] in
            await session.open(item)
            self?.refreshViews()
        }
    }

    @objc func refreshViews() {
        connectionTable.reloadData()
        browserTable.reloadData()
        transferTable.reloadData()
        pathLabel.stringValue = session?.location ?? "/"
        if let session {
            connectionStatus.stringValue = "\(session.profile.name)  |  \(session.profile.protocolType.rawValue)  |  \(session.isLoading ? "Loading..." : "Connected")"
        } else {
            connectionStatus.stringValue = "No connection selected"
        }
    }

    func addConnection() {
        let form = ConnectionForm()
        presentForm(title: "New Connection", form: form, actionTitle: "Save") { [weak self] in
            guard let self, let profile = form.profile() else { return }
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
        presentForm(title: "Edit Connection", form: form, actionTitle: "Save") { [weak self] in
            guard let self, let changed = form.profile(existing: profile) else { return }
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
        alert.messageText = "Delete \(profile.name)?"
        alert.informativeText = "This removes the saved connection and its Keychain credential. Remote files are not changed."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
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
        prompt(title: "New Folder", message: "Create a folder in \(session.location)", placeholder: "Folder name") { [weak self] name in
            guard let self else { return }
            Task { await self.store.createFolder(name, in: session); self.refreshViews() }
        }
    }

    func rename() {
        guard let item = selectedItems.first, selectedItems.count == 1, let session else { return }
        prompt(title: "Rename", message: item.name, placeholder: "New name", value: item.name) { [weak self] name in
            guard let self else { return }
            Task { await self.store.rename(item, to: name, in: session); self.refreshViews() }
        }
    }

    func deleteItems() {
        let items = selectedItems
        guard !items.isEmpty, let session else { return }
        let alert = NSAlert()
        alert.messageText = "Delete \(items.count) selected item\(items.count == 1 ? "" : "s")?"
        alert.informativeText = "Deletion is applied to the remote server immediately."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
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
        panel.prompt = "Upload"
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
        panel.prompt = "Download Here"
        panel.beginSheetModal(for: window!) { [weak self] response in
            guard response == .OK, let destination = panel.url, let self else { return }
            self.store.download(items, to: destination, from: session)
        }
    }

    func copyItems() { moveOrCopy(isMove: false) }
    func moveItems() { moveOrCopy(isMove: true) }

    func configureSync() {
        guard let profile = selectedProfile, let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Local Folder"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let local = panel.url?.path, let self else { return }
            let form = SyncForm(localFolder: local)
            self.presentForm(title: "Automatic Sync", form: form, actionTitle: "Add Rule") {
                var changed = profile
                changed.syncRules.append(form.rule())
                Task { await self.store.save(profile: changed, secret: nil); self.refreshViews() }
            }
        }
    }

    func runSync() {
        guard let profile = selectedProfile, let rule = profile.syncRules.first(where: { $0.isEnabled }) else {
            configureSync()
            return
        }
        store.sync(profile: profile, rule: rule)
    }

    private func moveOrCopy(isMove: Bool) {
        let items = selectedItems
        guard !items.isEmpty, let session else { return }
        prompt(title: isMove ? "Move to Folder" : "Copy to Folder", message: "Enter a remote destination folder.", placeholder: "/destination", value: session.location) { [weak self] destination in
            guard let self else { return }
            if isMove { self.store.move(items, to: RemotePath.normalized(destination), from: session) }
            else { self.store.copy(items, to: RemotePath.normalized(destination), from: session) }
        }
    }

    private var selectedProfile: ConnectionProfile? {
        selectedProfileID.flatMap { store.profile(id: $0) }
    }

    private var selectedItems: [RemoteItem] {
        guard let session else { return [] }
        return browserTable.selectedRowIndexes.compactMap { index in
            guard index >= 0, index < session.items.count else { return nil }
            return session.items[index]
        }
    }

    private func configureToolbar() {
        let toolbar = NSToolbar(identifier: "CloudShelfToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
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
        main.addItem(menu(title: "文件", items: [
            menuItem("新建文件夹", #selector(folderAction), key: "n", modifiers: [.command, .shift]),
            menuItem("上传", #selector(uploadAction), key: "u"),
            menuItem("下载", #selector(downloadAction), key: "d"),
            .separator(),
            menuItem("重命名", #selector(renameAction)),
            menuItem("复制到文件夹", #selector(copyAction)),
            menuItem("移动到文件夹", #selector(moveAction)),
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
        case "add": item.label = "Connection"; item.toolTip = "New connection"; item.image = symbol("plus"); item.target = self; item.action = #selector(addAction)
        case "edit": item.label = "Edit"; item.toolTip = "Edit selected connection"; item.image = symbol("slider.horizontal.3"); item.target = self; item.action = #selector(editAction)
        case "up": item.label = "Up"; item.toolTip = "Parent folder"; item.image = symbol("arrow.up"); item.target = self; item.action = #selector(upAction)
        case "reload": item.label = "Reload"; item.toolTip = "Reload folder"; item.image = symbol("arrow.clockwise"); item.target = self; item.action = #selector(reloadAction)
        case "folder": item.label = "Folder"; item.toolTip = "New folder"; item.image = symbol("folder.badge.plus"); item.target = self; item.action = #selector(folderAction)
        case "upload": item.label = "Upload"; item.toolTip = "Upload files"; item.image = symbol("arrow.up.doc"); item.target = self; item.action = #selector(uploadAction)
        case "download": item.label = "Download"; item.toolTip = "Download selected files"; item.image = symbol("arrow.down.doc"); item.target = self; item.action = #selector(downloadAction)
        case "copy": item.label = "Copy"; item.toolTip = "Copy selected files"; item.image = symbol("doc.on.doc"); item.target = self; item.action = #selector(copyAction)
        case "move": item.label = "Move"; item.toolTip = "Move selected files"; item.image = symbol("folder.badge.gearshape"); item.target = self; item.action = #selector(moveAction)
        case "delete": item.label = "Delete"; item.toolTip = "Delete selected files"; item.image = symbol("trash"); item.target = self; item.action = #selector(deleteAction)
        case "sync": item.label = "Sync"; item.toolTip = "Configure or run automatic sync"; item.image = symbol("arrow.triangle.2.circlepath"); item.target = self; item.action = #selector(syncAction)
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
    @objc fileprivate func copyAction() { copyItems() }
    @objc fileprivate func moveAction() { moveItems() }
    @objc fileprivate func deleteAction() { deleteItems() }
    @objc fileprivate func syncAction() { runSync() }
    @objc fileprivate func configureSyncAction() { configureSync() }
    @objc fileprivate func toggleToolbarAction() { window?.toggleToolbarShown(self) }

    @objc private func showAbout() {
        let alert = NSAlert()
        alert.messageText = "CloudShelf"
        alert.informativeText = "FTP、SFTP、WebDAV 应用内文件工作区\n不使用 Finder 挂载 API 或 macFUSE。"
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
        alert.addButton(withTitle: "Cancel")
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
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
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

    private func symbol(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)
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
        let title = NSTextField(labelWithString: "CONNECTIONS")
        title.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        title.textColor = .secondaryLabelColor
        let scroll = scrollView(for: owner.connectionTable)
        owner.connectionTable.delegate = owner
        owner.connectionTable.dataSource = owner
        owner.connectionTable.headerView = nil
        owner.connectionTable.rowHeight = 38
        owner.connectionTable.addTableColumn(column("connection", title: "Connection", width: 175))
        owner.connectionTable.addTableColumn(column("protocol", title: "Protocol", width: 70))
        let button = NSButton(title: "New Connection", target: owner, action: #selector(FileManagerWindowController.addAction))
        button.bezelStyle = .rounded
        let remove = NSButton(title: "Remove", target: owner, action: #selector(FileManagerWindowController.removeConnection))
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
        owner.browserTable.addTableColumn(column("name", title: "Name", width: 380))
        owner.browserTable.addTableColumn(column("modified", title: "Modified", width: 160))
        owner.browserTable.addTableColumn(column("size", title: "Size", width: 95))
        owner.browserTable.addTableColumn(column("type", title: "Type", width: 110))
        let transferTitle = NSTextField(labelWithString: "TRANSFERS")
        transferTitle.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        transferTitle.textColor = .secondaryLabelColor
        let transferScroll = scrollView(for: owner.transferTable)
        owner.transferTable.delegate = owner
        owner.transferTable.dataSource = owner
        owner.transferTable.headerView = nil
        owner.transferTable.rowHeight = 27
        owner.transferTable.addTableColumn(column("transfer", title: "Transfer", width: 245))
        owner.transferTable.addTableColumn(column("state", title: "State", width: 430))
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
    private let host = NSTextField(string: "")
    private let port = NSTextField(string: "22")
    private let username = NSTextField(string: "")
    private let root = NSTextField(string: "/")
    private let authentication = NSPopUpButton()
    private let secretField = NSSecureTextField(string: "")
    private let keyPath = NSTextField(string: "")
    private let hostKeyPolicy = NSPopUpButton()
    private let tls = NSButton(checkboxWithTitle: "Use TLS", target: nil, action: nil)

    var secret: String? {
        let value = secretField.stringValue
        return value.isEmpty ? nil : value
    }

    init(profile: ConnectionProfile? = nil) {
        super.init(frame: NSRect(x: 0, y: 0, width: 440, height: 364))
        protocolBox.addItems(withTitles: RemoteProtocol.allCases.map(\.rawValue))
        authentication.addItems(withTitles: AuthenticationMethod.allCases.map(\.rawValue))
        hostKeyPolicy.addItems(withTitles: HostKeyPolicy.allCases.map(\.rawValue))
        layout(rows: [
            ("Name", name), ("Protocol", protocolBox), ("Host", host), ("Port", port),
            ("Username", username), ("Remote root", root), ("Authentication", authentication),
            ("Password", secretField), ("Private key", keyPath), ("Host key", hostKeyPolicy), ("", tls)
        ])
        if let profile {
            name.stringValue = profile.name
            protocolBox.selectItem(withTitle: profile.protocolType.rawValue)
            host.stringValue = profile.host
            port.stringValue = String(profile.port)
            username.stringValue = profile.username
            root.stringValue = profile.basePath
            authentication.selectItem(withTitle: profile.authentication.rawValue)
            keyPath.stringValue = profile.privateKeyPath ?? ""
            hostKeyPolicy.selectItem(withTitle: profile.hostKeyPolicy.rawValue)
            tls.state = profile.useTLS ? .on : .off
        } else {
            protocolBox.selectItem(withTitle: RemoteProtocol.sftp.rawValue)
            hostKeyPolicy.selectItem(withTitle: HostKeyPolicy.acceptNew.rawValue)
            tls.state = .off
        }
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize { NSSize(width: 440, height: 364) }

    func profile(existing: ConnectionProfile? = nil) -> ConnectionProfile? {
        guard let protocolType = RemoteProtocol(rawValue: protocolBox.titleOfSelectedItem ?? ""),
              let method = AuthenticationMethod(rawValue: authentication.titleOfSelectedItem ?? ""),
              let keyPolicy = HostKeyPolicy(rawValue: hostKeyPolicy.titleOfSelectedItem ?? ""),
              let parsedPort = Int(port.stringValue), !name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !host.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return ConnectionProfile(
            id: existing?.id ?? UUID(), name: name.stringValue, protocolType: protocolType, host: host.stringValue,
            port: parsedPort, username: username.stringValue, basePath: root.stringValue,
            authentication: protocolType == .sftp ? method : .password,
            privateKeyPath: keyPath.stringValue.isEmpty ? nil : keyPath.stringValue,
            useTLS: tls.state == .on, hostKeyPolicy: keyPolicy,
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
}

private final class SyncForm: NSView {
    private let local = NSTextField(string: "")
    private let remote = NSTextField(string: "/")
    private let direction = NSPopUpButton()
    private let interval = NSPopUpButton()

    init(localFolder: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: 440, height: 132))
        local.stringValue = localFolder
        local.isEditable = false
        direction.addItems(withTitles: SyncDirection.allCases.map(\.rawValue))
        interval.addItems(withTitles: ["5 minutes", "15 minutes", "30 minutes", "1 hour"])
        interval.selectItem(at: 1)
        layout(rows: [("Local folder", local), ("Remote folder", remote), ("Direction", direction), ("Frequency", interval)])
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize { NSSize(width: 440, height: 132) }

    func rule() -> SyncRule {
        let minutes = [5, 15, 30, 60][max(0, interval.indexOfSelectedItem)]
        return SyncRule(localFolder: local.stringValue, remoteFolder: remote.stringValue, direction: SyncDirection(rawValue: direction.titleOfSelectedItem ?? "") ?? .uploadOnly, intervalMinutes: minutes)
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
}
