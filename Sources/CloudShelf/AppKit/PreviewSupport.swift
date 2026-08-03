import AppKit
import AVFoundation
import AVKit
import CloudShelfCore
import Foundation
import PDFKit

enum PreviewContentKind: Sendable {
    case image
    case video
    case audio
    case pdf
    case text
}

@MainActor
final class PreviewPreferences {
    static let shared = PreviewPreferences()

    private enum Key {
        static let enabled = "CloudShelf.previewEnabled"
        static let sidebarVisible = "CloudShelf.previewSidebarVisible"
        static let maximumSizeMB = "CloudShelf.previewMaximumSizeMB"
        static let enabledImageExtensions = "CloudShelf.previewEnabledImageExtensions"
        static let enabledVideoExtensions = "CloudShelf.previewEnabledVideoExtensions"
        static let enabledAudioExtensions = "CloudShelf.previewEnabledAudioExtensions"
        static let enabledDocumentExtensions = "CloudShelf.previewEnabledDocumentExtensions"
        static let customImageExtensions = "CloudShelf.previewCustomImageExtensions"
        static let customVideoExtensions = "CloudShelf.previewCustomVideoExtensions"
        static let customAudioExtensions = "CloudShelf.previewCustomAudioExtensions"
        static let otherTextEnabled = "CloudShelf.previewOtherTextEnabled"
        static let otherTextExtensions = "CloudShelf.previewOtherTextExtensions"
        static let connectionSidebarVisible = "CloudShelf.connectionSidebarVisible"
        static let transferPaneVisible = "CloudShelf.transferPaneVisible"
        static let defaultDownloadDirectory = "CloudShelf.defaultDownloadDirectory"
        static let askDownloadLocationEachTime = "CloudShelf.askDownloadLocationEachTime"
    }

    private let defaults = UserDefaults.standard
    private(set) var isEnabled: Bool
    private(set) var isSidebarVisible: Bool
    private(set) var isConnectionSidebarVisible: Bool
    private(set) var isTransferPaneVisible: Bool
    private(set) var maximumSizeMB: Int
    private(set) var enabledImageExtensions: Set<String>
    private(set) var enabledVideoExtensions: Set<String>
    private(set) var enabledAudioExtensions: Set<String>
    private(set) var enabledDocumentExtensions: Set<String>
    private(set) var customImageExtensions: String
    private(set) var customVideoExtensions: String
    private(set) var customAudioExtensions: String
    private(set) var isOtherTextEnabled: Bool
    private(set) var otherTextExtensions: String
    private(set) var defaultDownloadDirectoryPath: String?
    private(set) var askDownloadLocationEachTime: Bool

    private init() {
        isEnabled = defaults.object(forKey: Key.enabled) as? Bool ?? true
        isSidebarVisible = defaults.object(forKey: Key.sidebarVisible) as? Bool ?? true
        isConnectionSidebarVisible = defaults.object(forKey: Key.connectionSidebarVisible) as? Bool ?? true
        isTransferPaneVisible = defaults.object(forKey: Key.transferPaneVisible) as? Bool ?? true
        maximumSizeMB = max(1, defaults.object(forKey: Key.maximumSizeMB) as? Int ?? 32)
        enabledImageExtensions = Self.loadExtensions(for: Key.enabledImageExtensions, fallback: Self.commonImageExtensions)
        enabledVideoExtensions = Self.loadExtensions(for: Key.enabledVideoExtensions, fallback: Self.commonVideoExtensions)
        enabledAudioExtensions = Self.loadExtensions(for: Key.enabledAudioExtensions, fallback: Self.commonAudioExtensions)
        enabledDocumentExtensions = Self.loadExtensions(for: Key.enabledDocumentExtensions, fallback: Self.commonDocumentExtensions)
        customImageExtensions = defaults.string(forKey: Key.customImageExtensions) ?? ""
        customVideoExtensions = defaults.string(forKey: Key.customVideoExtensions) ?? ""
        customAudioExtensions = defaults.string(forKey: Key.customAudioExtensions) ?? ""
        isOtherTextEnabled = defaults.object(forKey: Key.otherTextEnabled) as? Bool ?? true
        otherTextExtensions = defaults.string(forKey: Key.otherTextExtensions) ?? "*"
        defaultDownloadDirectoryPath = defaults.string(forKey: Key.defaultDownloadDirectory)
        askDownloadLocationEachTime = defaults.object(forKey: Key.askDownloadLocationEachTime) as? Bool ?? true
    }

