# Changelog

All notable changes to CloudShelf are documented here.

## 1.1.0 - 2026-08-03

### Added

- Multi-file selection through file-list checkboxes, with `Command-A` to select or clear every visible remote item.
- Per-connection status indicators and a contextual Connect, Disconnect, Cancel, or Reconnect control in the left sidebar.
- Configurable preview, transfer, and sync settings in one settings window.
- Chinese and English interface support. The default language follows macOS; Settings can override it.
- Transfer concurrency controls, individual pause/resume/retry actions, and bulk queue controls.

### Fixed

- The connection sidebar now uses a compact responsive width and avoids squeezing the remote browser with a redundant protocol column.
- Text previews now give the `NSTextView` a tracked document size, so downloaded text is visible instead of rendering as an empty pane.
- Paused FTP and SFTP downloads use a task-specific partial file. A new download cannot consume stale bytes from an older task.
- Transfers targeting the same local or remote path are serialized to prevent concurrent writes from corrupting a file.
- Rapid pause/resume interactions honor the last requested state, including while a process is still stopping.
- Process cancellation is synchronized with process startup, and retry behavior is restricted to transfer requests rather than destructive remote commands.
- SFTP transfer progress is parsed from its progress meter when the server supplies it.
