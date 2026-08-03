import AppKit
import Foundation

enum AppLanguage: String, CaseIterable {
    case system
    case chinese
    case english

    var displayName: String {
        switch self {
        case .system: return "跟随系统"
        case .chinese: return "中文"
        case .english: return "English"
        }
    }
}

@MainActor
final class AppLocalization {
    static let shared = AppLocalization()
    static let didChangeNotification = Notification.Name("CloudShelf.languageDidChange")

    private let defaults = UserDefaults.standard
    private let languageKey = "CloudShelf.language"

    private init() {}

    var language: AppLanguage {
        guard let value = defaults.string(forKey: languageKey), let language = AppLanguage(rawValue: value) else {
            return .system
        }
        return language
    }

    var isEnglish: Bool {
        switch language {
        case .english: return true
        case .chinese: return false
        case .system:
            return !(Locale.preferredLanguages.first?.lowercased().hasPrefix("zh") ?? false)
        }
    }

    func setLanguage(_ language: AppLanguage) {
        defaults.set(language.rawValue, forKey: languageKey)
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }

    func text(_ chinese: String) -> String {
        guard isEnglish else { return chinese }
        return englishText[chinese] ?? chinese
    }

    func status(_ chinese: String) -> String {
        guard isEnglish else { return chinese }
        if let exact = englishText[chinese] { return exact }
        var result = chinese
        for (source, translation) in englishFragments {
            result = result.replacingOccurrences(of: source, with: translation)
        }
        return result
    }

    func label(_ key: String) -> String {
        guard isEnglish else {
            switch key {
            case "connect": return "连接"
            case "disconnect": return "断开连接"
            case "reconnect": return "重新连接"
            case "cancelConnection": return "取消连接"
            default: return key
            }
        }
        switch key {
        case "connect": return "Connect"
        case "disconnect": return "Disconnect"
        case "reconnect": return "Reconnect"
        case "cancelConnection": return "Cancel Connection"
        default: return text(key)
        }
    }

    func localize(view: NSView) {
        if let textField = view as? NSTextField {
            if !textField.isEditable {
                textField.stringValue = text(textField.stringValue)
            }
            textField.placeholderString = textField.placeholderString.map(text)
        }
        if let button = view as? NSButton {
            button.title = text(button.title)
            button.toolTip = button.toolTip.map(text)
        }
        if let popup = view as? NSPopUpButton {
            popup.itemArray.forEach { item in
                item.title = text(item.title)
                item.toolTip = item.toolTip.map(text)
            }
        }
        if let table = view as? NSTableView {
            table.tableColumns.forEach { $0.title = text($0.title) }
        }
        view.subviews.forEach { localize(view: $0) }
    }

    func localize(menu: NSMenu) {
        menu.title = text(menu.title)
        for item in menu.items {
            item.title = text(item.title)
            if let submenu = item.submenu { localize(menu: submenu) }
        }
    }