    var maximumSizeBytes: Int64 {
        Int64(maximumSizeMB) * 1_024 * 1_024
    }

    func update(
        isEnabled: Bool,
        maximumSizeMB: Int,
        enabledImageExtensions: Set<String>,
        enabledVideoExtensions: Set<String>,
        enabledAudioExtensions: Set<String>,
        enabledDocumentExtensions: Set<String>,
        customImageExtensions: String,
        customVideoExtensions: String,
        customAudioExtensions: String,
        isOtherTextEnabled: Bool,
        otherTextExtensions: String
    ) {
        self.isEnabled = isEnabled
        self.maximumSizeMB = max(1, maximumSizeMB)
        self.enabledImageExtensions = enabledImageExtensions
        self.enabledVideoExtensions = enabledVideoExtensions
        self.enabledAudioExtensions = enabledAudioExtensions
        self.enabledDocumentExtensions = enabledDocumentExtensions
        self.customImageExtensions = customImageExtensions
        self.customVideoExtensions = customVideoExtensions
        self.customAudioExtensions = customAudioExtensions
        self.isOtherTextEnabled = isOtherTextEnabled
        self.otherTextExtensions = otherTextExtensions
        defaults.set(isEnabled, forKey: Key.enabled)
        defaults.set(self.maximumSizeMB, forKey: Key.maximumSizeMB)
        defaults.set(Array(enabledImageExtensions).sorted(), forKey: Key.enabledImageExtensions)
        defaults.set(Array(enabledVideoExtensions).sorted(), forKey: Key.enabledVideoExtensions)
        defaults.set(Array(enabledAudioExtensions).sorted(), forKey: Key.enabledAudioExtensions)
        defaults.set(Array(enabledDocumentExtensions).sorted(), forKey: Key.enabledDocumentExtensions)
        defaults.set(customImageExtensions, forKey: Key.customImageExtensions)
        defaults.set(customVideoExtensions, forKey: Key.customVideoExtensions)
        defaults.set(customAudioExtensions, forKey: Key.customAudioExtensions)
        defaults.set(isOtherTextEnabled, forKey: Key.otherTextEnabled)
        defaults.set(otherTextExtensions, forKey: Key.otherTextExtensions)
    }

    func setSidebarVisible(_ visible: Bool) {
        isSidebarVisible = visible
        defaults.set(visible, forKey: Key.sidebarVisible)
    }

    func setConnectionSidebarVisible(_ visible: Bool) {
        isConnectionSidebarVisible = visible
        defaults.set(visible, forKey: Key.connectionSidebarVisible)
    }

    func setTransferPaneVisible(_ visible: Bool) {
        isTransferPaneVisible = visible
        defaults.set(visible, forKey: Key.transferPaneVisible)
    }

    func updateDownloadPreferences(directoryPath: String?, askEachTime: Bool) {
        let normalizedPath = directoryPath?.trimmingCharacters(in: .whitespacesAndNewlines)
        defaultDownloadDirectoryPath = normalizedPath?.isEmpty == true ? nil : normalizedPath
        askDownloadLocationEachTime = askEachTime
        if let defaultDownloadDirectoryPath {
            defaults.set(defaultDownloadDirectoryPath, forKey: Key.defaultDownloadDirectory)
        } else {
            defaults.removeObject(forKey: Key.defaultDownloadDirectory)
        }
        defaults.set(askEachTime, forKey: Key.askDownloadLocationEachTime)
    }

    func contentKind(for filename: String) -> PreviewContentKind? {
        let fileExtension = URL(fileURLWithPath: filename).pathExtension.lowercased()
        if imageExtensions.contains(fileExtension) { return .image }
        if videoExtensions.contains(fileExtension) { return .video }
        if audioExtensions.contains(fileExtension) { return .audio }
        if enabledDocumentExtensions.contains(fileExtension) { return .pdf }
        guard isOtherTextEnabled else { return nil }
        let otherExtensions = extensionSet(from: otherTextExtensions)
        return otherExtensions.contains("*") || otherExtensions.contains(fileExtension) ? .text : nil
    }

