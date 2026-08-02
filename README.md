# CloudShelf

CloudShelf is a native macOS FTP, SFTP, and WebDAV workspace manager. It presents remote servers as persistent workspaces inside its own file-manager window, so users can work with several servers at once without using Finder's network-volume APIs.

[中文文档](README.zh-CN.md)

## What it does

- Connect and switch between multiple FTP, SFTP, and WebDAV servers.
- Browse remote folders with directory navigation, sortable file-style columns, drag-and-drop upload, drag files out to Finder, and a transfer queue with progress and transfer rate.
- Show a Linux-style `..` parent-directory entry at the top of every non-root folder.
- Upload and download files and folders; folder uploads preserve the selected folder's hierarchy and create empty folders; create folders; rename, copy, move, and recursively delete remote content.
- Right-click remote files, folders, and connections for common actions. Inspect one selected remote item with `Command-I` to see its path, type, modified date, and size; folder sizes are calculated on demand.
- Save passwords in macOS Keychain. Connection metadata is stored separately in Application Support.
- Support SFTP password, SSH agent, and private-key authentication.
- Store SFTP host fingerprints in CloudShelf's own `known_hosts` file. Choose either strict checking or accepting a host key on first connection.
- Add, edit, enable, disable, remove, and run multiple local-folder sync rules per connection. Each rule independently selects local upload, remote download, local deletion to remote, and remote deletion to local; select remote folders from the server browser and optionally trigger rules after local changes.

## No FUSE and no Finder mount API

This project deliberately does **not** use macFUSE, Finder's network-mount APIs, `NetFS`, or a File Provider extension.

That means a connection is mounted into the **CloudShelf application workspace**, not exposed as a `/Volumes/...` disk in Finder. macOS does not permit a third-party process to create a system filesystem mount without a filesystem layer such as macFUSE or a system extension/File Provider. This boundary is intentional: all protocol handling, navigation, transfers, and syncing stay under the app's control instead of relying on Finder's remote-volume stack.

## Protocol layer

CloudShelf uses its own connection and operation model, with macOS command-line protocol engines for wire compatibility:

| Protocol | Engine | Operations |
| --- | --- | --- |
| FTP / FTPS | `/usr/bin/curl` | LIST, upload, download, MKD, DELE/RMD, RNFR/RNTO |
| WebDAV / HTTPS | `/usr/bin/curl` plus in-app DAV XML parser | PROPFIND, upload, download, MKCOL, DELETE, MOVE, COPY |
| SFTP | `/usr/bin/sftp` | list, put/get, mkdir, rm/rmdir, rename |

No Finder operation is used. Sensitive command arguments are avoided: curl credentials go through a permission-restricted temporary config file, and SFTP password auth uses a short-lived `SSH_ASKPASS` bridge. These temporary files are removed after the operation completes. Large command output is redirected to temporary files rather than pipes, preventing a full remote directory listing from blocking a transfer process.

## Requirements

- macOS 14 or newer
- Apple Command Line Tools, which provide Swift, `curl`, and OpenSSH `sftp`
- Network access to the remote server

No Homebrew package, kernel extension, administrator privilege, or `sudo` is needed.

## Build and run

From this project directory:

```sh
make build       # Build the Release executable
make test        # Run fourteen core smoke assertions
make bundle      # Create dist/CloudShelf.app
make dmg         # Create a universal DMG in dist/
make install     # Install the app in /Applications
open dist/CloudShelf.app
```

For a Debug run:

```sh
make run
```

The app bundle is ad-hoc/local only. Sign and notarize it with your Apple Developer identity before distributing it outside this Mac.

## Data locations

- Connection metadata: `~/Library/Application Support/CloudShelf/connections.json`
- Passwords: macOS Keychain service `com.cloudshelf.credentials`
- SFTP host keys: `~/Library/Application Support/CloudShelf/known_hosts`
- Per-rule deletion state: `~/Library/Application Support/CloudShelf/SyncState/`

Passwords are not written to `connections.json`.

## Sync behavior

Sync is conservative by design:

- It creates needed remote folders and transfers changed files.
- A WebDAV `MKCOL` response of `405 Method Not Allowed` is accepted when a follow-up listing confirms that the folder already exists.
- Local-to-remote and remote-to-local deletion propagation are separate opt-in operations.
- Deletion propagation starts only after one successful sync has recorded the rule's state. It removes only a path present in that recorded state and now missing from the selected source, so turning it on cannot erase unrelated files during the first run.
- When an endpoint lacks modification timestamps, same-size files are treated as unchanged to prevent repeat transfers on every interval.
- Only one run of a given sync rule can be active at a time.
- When enabled, local-change detection scans every five seconds and waits two seconds after the last detected change before starting a rule that uploads local changes or propagates local deletions.

Folder uploads skip only symbolic links and other non-regular filesystem entries. Regular files, hidden files, nested folders, and empty folders are included. Remote files can be dragged from CloudShelf to Finder; remote folders must still be downloaded with the Download command so their hierarchy can be created reliably.

For bidirectional folders with important concurrent edits, use the `Keep newest` policy only when both servers return reliable modification times. Otherwise choose a one-way rule or keep a versioned backup.

## Project layout

```text
Sources/CloudShelf/Domain            Profiles, paths, remote-item models
Sources/CloudShelf/Infrastructure    FTP/WebDAV/SFTP clients, Keychain, process runner, sync engine
Sources/CloudShelf/App               Workspace and transfer state
Sources/CloudShelf/AppKit            Native macOS file-manager interface
Sources/CloudShelfSmoke              Framework-free core smoke checks
```

## Known constraints

- System-wide `/Volumes` mounting is intentionally out of scope because macFUSE and Finder/File Provider APIs are excluded.
- FTP directory listings vary across servers; unusual non-Unix LIST formats can provide less file metadata than WebDAV or SFTP.
- SFTP's default `Accept new keys` policy is convenient for initial setup. Use `Strict` after the server key is known.
- Remote integration checks need a real server and are not run by the bundled local smoke check.