    private let englishText: [String: String] = [
        "未选择连接": "No connection selected",
        "连接": "Connection",
        "连接失败": "Connection failed",
        "正在连接": "Connecting",
        "已连接": "Connected",
        "已断开": "Disconnected",
        "连接中": "Connecting",
        "新建连接": "New Connection",
        "编辑连接": "Edit Connection",
        "移除连接": "Remove Connection",
        "删除连接": "Delete Connection",
        "重新连接": "Reconnect",
        "断开连接": "Disconnect",
        "选择一个连接后即可连接": "Select a connection to connect",
        "选择连接": "Select Connection",
        "名称": "Name",
        "协议": "Protocol",
        "服务器 URL": "Server URL",
        "用户名": "Username",
        "认证方式": "Authentication",
        "密码": "Password",
        "密码（留空不改）": "Password (leave blank to keep)",
        "输入密码": "Enter password",
        "留空则保留已保存的密码": "Leave blank to keep the saved password",
        "私钥路径": "Private key path",
        "主机密钥": "Host key",
        "严格校验": "Strict",
        "首次接受新密钥": "Accept new keys",
        "连接设置": "Connection Settings",
        "保存": "Save",
        "取消": "Cancel",
        "关闭": "Close",
        "好": "OK",
        "移除": "Remove",
        "编辑": "Edit",
        "文件": "File",
        "视图": "View",
        "文件夹": "Folder",
        "上级目录": "Parent directory",
        "返回上级目录": "Go to Parent Directory",
        "修改时间": "Modified",
        "大小": "Size",
        "类型": "Type",
        "上级": "Up",
        "打开": "Open",
        "上传": "Upload",
        "下载": "Download",
        "下载到此处": "Download Here",
        "剪切": "Cut",
        "复制": "Copy",
        "粘贴": "Paste",
        "重命名": "Rename",
        "复制到指定文件夹": "Copy to Folder",
        "移动到指定文件夹": "Move to Folder",
        "移动": "Move",
        "删除": "Delete",
        "属性": "Properties",
        "全选": "Select All",
        "取消全选": "Deselect All",
        "刷新": "Refresh",
        "新建文件夹": "New Folder",
        "显示或隐藏左侧栏": "Show or Hide Connection Sidebar",
        "显示或隐藏左侧连接栏": "Show or Hide Connection Sidebar",
        "显示或隐藏右侧预览栏": "Show or Hide Preview Sidebar",
        "显示或隐藏底部传输栏": "Show or Hide Transfer Pane",
        "显示预览栏": "Show Preview Pane",
        "传输": "Transfers",
        "任务": "Task",
        "状态": "Status",
        "进度": "Progress",
        "速率": "Speed",
        "操作": "Action",
        "全部开始": "Start All",
        "全部停止": "Stop All",
        "重试失败": "Retry Failed",
        "清除已结束": "Clear Finished",
        "同步": "Sync",
        "立即同步": "Sync Now",
        "自动同步：开": "Auto Sync: On",
        "自动同步：关": "Auto Sync: Off",
        "设置": "Settings",
        "打开设置…": "Open Settings…",
        "预览": "Preview",
        "文件预览": "File Preview",
        "语言": "Language",
        "跟随系统": "Follow System",
        "中文": "Chinese",
        "启用文件预览": "Enable File Preview",
        "最大大小（MB）": "Maximum Size (MB)",
        "自定义图片": "Custom Image Extensions",
        "自定义视频": "Custom Video Extensions",
        "自定义音频": "Custom Audio Extensions",
        "文档": "Documents",
        "其他": "Other",
        "例如：avif, raw": "For example: avif, raw",
        "* 代表所有其他文件；或填写 txt, md, log": "* means all other files; or enter txt, md, log",
        "同时传输任务数": "Concurrent transfers",
        "每次下载时询问位置": "Ask for a location for every download",
        "默认下载位置": "Default download location",
        "选择…": "Choose…",
        "清除": "Clear",
        "未设置": "Not set",
        "同时传输的任务越多，速度不一定越快。建议普通网络使用 2 到 4 个任务；不稳定网络请选择 1 到 2 个任务。暂停的文件任务会在协议支持时从现有进度继续。": "More concurrent transfers do not always increase speed. Use 2 to 4 tasks on a typical network, or 1 to 2 on an unstable network. Paused file transfers resume from existing progress when the protocol supports it.",
        "选择一个文件以预览": "Select a file to preview",
        "预览已关闭": "Preview is disabled",
        "正在下载预览…": "Downloading preview…",
        "预览失败": "Preview failed",
        "此扩展名未在预览设置中启用": "This extension is not enabled for preview",
        "服务器未提供文件大小，未下载预览": "The server did not provide a file size; preview was not downloaded",
        "无法读取图片": "Unable to read image",
        "无法读取文本": "Unable to read text",
        "无法读取 PDF": "Unable to read PDF",
        "图片": "Image",
        "视频": "Video",
        "音频": "Audio",
        "文本": "Text",
        "关于 CloudShelf": "About CloudShelf",
        "退出 CloudShelf": "Quit CloudShelf",
        "帮助": "Help",
        "中文使用说明": "Chinese User Guide",
        "远程文件工作区。": "Remote file workspace.",
        "操作失败": "Operation Failed",
        "计算文件夹大小": "Calculate Folder Size",
        "尚未计算": "Not calculated",
        "修改日期": "Modified Date",
        "位置": "Location",
        "传输队列": "Transfer Queue",
        "选择本地文件夹": "Choose Local Folder",
        "选择远端文件夹": "Choose Remote Folder",
        "选择此文件夹": "Choose This Folder",
        "添加同步规则": "Add Sync Rule",
        "编辑同步规则": "Edit Sync Rule",
        "自动同步": "Automatic Sync",
        "执行频率": "Frequency",
        "本地新增和修改上传到远端": "Upload local additions and changes to the remote server",
        "远端新增和修改下载到本地": "Download remote additions and changes locally",
        "本地删除时删除远端对应项目": "Delete matching remote items when deleted locally",
        "远端删除时删除本地对应项目": "Delete matching local items when deleted remotely",
        "检测到本地文件夹变化后自动同步": "Automatically sync after local folder changes",
        "5 分钟": "5 minutes",
        "15 分钟": "15 minutes",
        "30 分钟": "30 minutes",
        "1 小时": "1 hour",
        "从未": "Never",
        "新名称": "New name",
        "文件夹名称": "Folder name",
        "输入远端目标文件夹。": "Enter the remote destination folder.",
        "/目标文件夹": "/destination-folder",
        "请输入包含协议、主机、端口和路径的完整 URL。": "Enter a complete URL with a scheme, host, port, and path.",
        "为保护密码，编辑连接时不会显示钥匙串中的现有密码。": "For security, the saved Keychain password is not shown while editing a connection.",
        "请填写连接名称。": "Enter a connection name.",
        "请选择连接协议。": "Select a connection protocol.",
        "请输入包含协议和主机的完整服务器 URL。": "Enter a complete server URL with a scheme and host.",
        "请在密码字段填写密码，不要把密码写入 URL。": "Enter the password in the password field, not in the URL.",
        "FTP 连接请使用 ftp:// 或 ftps:// URL。": "FTP connections require an ftp:// or ftps:// URL.",
        "SFTP 连接请使用 sftp:// URL。": "SFTP connections require an sftp:// URL.",
        "WebDAV 连接请使用 http:// 或 https:// URL。": "WebDAV connections require an http:// or https:// URL.",
        "请填写本地和远端文件夹。": "Enter both local and remote folders.",
        "请至少选择一项同步操作。": "Select at least one sync action.",
        "正在加载…": "Loading…",
        "加载失败": "Load failed",
        "最大预览文件大小必须是大于 0 的整数。": "The maximum preview file size must be an integer greater than 0.",
        "选择下载位置": "Choose Download Location",
        "添加规则": "Add Rule",
        "启用/停用": "Enable/Disable",
        "立即执行": "Run Now",
        "已启用": "Enabled",
        "已停用": "Disabled",
        "本地文件夹": "Local Folder",
        "远端文件夹": "Remote Folder",
        "远端": "Remote",
        "同步操作": "Sync Actions",
        "执行方式": "Schedule",
        "上次同步": "Last Sync",
        "本地上传": "Local upload",
        "远端下载": "Remote download",
        "本地删除 -> 远端": "Local delete -> Remote",
        "远端删除 -> 本地": "Remote delete -> Local",
        "同步规则属于某一台服务器。关闭设置后，在左侧选择并连接服务器，再打开“设置 > 同步”。": "Sync rules belong to a server. Close Settings, select and connect a server in the sidebar, then open Settings > Sync.",
        "选择一个已连接的服务器": "Select a connected server",
        "没有选择": "None",
        "未选择": "None",
        "完成": "Done",
        "暂停": "Pause",
        "继续": "Resume",
        "重试": "Retry",
        "处理中": "Processing"
    ]