    static let commonImageExtensions = ["jpg", "jpeg", "png", "gif", "heic", "heif", "webp", "tif", "tiff", "bmp", "ico"]
    static let commonVideoExtensions = ["mp4", "mov", "m4v", "avi", "mkv", "webm", "mpeg", "mpg"]
    static let commonAudioExtensions = ["mp3", "m4a", "aac", "wav", "aif", "aiff", "flac", "ogg", "opus"]
    static let commonDocumentExtensions = ["pdf"]

    private var imageExtensions: Set<String> {
        enabledImageExtensions.union(extensionSet(from: customImageExtensions))
    }

    private var videoExtensions: Set<String> {
        enabledVideoExtensions.union(extensionSet(from: customVideoExtensions))
    }

    private var audioExtensions: Set<String> {
        enabledAudioExtensions.union(extensionSet(from: customAudioExtensions))
    }

    private func extensionSet(from text: String) -> Set<String> {
        Set(text.split(whereSeparator: { $0 == "," || $0 == ";" || $0.isWhitespace }).compactMap { value in
            let normalized = String(value).trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
            return normalized.isEmpty ? nil : normalized
        })
    }

    private static func loadExtensions(for key: String, fallback: [String]) -> Set<String> {
        guard let values = UserDefaults.standard.stringArray(forKey: key) else { return Set(fallback) }
        return Set(values.map { $0.lowercased() })
    }
}

enum PreviewTemporaryFiles {
    private static let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CloudShelfPreview", isDirectory: true)

    static func prepare() throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: directory.path) {
            try manager.removeItem(at: directory)
        }
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    static func destination(for originalName: String) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let safeName = URL(fileURLWithPath: originalName).lastPathComponent.replacingOccurrences(of: "/", with: "-")
        return directory.appendingPathComponent("\(UUID().uuidString)-\(safeName)")
    }
}

