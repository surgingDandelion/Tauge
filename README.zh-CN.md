# Tauge

**本地优先的 macOS SSH / SFTP 客户端。** 原生 SwiftUI、分屏工作区、多服务器
SFTP 与服务器间直传，凭据始终留在你的 Mac 上。

[![CI](https://github.com/surgingDandelion/Tauge/actions/workflows/ci.yml/badge.svg)](https://github.com/surgingDandelion/Tauge/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/surgingDandelion/Tauge?display_name=tag)](https://github.com/surgingDandelion/Tauge/releases/latest)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/macOS-13%2B-black)](https://www.apple.com/macos/)

[English](README.md) · 简体中文

Tauge 只使用 SwiftPM 构建，界面由 SwiftUI 与 AppKit 编写，终端基于
[SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)，SSH 基于一份内置的
[SwiftNIO SSH](Vendor/swift-nio-ssh) 分支。没有账号、没有同步服务、没有遥测。
主机、密钥与传输记录保存在本地 SQLite 数据库，敏感凭据保存在 macOS 钥匙串。

> Tauge 早期内部代号为 **ShellX**。Bundle 标识符、钥匙串服务名与数据目录仍保留
> `shellx` 前缀，以保证升级不会丢失数据。

![Tauge 起始页：按项目分组的主机，带标签与最近使用状态](docs/images/start-page.png)

## 安装

从 [Releases](https://github.com/surgingDandelion/Tauge/releases/latest) 下载
最新的 `Tauge-<version>.dmg`，将 Tauge 拖入「应用程序」后启动。

若 macOS 拒绝首次启动，请参考
[docs/INSTALL.md](docs/INSTALL.md#if-macos-blocks-the-first-launch)。当发布流程配置了
Developer ID 凭据时，发布包会经过公证；否则为 ad-hoc 签名，需要一次性手动放行。

系统要求：macOS 13 Ventura 及以上，Apple 芯片或 Intel 均可。

## 功能

### 主机与分组

- 无限层级分组，用户、端口、私钥、代理、跳板机、终端主题与编码等默认值可继承。
- 拖拽排序、跨分组移动、收藏与最近 20 台主机；支持按名称、地址、用户名、标签、
  备注与拼音首字母搜索。
- 导入 `~/.ssh/config`（Host、HostName、User、Port、IdentityFile、ProxyJump）
  或 Termius 保险库。Termius 数据使用钥匙串中的 `localKey` 在本地解密，绝不
  上传；导入前可预览，自动去重，并可选择导入连接历史中的未保存主机。

### 终端

- 基于 SwiftTerm 的 xterm-256color 终端，支持真彩色、鼠标上报、括号粘贴、
  OSC 8 超链接与 OSC 52 剪贴板。
- 标签页支持 `⌘T`、`⌘W`、`⌘1…9`、拖拽重排；增量查找（`⌘F`）、
  选中即复制、右键粘贴、多行粘贴确认、Option 作为 Meta。
- 六套配色主题，可调字体、字号、行高与透明度，回滚缓冲 10,000 行。
- 断线后保留屏幕内容，并按指数退避自动重连。
- 可选会话日志写入 `~/Logs/<host>/<date>.log`，支持脱敏。

### 工作区

- 一个工作区就是包含多个 SSH 窗格的标签页；每个窗格拥有独立的查找栏、SFTP
  浏览器、拖放目标、日志与重连行为。
- 将窗格标题拖到另一个窗格的边缘即可分屏，拖到中心则交换位置。分割线会吸附到
  25/33/50/67/75%，双击复位，并显示实时参考线。双击标题可最大化窗格。
- 新建工作区面板可选择布局，并按分组多选服务器。
- 布局、打开的窗格与每个窗格的 SFTP 状态会跨启动保留。窗格改动会暂存，直到
  `⌘S` 保存或离开工作区。

### SFTP 与传输

- 本地窗格加任意数量的远程窗格；主窗格复用终端的 SSH 连接，额外窗格各自建连。
- 在两个远程窗格之间拖拽即可服务器间直传，不经过本地磁盘；拖到 Finder 为下载，
  从 Finder 拖入为上传。
- 路径栏支持 `~` 与相对路径、后退/前进/上一级、显示隐藏文件，并记录每台主机
  最近 50 个目录。
- 内置编辑器可打开 2 MB 以内的文件，支持 chmod、重命名、删除与新建目录。
- 传输引擎支持 1–4 个并发任务、32 KiB 分块、下载断点续传、三次重试、
  暂停/继续/取消，以及覆盖、跳过、重命名、仅较新等冲突策略。
- 传输中心持久化历史记录，全局进度浮层在 SFTP 窗格之外也保持可见。

### 安全与连接

- 支持密码或私钥认证：Ed25519、ECDSA P-256/P-384/P-521，以及 OpenSSH、
  PKCS#8、SEC1 格式的 RSA（仅限未加密 PEM）。
- 密码与私钥口令保存在钥匙串，可访问性为
  `kSecAttrAccessibleAfterFirstUnlock`；数据库中不含明文凭据。
- 首次连接采用 TOFU 主机密钥校验，展示 SHA-256 与 MD5 指纹；密钥变化时阻止
  连接，并并列显示新旧指纹。
- 最多三级跳板机，基于 `direct-tcpip`，支持逐跳独立凭据或复用目标凭据。
- 支持 HTTP CONNECT（Basic）与 SOCKS5/SOCKS5h（RFC 1929）代理，作用域可设为主机、
  分组或全局（主机 > 分组 > 全局）。

### 界面

- 起始页左侧为工作区/分组，右侧为可拖拽的主机卡片；侧边栏可隐藏；状态栏显示
  连接路径、编码与传输速度。
- 命令面板（`⌘K`）统一检索分组树、工作区与命令。
- 菜单栏常驻项可打开主窗口、新建终端/SFTP 标签、打开命令面板与传输中心。
- 单实例运行；关闭主窗口即干净退出。
- 内置英文与简体中文，可在「设置 → 通用」中即时切换，无需重启。

## 从源码构建

依赖：macOS 13+、Command Line Tools（`xcode-select --install`），首次解析依赖
需要网络。项目使用 Swift 6.4 / macOS 26 开发，部署目标为 macOS 13。

```bash
git clone https://github.com/surgingDandelion/Tauge.git
cd Tauge

export TMPDIR="$PWD/.build/tmp"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/modulecache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/modulecache"

swift build --disable-sandbox
./scripts/build-app.sh release
open dist/Tauge.app
```

只有在 `sandbox-exec` 受限的环境（例如在另一层沙箱中构建）才需要
`--disable-sandbox`。Command Line Tools SDK 不包含 SwiftUI 的宏插件，因此界面使用
[`Sources/ShellXApp/ViewState.swift`](Sources/ShellXApp/ViewState.swift) 中等价的
属性包装器。

通用二进制构建：

```bash
TAUGE_ARCHS="arm64 x86_64" ./scripts/build-app.sh release
```

## 自检

Command Line Tools 不提供 XCTest 与 swift-testing，因此自检是一个可执行目标：

```bash
swift run --disable-sandbox ShellXChecks
```

目前包含 **超过 2,000 项检查**，覆盖 SFTP v3 编解码往返、`ssh_config` 解析
（OpenSSH 首值优先）、分组继承与跳板链、工作区分割树计算、传输引擎行为
（续传、递归、冲突、进度）、RSA 公钥与 `ssh-keygen` 指纹比对、
XSalsa20-Poly1305 测试向量、本地化表完整性，以及针对进程内模拟 SSH 服务器的
端到端检查（握手、公钥认证、PTY shell、SFTP 子系统、`rsa-sha2-256/512`、
一跳与两跳 `direct-tcpip` 隧道）。

可选的实机检查默认跳过，需设置环境变量：`SHELLX_LIVE_SSH`、
`SHELLX_REAL_JUMP`、`SHELLX_REAL_TRANSFER`、`SHELLX_TERMIUS`。

## 签名与公证

- 本地开发：运行 `./scripts/setup-signing.sh` 创建自签名证书，使钥匙串的
  「始终允许」在重新构建后继续有效。
- 分发：运行 `./scripts/package-release.sh` 构建通用二进制；若提供
  `TAUGE_SIGN_IDENTITY` 则签名，若提供 `TAUGE_NOTARY_*` 则公证，最终生成
  DMG、ZIP 与 `SHA256SUMS.txt`。
- CI：[release 工作流](.github/workflows/release.yml) 从仓库 Secrets 导入
  Developer ID 证书，在推送 `v*` 标签时构建并发布。未配置 Secrets 时发布
  ad-hoc 签名包，[docs/INSTALL.md](docs/INSTALL.md) 说明了首次启动的手动放行步骤。

## 代码结构

```
Sources/ShellXKit/
  Model/          模型、分组继承、代理与跳板解析
  Store/          SQLite（WAL）目录、已知主机、传输历史、设置
  Security/       钥匙串、凭据存储、AES-256-GCM 导出加密
  SSHConfig/      ~/.ssh/config 解析与 Host * 默认值
  SFTP/           SFTP v3 编解码与并发客户端
  SSH/            NIOSSH 连接、代理、跳板链、主机密钥校验
  Transfer/       分块传输引擎、续传、冲突、重试
  FileBrowser/    本地文件服务、路径与权限格式化
  Import/         Termius 保险库读取（XSalsa20-Poly1305）与映射
  Localization/   en.json；L() 运行时查找与语言即时切换
Sources/ShellXApp/  SwiftUI 视图、AppState、工作区、终端桥接
Sources/ShellXChecks/ 可执行自检套件
Vendor/             SwiftTerm 与打过补丁的 swift-nio-ssh 分支
```

## 本地化

中文源字符串即翻译键，英文位于
[`Sources/ShellXKit/Localization/en.json`](Sources/ShellXKit/Localization/en.json)。
所有用户可见字符串都用 `L("中文")` 包裹，语言设置即时生效、无需重启；缺少译文
时回退到中文，而不是显示键名。新增字符串前请阅读
[CONTRIBUTING.md](CONTRIBUTING.md#localisation)。

## 已知限制

- **SSH 功能：** SwiftNIO SSH 未实现 `keyboard-interactive` 认证，也不暴露协商
  算法与 RTT。暂未接入 `SSH_AUTH_SOCK` agent 与 HTTPS 代理。
- **老旧服务器：** 不提供 SHA-1 `ssh-rsa`/`ssh-dss` 签名；只支持这些算法的
  服务器无法连接，错误会以密钥交换失败呈现，而不是含糊的 EOF。
- **私钥：** 不支持加密 PEM，请用 `ssh-keygen -p` 转换或改用 OpenSSH 格式。
- **终端：** 字节流按 UTF-8 渲染，编码设置仅影响从 SFTP 打开的文本；无法导入
  iTerm2 配色。
- **工作区：** 窗格由推导网格加手动分割组成，并非任意嵌套树；回滚内容不跨重启
  保留。
- **SFTP：** 大目录一次性加载，未做虚拟化与键盘导航；不支持把目录拖到 Finder
  （请使用传输中心或第二个窗格）。
- **Termius 导入：** 本地 Termius 数据库只保存分组名、不保存层级，导入的主机会
  归入同一个分组。

更详细的需求对照见 [docs/PRD-COVERAGE.zh-CN.md](docs/PRD-COVERAGE.zh-CN.md)。

## 隐私

Tauge 不包含统计分析、崩溃上报或更新检查。网络流量只发往你配置的 SSH 服务器与
代理。Termius 导入仅读取本地保险库，不会上传任何数据。会话日志默认关闭，保存在
`~/Logs` 下。

数据位置：

- 数据库：`~/Library/Application Support/ShellX/shellx.sqlite`
- 导入的私钥：`~/Library/Application Support/ShellX/Keys`
- 日志：`~/Logs/<host>/<date>.log`
- 凭据：macOS 钥匙串（服务名 `shellx`）

环境变量 `SHELLX_CATALOG_PATH`（或偏好键 `ShellXCatalogPath`）可覆盖数据库位置；
「设置 → 高级」中可迁移数据目录。

## 参与贡献

欢迎提交 Issue 与 Pull Request。请先阅读 [CONTRIBUTING.md](CONTRIBUTING.md) 与
[CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md)；安全问题请按 [SECURITY.md](SECURITY.md)
私下报告。

## 许可证

[MIT](LICENSE) © 2026 surgingDandelion。

本项目建立在 [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)、
[SwiftNIO SSH](https://github.com/apple/swift-nio-ssh)、SwiftNIO、
[swift-crypto](https://github.com/apple/swift-crypto) 与
[swift-log](https://github.com/apple/swift-log) 之上，详见
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