    private let englishFragments: [(String, String)] = [
        ("正在加载", "Loading"),
        ("正在连接", "Connecting"),
        ("已连接", "Connected"),
        ("已断开", "Disconnected"),
        ("连接失败", "Connection failed"),
        ("正在下载预览", "Downloading preview"),
        ("预览失败", "Preview failed"),
        ("此扩展名未在预览设置中启用", "This extension is not enabled for preview"),
        ("服务器未提供文件大小，未下载预览", "The server did not provide a file size; preview was not downloaded"),
        ("文件超过", "File exceeds"),
        ("预览上限", "preview limit"),
        ("无法读取图片", "Unable to read image"),
        ("无法读取文本", "Unable to read text"),
        ("无法读取 PDF", "Unable to read PDF"),
        ("图片", "Image"),
        ("视频", "Video"),
        ("音频", "Audio"),
        ("文本", "Text"),
        ("无法读取", "Unable to read"),
        ("正在下载", "Downloading"),
        ("正在上传", "Uploading"),
        ("已暂停", "Paused"),
        ("等待继续", "Waiting to resume"),
        ("等待重试", "Waiting to retry"),
        ("下载完成", "Download complete"),
        ("上传完成", "Upload complete"),
        ("复制完成", "Copy complete"),
        ("移动完成", "Move complete"),
        ("每", "Every"),
        ("分钟", " min"),
        ("小时", " hr"),
        ("本地上传", "Local upload"),
        ("远端下载", "Remote download"),
        ("本地删除", "Local delete"),
        ("远端删除", "Remote delete"),
        ("服务器：", "Server: "),
        ("未设置", "Not set"),
        ("服务器未提供", "Not provided by server")
    ]
}