@MainActor
final class RemotePreviewSidebar: NSView {
    private let titleLabel = NSTextField(labelWithString: "预览")
    private let statusLabel = NSTextField(labelWithString: "选择一个文件以预览")
    private let contentHolder = NSView()
    private var previewTask: Task<Void, Never>?
    private var previewToken = UUID()
    private var mediaPlayer: AVPlayer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupView()
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        previewTask?.cancel()
        mediaPlayer?.pause()
    }

    func reset() {
        previewTask?.cancel()
        previewTask = nil
        mediaPlayer?.pause()
        mediaPlayer = nil
        previewToken = UUID()
        clearContent()
        titleLabel.stringValue = AppLocalization.shared.text("预览")
        statusLabel.stringValue = AppLocalization.shared.text("选择一个文件以预览")
    }

    func show(item: RemoteItem?, client: (any RemoteClient)?) {
        reset()

        guard PreviewPreferences.shared.isEnabled else {
            titleLabel.stringValue = AppLocalization.shared.text("预览")
            statusLabel.stringValue = AppLocalization.shared.text("预览已关闭")
            return
        }
        guard let item, let client, !item.isDirectory else {
            titleLabel.stringValue = AppLocalization.shared.text("预览")
            statusLabel.stringValue = AppLocalization.shared.text("选择一个文件以预览")
            return
        }
        guard let size = item.size else {
            titleLabel.stringValue = item.name
            statusLabel.stringValue = AppLocalization.shared.text("服务器未提供文件大小，未下载预览")
            return
        }
        guard size <= PreviewPreferences.shared.maximumSizeBytes else {
            titleLabel.stringValue = item.name
            statusLabel.stringValue = AppLocalization.shared.isEnglish
                ? "File exceeds \(PreviewPreferences.shared.maximumSizeMB) MB preview limit"
                : "文件超过 \(PreviewPreferences.shared.maximumSizeMB) MB 预览上限"
            return
        }

        let token = previewToken
        titleLabel.stringValue = item.name
        statusLabel.stringValue = AppLocalization.shared.text("正在下载预览…")
        guard let kind = PreviewPreferences.shared.contentKind(for: item.name) else {
            statusLabel.stringValue = AppLocalization.shared.text("此扩展名未在预览设置中启用")
            return
        }
        previewTask = Task { [weak self] in
            do {
                let destination = try PreviewTemporaryFiles.destination(for: item.name)
                try await client.download(item, to: destination)
                guard !Task.isCancelled, let self, self.previewToken == token else { return }
                self.render(kind: kind, url: destination, size: size)
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.previewToken == token else { return }
                self.statusLabel.stringValue = AppLocalization.shared.text("预览失败") + ": \(error.localizedDescription)"
            }
        }
    }

    private func setupView() {
        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        titleLabel.lineBreakMode = .byCharWrapping
        titleLabel.maximumNumberOfLines = 3
        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.maximumNumberOfLines = 3
        contentHolder.translatesAutoresizingMaskIntoConstraints = false

        let header = NSStackView(views: [titleLabel, statusLabel])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 4
        let stack = NSStackView(views: [header, contentHolder])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            contentHolder.widthAnchor.constraint(equalTo: stack.widthAnchor),
            contentHolder.heightAnchor.constraint(greaterThanOrEqualToConstant: 220)
        ])
    }

    private func render(kind: PreviewContentKind, url: URL, size: Int64) {
        let sizeText = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
        switch kind {
        case .image:
            guard let image = NSImage(contentsOf: url) else {
                statusLabel.stringValue = AppLocalization.shared.text("无法读取图片")
                return
            }
            let imageView = NSImageView(image: image)
            imageView.imageScaling = .scaleProportionallyUpOrDown
            installContent(imageView)
            statusLabel.stringValue = AppLocalization.shared.text("图片") + " · \(sizeText)"
        case .video, .audio:
            let player = AVPlayer(url: url)
            let playerView = AVPlayerView()
            playerView.player = player
            playerView.controlsStyle = .floating
            playerView.showsFullScreenToggleButton = kind == .video
            mediaPlayer = player
            installContent(playerView)
            statusLabel.stringValue = AppLocalization.shared.text(kind == .video ? "视频" : "音频") + " · \(sizeText)"
        case .pdf:
            let pdfView = PDFView()
            pdfView.autoScales = true
            pdfView.displayMode = .singlePageContinuous
            pdfView.document = PDFDocument(url: url)
            installContent(pdfView)
            statusLabel.stringValue = pdfView.document == nil ? AppLocalization.shared.text("无法读取 PDF") : "PDF · \(sizeText)"
        case .text:
            guard let data = try? Data(contentsOf: url) else {
                statusLabel.stringValue = AppLocalization.shared.text("无法读取文本")
                return
            }
            let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
            let limit = 200_000
            let displayedText = text.count > limit ? String(text.prefix(limit)) + "\n\n… 已截断预览 …" : text
            let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 280))
            textView.isEditable = false
            textView.isSelectable = true
            textView.drawsBackground = false
            textView.isVerticallyResizable = true
            textView.isHorizontallyResizable = false
            textView.autoresizingMask = [.width]
            textView.minSize = NSSize(width: 0, height: 0)
            textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            textView.textContainer?.widthTracksTextView = true
            textView.textContainer?.containerSize = NSSize(width: 320, height: CGFloat.greatestFiniteMagnitude)
            textView.textContainerInset = NSSize(width: 8, height: 8)
            textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            textView.textColor = .labelColor
            textView.string = displayedText
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 320, height: 280))
            scroll.hasVerticalScroller = true
            scroll.autohidesScrollers = true
            scroll.hasHorizontalScroller = false
            scroll.borderType = .bezelBorder
            scroll.documentView = textView
            installContent(scroll)
            statusLabel.stringValue = AppLocalization.shared.text("文本") + " · \(sizeText)"
        }
    }

    private func clearContent() {
        contentHolder.subviews.forEach { $0.removeFromSuperview() }
    }

    private func installContent(_ view: NSView) {
        clearContent()
        view.translatesAutoresizingMaskIntoConstraints = true
        view.frame = contentHolder.bounds
        view.autoresizingMask = [.width, .height]
        if let scroll = view as? NSScrollView, let textView = scroll.documentView as? NSTextView {
            let width = max(scroll.contentView.bounds.width, 1)
            let height = max(scroll.contentView.bounds.height, 280)
            textView.frame = NSRect(x: 0, y: 0, width: width, height: height)
            textView.textContainer?.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
            DispatchQueue.main.async { [weak self, weak scroll, weak textView] in
                guard let self, let scroll, let textView else { return }
                let width = max(self.contentHolder.bounds.width, 1)
                let height = max(self.contentHolder.bounds.height, 280)
                textView.frame = NSRect(x: 0, y: 0, width: width, height: height)
                textView.textContainer?.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
                scroll.reflectScrolledClipView(scroll.contentView)
            }
        }
        contentHolder.addSubview(view)
    }
}

