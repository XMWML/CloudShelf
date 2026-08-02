# CloudShelf

CloudShelf 是一个原生 macOS FTP、SFTP、WebDAV 文件管理器。它把每个远程服务器保存在应用自己的工作区中，可以同时维护多个连接、传输任务和同步规则，不依赖 Finder 的网络磁盘功能。

## 功能

- 保存并切换多个 FTP/FTPS、SFTP、WebDAV 连接。
- 以文件管理器方式浏览远端目录，支持双击进入目录、返回上级、刷新和文件信息列。
- 上传、下载、拖拽上传、新建目录、重命名、复制、移动、递归删除。
- 底部传输列表显示上传、下载、复制、移动和同步的状态。
- 每个连接可添加多个本地文件夹同步规则，支持只上传、只下载、双向保留较新版本。
- SFTP 支持密码、SSH Agent、私钥；可选择首次接受服务器主机密钥或严格校验。
- 密码放入 macOS 钥匙串，连接配置与密码分离保存。

## 这不是 Finder 磁盘挂载

本项目明确**不使用** macFUSE、Finder 网络挂载 API、`NetFS` 或 File Provider。因此，连接会挂载到 CloudShelf 的应用内工作区，而不会显示为 Finder 里的 `/Volumes/...` 磁盘。

在排除 FUSE、File Provider 和系统文件系统扩展的前提下，macOS 不允许普通进程创建真正的系统级文件系统挂载点。CloudShelf 将协议、文件操作、同步和错误处理都放在应用内部，避免依赖 Finder 的远程卷栈。

## 如何使用

1. 打开 `dist/CloudShelf.app`。首次启动会显示空的文件管理器窗口。
2. 点击左下角 **新建连接** 或工具栏第一个加号。
3. 填写连接名称、协议、主机、端口、用户名和远端根目录。
4. FTP/FTPS/WebDAV 选择“密码”并输入密码；SFTP 可以选择“密码”、“SSH Agent”或“私钥”。
5. 点“保存”。连接会出现在左侧列表，并立即尝试连接。成功后在左侧选中它即可浏览远端文件。
6. 工具栏提供上级目录、刷新、新建文件夹、上传、下载、复制、移动、删除和同步操作。也可以直接把 Finder 中的文件拖到右侧文件列表上传。

### 带路径的 WebDAV 地址

WebDAV 的“服务器 / WebDAV URL”字段可直接填写完整地址。以下地址可以直接使用：

```text
http://[2409:8a55:4e87:a560:aaae:68de:76eb:5550]:5244/dav
```

选择 `WebDAV` 协议后粘贴这条地址即可。应用会自动识别 IPv6、端口 `5244`、`http` 协议和 `/dav` 根路径；“端口”字段填写 `5244` 或保留默认值都不会覆盖 URL 中的端口，“远端根目录”保持 `/`。

### 快捷键与菜单

- `Command-C`：复制所选远端文件到应用内剪贴板。
- `Command-X`：剪切所选远端文件。
- `Command-V`：在当前远端文件夹粘贴。跨服务器粘贴会提示先下载再上传。
- `Command-A`：全选当前列表。
- `Command-N`：新建连接；`Command-Shift-N`：新建文件夹；`Command-R`：刷新。

所有连接、文件、视图、同步与帮助操作也都可以从菜单栏进入。

### 自动同步

1. 在左侧选中已连接的服务器。
2. 点击工具栏的循环箭头。如果还没有同步规则，会先要求选择本地文件夹。
3. 选择本地文件夹后，设置远端目录、同步方向和执行频率，点击 **添加规则**。
4. 以后点击循环箭头会立即执行第一条启用的规则；应用运行期间也会按设定周期执行。

同步策略默认很保守：不会自动删除本地或远端文件。没有可靠修改时间的服务器会以文件大小为准，避免每轮重复传输。

## 协议实现

| 协议 | 传输引擎 | 支持的远端操作 |
| --- | --- | --- |
| FTP / FTPS | `/usr/bin/curl` | 列表、上传、下载、建目录、删除、重命名 |
| WebDAV / HTTPS | `/usr/bin/curl` + 应用内 DAV XML 解析 | PROPFIND、上传、下载、MKCOL、DELETE、MOVE、COPY |
| SFTP | `/usr/bin/sftp` | 列表、上传、下载、建目录、删除、重命名 |

这些是协议传输层，并不调用 Finder 操作。curl 凭据通过权限受限的临时配置文件传递；SFTP 密码使用短生命周期的 `SSH_ASKPASS` 桥接。所有临时文件都会在操作结束后删除。命令输出会写入临时文件，避免大目录列表填满管道后卡住。

## 安全与数据位置

- 连接配置：`~/Library/Application Support/CloudShelf/connections.json`
- 密码：macOS 钥匙串服务 `com.cloudshelf.credentials`
- SFTP 主机密钥：`~/Library/Application Support/CloudShelf/known_hosts`

密码不会写入 `connections.json`。初次连接可以使用 `Accept new keys` 保存主机密钥；确认服务器指纹后，建议改为 `Strict`。

连接、文件操作、传输或同步失败时，应用会弹出“操作失败”窗口，显示底层网络、身份验证或协议错误的具体原因。

## 构建与运行

要求：macOS 14 以上，Apple Command Line Tools，系统自带 `curl` 与 OpenSSH `sftp`。不需要 Homebrew、管理员权限、`sudo`、内核扩展或 macFUSE。

```sh
make build       # 构建 Release 可执行文件
make test        # 执行 7 项核心冒烟检查
make bundle      # 生成 dist/CloudShelf.app
open dist/CloudShelf.app
```

调试运行：

```sh
make run
```

当前 `.app` 为本机构建产物。对外分发前应使用 Apple Developer 身份签名并完成公证。

## 已知边界

- 不提供 Finder 中的 `/Volumes` 系统级挂载，这是“不使用 macFUSE/Finder/File Provider”的直接边界。
- 不同 FTP 服务器的 LIST 输出格式不完全一致，非 Unix 风格的服务器可能无法提供完整大小和类型信息。
- 当前本地冒烟检查验证路径、连接默认值和同步规则；真实服务器的集成验证需要使用你的实际服务器进行。