@MainActor
final class SettingsWindowController: NSWindowController {
    private enum ExtensionGroup: Hashable {
        case image, video, audio, document
    }

    private let previewEnabled = NSButton(checkboxWithTitle: "启用文件预览", target: nil, action: nil)
    private let languagePopup = NSPopUpButton()
    private let maximumSize = NSTextField(string: "")
    private let customImageExtensions = NSTextField(string: "")
    private let customVideoExtensions = NSTextField(string: "")
    private let customAudioExtensions = NSTextField(string: "")
    private let otherTextEnabled = NSButton(checkboxWithTitle: "其他", target: nil, action: nil)
    private let otherTextExtensions = NSTextField(string: "")
    private let concurrency = NSPopUpButton()
    private let askDownloadLocationEachTime = NSButton(checkboxWithTitle: "每次下载时询问位置", target: nil, action: nil)
    private let defaultDownloadLocation = NSTextField(labelWithString: "")
    private let tabView = NSTabView()
    private var extensionButtons: [ExtensionGroup: [String: NSButton]] = [:]
    private var pendingDefaultDownloadDirectoryPath: String?
    private let makeSyncContent: () -> NSView
    private let currentConcurrency: () -> Int
    private let updateConcurrency: (Int) -> Void
    private let didSave: () -> Void

    init(
        makeSyncContent: @escaping () -> NSView,
        currentConcurrency: @escaping () -> Int,
        updateConcurrency: @escaping (Int) -> Void,
        didSave: @escaping () -> Void
    ) {
        self.makeSyncContent = makeSyncContent
        self.currentConcurrency = currentConcurrency
        self.updateConcurrency = updateConcurrency
        self.didSave = didSave
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = AppLocalization.shared.text("设置")
        window.minSize = NSSize(width: 680, height: 520)
        super.init(window: window)
        window.center()
        loadPreferences()
        window.contentView = makeContentView(window: window)
        if let contentView = window.contentView {
            AppLocalization.shared.localize(view: contentView)
        }
    }

    required init?(coder: NSCoder) { nil }

    func selectSyncTab() {
        tabView.selectTabViewItem(at: 2)
    }

    @objc private func save() {
        guard let size = Int(maximumSize.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)), size > 0 else {
            let alert = NSAlert()
            alert.messageText = AppLocalization.shared.text("最大预览文件大小必须是大于 0 的整数。")
            alert.beginSheetModal(for: window!) { _ in }
            return
        }
        PreviewPreferences.shared.update(
            isEnabled: previewEnabled.state == .on,
            maximumSizeMB: size,
            enabledImageExtensions: selectedExtensions(in: .image),
            enabledVideoExtensions: selectedExtensions(in: .video),
            enabledAudioExtensions: selectedExtensions(in: .audio),
            enabledDocumentExtensions: selectedExtensions(in: .document),
            customImageExtensions: customImageExtensions.stringValue,
            customVideoExtensions: customVideoExtensions.stringValue,
            customAudioExtensions: customAudioExtensions.stringValue,
            isOtherTextEnabled: otherTextEnabled.state == .on,
            otherTextExtensions: otherTextExtensions.stringValue
        )
        updateConcurrency(Int(concurrency.titleOfSelectedItem ?? "3") ?? 3)
        PreviewPreferences.shared.updateDownloadPreferences(
            directoryPath: pendingDefaultDownloadDirectoryPath,
            askEachTime: askDownloadLocationEachTime.state == .on
        )
        let languageIndex = max(0, min(languagePopup.indexOfSelectedItem, AppLanguage.allCases.count - 1))
        AppLocalization.shared.setLanguage(AppLanguage.allCases[languageIndex])
        didSave()
        close()
    }

    @objc private func chooseDefaultDownloadDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = AppLocalization.shared.text("选择下载位置")
        if let pendingDefaultDownloadDirectoryPath {
            panel.directoryURL = URL(fileURLWithPath: pendingDefaultDownloadDirectoryPath, isDirectory: true)
        }
        panel.beginSheetModal(for: window!) { [weak self] response in
            guard response == .OK, let self, let url = panel.url else { return }
            self.pendingDefaultDownloadDirectoryPath = url.path
            self.updateDefaultDownloadLocationLabel()
        }
    }

    @objc private func clearDefaultDownloadDirectory() {
        pendingDefaultDownloadDirectoryPath = nil
        updateDefaultDownloadLocationLabel()
    }

    private func loadPreferences() {
        let preferences = PreviewPreferences.shared
        previewEnabled.state = preferences.isEnabled ? .on : .off
        maximumSize.stringValue = String(preferences.maximumSizeMB)
        customImageExtensions.stringValue = preferences.customImageExtensions
        customVideoExtensions.stringValue = preferences.customVideoExtensions
        customAudioExtensions.stringValue = preferences.customAudioExtensions
        otherTextEnabled.state = preferences.isOtherTextEnabled ? .on : .off
        otherTextExtensions.stringValue = preferences.otherTextExtensions
        pendingDefaultDownloadDirectoryPath = preferences.defaultDownloadDirectoryPath
        askDownloadLocationEachTime.state = preferences.askDownloadLocationEachTime ? .on : .off
        updateDefaultDownloadLocationLabel()
        concurrency.addItems(withTitles: ["1", "2", "3", "4", "6", "8"])
        concurrency.selectItem(withTitle: String(currentConcurrency()))
        if concurrency.indexOfSelectedItem < 0 { concurrency.selectItem(withTitle: "3") }
        languagePopup.addItems(withTitles: AppLanguage.allCases.map(\.displayName))
        languagePopup.selectItem(at: AppLanguage.allCases.firstIndex(of: AppLocalization.shared.language) ?? 0)
    }

    private func makeContentView(window: NSWindow) -> NSView {
        addTab(label: "预览", identifier: "preview", view: makePreviewTab())
        addTab(label: "传输", identifier: "transfer", view: makeTransferTab())
        addTab(label: "同步", identifier: "sync", view: makeSyncContent())
        tabView.translatesAutoresizingMaskIntoConstraints = false

        let save = NSButton(title: "保存", target: self, action: #selector(save))
        save.bezelStyle = .rounded
        let cancel = NSButton(title: "取消", target: window, action: #selector(NSWindow.performClose(_:)))
        cancel.bezelStyle = .rounded
        let actions = NSStackView(views: [NSView(), cancel, save])
        actions.orientation = .horizontal
        actions.spacing = 8
        actions.arrangedSubviews[0].setContentHuggingPriority(.defaultLow, for: .horizontal)
        actions.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView()
        root.addSubview(tabView)
        root.addSubview(actions)
        NSLayoutConstraint.activate([
            tabView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            tabView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            tabView.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            actions.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            actions.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            actions.topAnchor.constraint(equalTo: tabView.bottomAnchor, constant: 12),
            actions.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18)
        ])
        return root
    }

    private func addTab(label: String, identifier: String, view: NSView) {
        let item = NSTabViewItem(identifier: identifier)
        item.label = AppLocalization.shared.text(label)
        item.view = view
        AppLocalization.shared.localize(view: view)
        tabView.addTabViewItem(item)
    }

    private func makePreviewTab() -> NSView {
        let title = NSTextField(labelWithString: "文件预览")
        title.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        let sizeRow = NSStackView(views: [NSTextField(labelWithString: "最大大小（MB）"), maximumSize])
        sizeRow.orientation = .horizontal
        sizeRow.spacing = 12
        sizeRow.arrangedSubviews[0].setContentHuggingPriority(.required, for: .horizontal)

        let stack = NSStackView(views: [
            title,
            languageRow(),
            previewEnabled,
            sizeRow,
            extensionSection(title: "图片", group: .image, extensions: PreviewPreferences.commonImageExtensions, selected: PreviewPreferences.shared.enabledImageExtensions),
            customExtensionRow(title: "自定义图片", field: customImageExtensions),
            extensionSection(title: "视频", group: .video, extensions: PreviewPreferences.commonVideoExtensions, selected: PreviewPreferences.shared.enabledVideoExtensions),
            customExtensionRow(title: "自定义视频", field: customVideoExtensions),
            extensionSection(title: "音频", group: .audio, extensions: PreviewPreferences.commonAudioExtensions, selected: PreviewPreferences.shared.enabledAudioExtensions),
            customExtensionRow(title: "自定义音频", field: customAudioExtensions),
            extensionSection(title: "文档", group: .document, extensions: PreviewPreferences.commonDocumentExtensions, selected: PreviewPreferences.shared.enabledDocumentExtensions),
            otherExtensionRow()
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = stack
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor, constant: -6),
            stack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: scroll.contentView.bottomAnchor, constant: -8),
            stack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor, constant: -12),
            maximumSize.widthAnchor.constraint(equalToConstant: 90)
        ])
        return scroll
    }

    private func languageRow() -> NSView {
        let label = NSTextField(labelWithString: "语言")
        label.setContentHuggingPriority(.required, for: .horizontal)
        let row = NSStackView(views: [label, languagePopup])
        row.orientation = .horizontal
        row.spacing = 12
        return row
    }

    private func makeTransferTab() -> NSView {
        let title = NSTextField(labelWithString: "传输队列")
        title.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        let description = NSTextField(wrappingLabelWithString: "同时传输的任务越多，速度不一定越快。建议普通网络使用 2 到 4 个任务；不稳定网络请选择 1 到 2 个任务。暂停的文件任务会在协议支持时从现有进度继续。")
        description.textColor = .secondaryLabelColor
        description.font = NSFont.systemFont(ofSize: 12)
        let row = NSStackView(views: [NSTextField(labelWithString: "同时传输任务数"), concurrency])
        row.orientation = .horizontal
        row.spacing = 12
        row.arrangedSubviews[0].setContentHuggingPriority(.required, for: .horizontal)
        let locationTitle = NSTextField(labelWithString: "默认下载位置")
        locationTitle.setContentHuggingPriority(.required, for: .horizontal)
        defaultDownloadLocation.lineBreakMode = .byTruncatingMiddle
        defaultDownloadLocation.maximumNumberOfLines = 1
        defaultDownloadLocation.textColor = .secondaryLabelColor
        defaultDownloadLocation.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let chooseLocation = NSButton(title: "选择…", target: self, action: #selector(chooseDefaultDownloadDirectory))
        let clearLocation = NSButton(title: "清除", target: self, action: #selector(clearDefaultDownloadDirectory))
        [chooseLocation, clearLocation].forEach { $0.bezelStyle = .rounded; $0.controlSize = .small }
        let locationRow = NSStackView(views: [locationTitle, defaultDownloadLocation, chooseLocation, clearLocation])
        locationRow.orientation = .horizontal
        locationRow.alignment = .centerY
        locationRow.spacing = 12
        let stack = NSStackView(views: [title, row, askDownloadLocationEachTime, locationRow, description])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        let root = NSView()
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 18)
        ])
        return root
    }

    private func updateDefaultDownloadLocationLabel() {
        defaultDownloadLocation.stringValue = pendingDefaultDownloadDirectoryPath ?? "未设置"
        defaultDownloadLocation.toolTip = pendingDefaultDownloadDirectoryPath
    }

    private func extensionSection(title: String, group: ExtensionGroup, extensions: [String], selected: Set<String>) -> NSView {
        let heading = NSTextField(labelWithString: title)
        heading.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        var buttons: [String: NSButton] = [:]
        let rows = stride(from: 0, to: extensions.count, by: 4).map { offset -> NSStackView in
            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 12
            for extensionName in extensions[offset..<min(offset + 4, extensions.count)] {
                let button = NSButton(checkboxWithTitle: ".\(extensionName)", target: nil, action: nil)
                button.state = selected.contains(extensionName) ? .on : .off
                buttons[extensionName] = button
                row.addArrangedSubview(button)
            }
            row.addArrangedSubview(NSView())
            row.arrangedSubviews.last?.setContentHuggingPriority(.defaultLow, for: .horizontal)
            return row
        }
        extensionButtons[group] = buttons
        let stack = NSStackView(views: [heading] + rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        return stack
    }

    private func customExtensionRow(title: String, field: NSTextField) -> NSView {
        field.placeholderString = "例如：avif, raw"
        let label = NSTextField(labelWithString: title)
        label.setContentHuggingPriority(.required, for: .horizontal)
        let row = NSStackView(views: [label, field])
        row.orientation = .horizontal
        row.spacing = 12
        return row
    }

    private func otherExtensionRow() -> NSView {
        otherTextExtensions.placeholderString = "* 代表所有其他文件；或填写 txt, md, log"
        let row = NSStackView(views: [otherTextEnabled, otherTextExtensions])
        row.orientation = .horizontal
        row.spacing = 12
        return row
    }

    private func selectedExtensions(in group: ExtensionGroup) -> Set<String> {
        Set(extensionButtons[group, default: [:]].compactMap { extensionName, button in
            button.state == .on ? extensionName : nil
        })
    }
}
