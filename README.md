# Tauge

本地优先的 macOS SSH / SFTP 客户端（原名 ShellX；界面与菜单栏已更名，内部 target、
`ShellXKit` 模块、Keychain service 与数据目录仍沿用 `shellx` 标识，升级不会丢数据），按 `prd/shellx.md` 的推荐方案 A 实现：
SwiftUI + AppKit + SwiftTerm + SwiftNIO SSH。

## 功能概览

- **主机与分组**：无限层级分组、组默认值向下继承、拖拽排序/移动、收藏与最近 20 台、
  拼音首字母模糊搜索、`~/.ssh/config` 导入（Host/HostName/User/Port/IdentityFile/ProxyJump）。
- **从 Termius 一键导入**（文件 → 从 Termius 导入…、起始页“更多”、侧边栏导入菜单、`⌘K`）：
  Termius 的本地库是加密的 IndexedDB（NaCl secretbox），Tauge 用登录钥匙串里的 Termius `localKey`
  解密（纯 Swift 实现 XSalsa20-Poly1305，不引入 libsodium），同时扫描
  `~/Library/Application Support/Termius/IndexedDB` 与容器副本，自动选能解开的那一份（容器里常是旧副本）。
  导入前会列出主机 / 身份 / 私钥 / known_hosts / 连接记录的条数与主机明细，勾选后写入指定分组：
  地址、端口、用户名、密码（进钥匙串）、私钥（复制到 `~/Library/Application Support/ShellX/Keys`，0600 并登记指纹）、
  known_hosts、启动命令、标签、编码；按 endpoint 去重，重复导入不会产生副本。
  读库在后台线程做，面板立刻出现；6 秒没读完会提示“还在等待钥匙串授权”，30 秒超时改成可重试的提示，
  也可以直接粘贴 `localKey`。`导入` 故意不绑默认回车，避免面板打开时误按回车就批量写库。
  局限：Termius 的分组层级没有存进本地库（只有分组名），所以导入成单一分组；连接历史默认只作参考，
  打开“同时导入连接历史里未保存的主机”才会把历史里的主机也导进来。
- **认证**：密码、私钥（Ed25519 / ECDSA P-256/P-384/P-521，OpenSSH 新格式、PKCS#8、SEC1）；
  密钥口令与主机密码存 Keychain（`kSecAttrAccessibleAfterFirstUnlock`），数据库中不落明文。
- **known_hosts**：首次连接 TOFU，展示 SHA256 指纹；指纹变更时阻断并高亮新旧指纹。
- **终端**：SwiftTerm（xterm-256color、24 位色、鼠标上报、括号粘贴、OSC 8/52）、
  终端不再贴着窗口边缘——内容嵌在圆角卡片里（内外都有留白，卡片底色跟随所选主题）、
  多标签 `⌘T`/`⌘W`/`⌘1..9` 与拖拽重排、增量搜索（`⌘F`，显示命中/总数）、
  选中即复制（拖动过程中就写入剪贴板，指针移出视图也不会漏）、右键直接粘贴
  （vim/tmux/htop 等开启鼠标上报的程序仍把右键交给程序）、
  多行粘贴确认、Option 作为 Meta、六套主题与字体/字号/行高/透明度、10000 行回滚、
  断线保留内容并指数退避重连（附 tmux attach 提示）、会话日志（`~/Logs/{host}/{date}.log`，可脱敏）。
- **键盘焦点**（“有时打不了字”的根因）：SwiftTerm 的视图不会自己成为 first responder，
  所以点击终端、切换标签/工作区窗格、关闭查找栏或任何对话框、从别的 App 切回来时，都会显式把键盘交还给当前终端；
  窗口级 key monitor 还会在按键落到 SwiftUI 宿主视图这类会吞键的响应者时先改派给终端
  （文本框、搜索框、编辑器仍保留自己的按键）。`SHELLX_TRACE_FOCUS=1` 可打印每次焦点决策。
- **起始页**：没有任何标签被选中时（或 `⇧⌘H`、标签栏右侧房子按钮）显示两栏概览——
  左边是可滚动的“工作区 + 分组”清单（工作区一行一个并显示窗格数；分组按层级缩进、右侧只统计该分组自己的主机（子分组主机不重复出现，避免看起来像被复制了两份），
  点一行右边就只显示这个分组），右边是所选分组的主机卡片网格（自适应 240–420pt，名称、地址、分组/跳板/代理/标签、
  上次连接与使用次数；悬停浮出连接与新建 SFTP 按钮，双击连接，右键连接 / 在工作区中打开 / 编辑 / 收藏 / 删除）。
  卡片图标用一组低饱和色（或主机自己的颜色），选中/悬停/描边一律取系统中性色，不再出现默认的系统蓝；
  **卡片可直接拖动**：拖到同组另一张卡上即排序，拖到左侧分组行或组内空白处即移动过去（是移动不是复制，原分组里不会保留），顺序写入 hosts.sort 字段，重启后保持。
  选中带子分组的分组时，标题行右侧还有「含子分组（N）」按钮，可以把子分组的主机一起列出来。
  分组不再往下堆叠，所以有几十个分组也仍是一屏，不会把页面拉成一条长卷。
  新建分组也不再藏在菜单里：左侧“分组”标题右侧有 `+`，分组行右键有“新建子分组 / 重命名 / 删除”（含二次确认与
  “连接组内全部主机”“新建主机到此分组”），选中某个分组时右侧标题行还有「新建子分组」；`⇧⌘N`、文件菜单与 `⌘K`
  命令面板同样能新建分组，新建子分组会自动展开父分组。
  顶栏只有一行：主机/分组/工作区计数、搜索框（匹配名称、地址、用户名、标签、备注与拼音首字母）、
  **「新建 SFTP」**（弹出服务器多选，勾几台就并排挂几个远端面板，见下）、「新建主机」和一个“更多”菜单
  （新建工作区 / 导入 `~/.ssh/config` / 命令面板 / 传输中心 / 设置）；底部只留一行快捷键提示。
  空库时右侧改为“新建主机 / 导入 ~/.ssh/config / 新建工作区”三张引导卡。
  所以即使一个标签都没开，也能从起始页进入工作区或某台主机。
- **侧边栏可隐藏**：主机列表默认收起（起始页已列出全部主机），`⌃⌘S` 或状态栏最左侧按钮随时召回，
  选择写入设置、重启沿用；设置 → 通用里也有开关。分组的新建/改名/删除在侧边栏右键菜单、`⇧⌘N`、
  起始页“分组”栏与 `⌘K` 命令面板都能做。
- **工作区（原“看板”）**：Termius 式多终端工作区——一个工作区里并排多个 SSH 窗格（宫格/分栏，或用左上角切换成“单窗格”并从左侧终端列表里选一台），终端只保留文字内边距、铺满窗格；
  分割条由 AppKit 实现（按窗口坐标计算位移、8pt 视觉槽位、悬停高亮、双击复位 50%），
  拖动时实时磁吸到 25/33/50/67/75% 并显示百分比徽标；把窗格标题栏拖到另一个窗格的
  左/右/上/下边缘即在上/下/左/右新开窗格（拖到中心则交换位置），拖动时有高亮预览区；
  双击窗格标题栏最大化/还原；
  每个窗格就是一条独立会话（自带 `⌘F` 查找、拖文件上传、会话日志、断线重连），
  窗格标题两行显示主机名与地址（悬停才浮出按钮），右上角 SFTP 按钮可**只在这个窗格**打开浏览器，
  因此可以一边左窗格跑命令、右窗格挂 SFTP，互不干扰。
  **工作区就是标签栏里的一个标签**（网格图标 + 名称），和普通连接并排：点它切到分屏，点普通标签就回到单会话；
  标签栏右侧「工作区」菜单可新建或打开已有工作区，`⇧⌘B` 新建工作区；
  **新建工作区是一个表单**：名称、布局（宫格/单窗格）、勾选要打开的服务器（按分组分节，可“选择该组”或全选）、
  “创建后立即连接”——一次把一组服务器铺成宫格，不用一台台添加；
  「添加主机」菜单里也能直接“整组添加：<分组>”，或从服务器列表里挑；
  主机右键「在工作区中打开」把该主机加为窗格（持久化到 `boards` 表，重启恢复布局、开着的标签与窗格）。
  **窗格增删不会立刻落库**：标题栏出现橙点「未保存」，点它或按 `⌘S` 保存（菜单「文件 → 保存工作区」同样可用）；
  拖动分割条这类纯布局改动仍即时保存；切换工作区、关闭工作区标签或退出应用时会自动提交未保存的改动。
- **SFTP 独立标签**：SFTP 可以不依附终端单独开成一个标签（起始页顶栏「新建 SFTP」、标签栏 `+` → 新建 SFTP 标签、主机右键、
  起始页卡片上的“新建 SFTP 标签”；顶栏那个会先弹服务器多选，勾选多台后一个标签里直接铺开对应数量的远端面板），一个标签里同时挂多台服务器，任意两栏之间拖拽即“服务器到服务器”
  中转（不经本地磁盘，`Sources/ShellXApp/RelayTransfers.swift`），也能拖到本地面板落盘。
- **SFTP**：本地/远端多栏——一个本地面板可并排挂多个远端服务器（工具栏 `+` 从主机列表添加，
  额外面板各自持有一条 SSH 连接，关闭时只断开自己那一栏；面板组合随工作区快照恢复）；
  两端地址栏都可直接输入路径回车跳转（`~` 与相对路径均支持）、前进/后退/上级/刷新、隐藏文件开关；
  窗格较窄（<520pt）时切换成紧凑布局：本地/远端用 chip 切换、工具栏只留常用按钮、其余收进 `⋯` 菜单，
  再窄（<380pt）时列表隐藏大小与时间两列、标题只留主机名；工具栏按面板宽度自适应（名称、路径、按钮逐个让位），
  不再把按钮挤到面板外；日期列同年只显示“月-日 时:分”、跨年显示日期，完整的权限/时间/路径在行悬停提示里；
  **目录记忆**——每台主机最近访问的 50 个远端目录落库（`sftp_history` 表），重新打开 SFTP 直接回到
  上次所在目录（工具栏时钟图标可挑选历史目录或清空），本地目录同理记在设置里、下次启动沿用、
  rwx 与八进制双显、排序、`<2MB` 内置编辑器、新建/重命名/删除/chmod、
  上传下载（并发 1–4、每包 32 KiB、8 个 in-flight 窗口、断点续传、失败重试 3 次、
  暂停/继续/取消）、冲突策略（覆盖/跳过/重命名/仅较新，可“应用于全部”，拖拽与按钮走同一套判断）、
  SFTP 区域底部常驻活动条显示进度/百分比/速度/剩余时间，工作区右下角另有全局传输浮层
  （无论 SFTP 面板是否打开都可见，含暂停/取消），状态栏汇总当前速度；传输中心
  （完成后自动刷新对应面板，终态记录落库、重启后仍可查看）。
- **拖拽**：Finder → 远端面板上传；Finder → 终端上传到当前目录并回填（不回车）；
  Finder → 侧边栏主机；远端 → Finder 通过文件表示流式落盘；远端 ↔ 本地入队。
- **跳板与代理**：从现有主机选择 1–3 级跳板（direct-tcpip），每跳独立凭据或复用目标机凭据；
  HTTP CONNECT（Basic）与 SOCKS5/SOCKS5h（RFC 1929），作用域 主机 > 分组 > 全局。
- **外观与菜单栏**：Dock 图标为 Tauge 圆角标（`Resources/AppIcon.icns`），菜单栏常驻 18pt 黑白
  template 图标（`Sources/ShellXApp/Assets/MenuIcon*.png`，随浅色/深色菜单栏自动反色），菜单可
  打开主窗口、新建 SFTP 标签、新建终端标签、命令面板、传输中心与退出。
- **窗口与进程生命周期**：关闭主窗口就退出进程（菜单栏图标与 Dock 状态一起消失），
  不会留下一个没有窗口的后台进程；再次打开 `.app`/点 Dock 会唤醒窗口。同一时刻只允许一个实例
  （重复启动会激活已有窗口；测试用的旁路是 `SHELLX_SINGLE_INSTANCE=0`）。
  实现见 `Sources/ShellXApp/ShellXApp.swift` 的 `applicationWillFinishLaunching` /
  `observeWindowClosing()` / `applicationShouldHandleReopen`：SwiftUI 会留一个不可见宿主窗口，
  所以 `applicationShouldTerminateAfterLastWindowClosed` 永远不触发；改成只认主窗口
  （`mainWindow`——SwiftUI 还会自己开关隐藏宿主窗口，不能被它误判）的
  `NSWindow.willCloseNotification`，退出前用同步的 `flushWorkspace()` 落盘标签布局
  （原来的 `persistWorkspace` 有 300ms 防抖，进程退出会把它丢掉）。
- **导航**：`⌘K` 命令面板按侧边栏的分组树展示（分组标题 + 按层级缩进的主机行，另有“工作区”“命令”分区，
  `↑`/`↓`/`↩` 操作）、状态栏（状态/路由/编码/传输）、崩溃后恢复标签与最后目录。

## 构建

只依赖 SwiftPM 与 Command Line Tools（本项目在 macOS 26.6 / Swift 6.4 上开发）。

```bash
# 依赖：已 vendor 到 Vendor/ 并通过 SwiftPM mirror 指向本地副本
export TMPDIR="$PWD/.build/tmp"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/modulecache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/modulecache"

swift build --disable-sandbox \
  --cache-path .swiftpm/cache \
  --config-path .swiftpm/config \
  --security-path .swiftpm/security

# 打包 .app（默认 release），产物在 dist/Tauge.app
./scripts/build-app.sh release
open dist/Tauge.app
```

图标由根目录的 `tauge.png` 生成：`python3 scripts/make-icons.py` 抠出圆角方块写成
`Resources/AppIcon.icns`（打包进 `Contents/Resources`），`python3 scripts/make-menu-icons.py`
生成菜单栏用的 18pt 黑白 template 图 `Sources/ShellXApp/Assets/MenuIcon*.png`（`.copy("Assets")`
资源，打包时复制到 `Contents/Resources/Assets`）。

> CLT 的 SwiftUI 接口把 `@State` 声明为外部宏，而 `libSwiftUIMacros.dylib` 只随完整
> Xcode 提供，因此界面层使用 `Sources/ShellXApp/ViewState.swift` 中的等价属性包装器。

### 代码签名与钥匙串授权

`dist/Tauge.app` 用本地自签名证书签名：`scripts/setup-signing.sh` 一次性生成
（私钥放在 `~/Library/Keychains/tauge-signing.keychain-db`，证书以“仅代码签名”的用途
加进用户域信任，并把该钥匙串追加到登录钥匙串搜索列表）。这样每次重建的 designated
requirement 都是 `identifier "com.shellx.app" and certificate leaf = H"…"`，保持不变。

这决定了钥匙串会不会反复索要密码：ad-hoc 签名的 requirement 是 `cdhash H"…"`，
每次构建都变，你在“始终允许”里给出的授权随之失效，表现为每次重开 App 都弹
“若要给予许可，请输入‘登录’钥匙串的密码”。换成固定证书后，旧条目第一次访问时点一次
“始终允许”即可，重建、重开都不会再提示。

签名钥匙串丢失或换机器时，`scripts/build-app.sh` 会打印提示并退回 ad-hoc 签名（构建不会中断），
执行一次 `scripts/setup-signing.sh` 就能恢复稳定签名。

## 自检

CLT 工具链不包含 XCTest/swift-testing，自检以可执行 target 运行：

```bash
swift run --disable-sandbox \
  --cache-path .swiftpm/cache \
  --config-path .swiftpm/config \
  --security-path .swiftpm/security ShellXChecks
```

默认 360 项（另加真实环境检查，见下）：SFTP v3 编解码、ssh_config 解析（含 OpenSSH “首个取值优先”语义）、分组继承与跳板链、
工作区分屏树（宫格推导、带方位/移位的切分、关闭塌陷、交换、分割条比例吸附、剪枝、窗口坐标拖动换算、
含窗格 SFTP 标记的 JSON 与旧数据兼容）、
终端/SFTP 分割条（与工作区同一套 AppKit 分割条，可拖动、双击复位）、
SFTP 目录历史（按主机隔离、最新优先、上限 50、随主机删除清理）、工作区标签开关的持久化（`board.open`，兼容旧 `navigationMode`）、上次聚焦的视图（`board.selected`，重启回到工作区标签或普通终端标签）、
POSIX 路径与权限格式化、密钥指纹、本地文件服务生命周期、传输引擎（上传/下载/断点续传/递归/冲突/进度流）、
RSA 私钥解析（OpenSSH / PKCS#1 / PKCS#8，2048 与 4096 位，指纹与 ssh-keygen 比对）、
Termius 导入用到的 XSalsa20-Poly1305（libsodium 向量校验，另加 21 项真实库导入检查，见下），
以及**端到端链路**——进程内 NIOSSH 服务端 + 真实客户端：握手、公钥认证、PTY + shell 通道往返、
SFTP 子系统读写、`rsa-sha2-256` / `rsa-sha2-512` 认证（`Sources/ShellXChecks/MockSSHServer.swift`、
`Sources/ShellXChecks/RSAKeyChecks.swift`）；跳板链也在其中真跑：mock 服务端实现 direct-tcpip 隧道，
单跳与双跳各开一次嵌套 SSH 会话，并验证“哪一跳拒绝登录”“TCP 连接被拒”“主机名解析失败”的报错归属
（`Sources/ShellXChecks/JumpChainChecks.swift`）。

界面里的焦点逻辑还有一条**进程内自测**（不属于上面的 CLI 自检）：
`SHELLX_FOCUS_SELFTEST=1 .build/debug/ShellX` 会在恢复的标签连上后把键盘从终端夺走
（first responder 设为窗口本身，模拟点标签栏/关闭对话框后的状态），派发一次合成按键，
再打印键盘是否被改派回 `ShellXTerminalView`、以及经终端写入的命令是否回显
（`Sources/ShellXApp/FocusSelfTest.swift`）。

另有四条默认关闭的真实环境检查（缺环境变量时直接跳过）：

- `SHELLX_LIVE_SSH=1` + `SHELLX_LIVE_HOST/PORT/USER/KEY`：连真实 sshd，验证终端与 SFTP。
- `SHELLX_REAL_JUMP=1` + `SHELLX_REAL_JUMP_HOST/PORT/USER` 与 `SHELLX_REAL_JUMP_VIA/VIA_PORT/VIA_USER`、
  `SHELLX_REAL_JUMP_KEY`：走真实跳板机（目标地址仅跳板可达），逐跳 direct-tcpip，验证 SFTP 与 shell，
  并**显式开启 keepalive**（见下一条），回归“跳板连接一建立就崩”的问题。
- `SHELLX_REAL_TRANSFER=1`（复用上一组的跳板与密钥变量，不带 `_VIA` 则直连目标）：用真实 SFTP 服务器跑
  `TransferEngine`——256KB 上传后远端字节比对、下载回本地比对、递归上传保持目录树
  （`Sources/ShellXChecks/RealTransferCheck.swift`）。
- `SHELLX_TERMIUS=1`：读取本机 Termius 的加密库（默认走登录钥匙串取密钥，
  `SHELLX_TERMIUS_KEY=<44 字符 base64>` 可绕过钥匙串授权），在临时库里完整导入一遍，
  校验分组、主机/私钥/known_hosts 数量、私钥文件 0600 与指纹，以及二次导入不重复
  （`Sources/ShellXChecks/TermiusVaultChecks.swift`）。

## 代码结构

```
Sources/ShellXKit/
  Model/           数据模型、配置解析（分组继承、代理来源、跳板链）
  Store/           SQLite（WAL）主机目录、known_hosts、传输记录、设置
  Security/        Keychain、凭据存储、AES-256-GCM 导出加密、密钥指纹
  SSHConfig/       ~/.ssh/config 解析与 Host * 默认值
  SFTP/            SFTP v3 编解码与并发客户端
  SSH/             NIOSSH 连接（代理、跳板、终端、SFTP 子系统、主机密钥校验）
  Transfer/        传输引擎（分块、断点续传、冲突策略、重试、进度流）
  FileBrowser/     本地文件服务与路径/权限格式化
  Import/          Termius 加密库读取（XSalsa20-Poly1305）与导入映射
Sources/ShellXApp/ SwiftUI 界面、AppState 编排、工作区视图（BoardView）、终端桥接、命令面板、设置
Sources/ShellXChecks/ 自检
```

## 已实现范围与已知限制

- 键盘焦点：SwiftTerm（vendored 版本）的 `mouseDown` 不会调用 `makeFirstResponder`，这是“终端有时无法输入”
  的根因——焦点一旦被 SwiftUI 界面拿走就再也回不到终端。修复在 `Sources/ShellXApp/TerminalBridge.swift`
  （`takeFocus()`，点击/粘贴确认/拖放结束后调用）与 `Sources/ShellXApp/AppState.swift`
  （`focusTerminal`/`scheduleTerminalFocus`（带重试）/窗口 key monitor 的 `handOffKeyEventToTerminalIfNeeded`），
  没有改 vendor 源码。
- SwiftNIO SSH 的能力边界：不提供 keyboard-interactive，也不暴露协商算法/RTT。
  因此 keyboard-interactive 认证与状态栏算法/RTT 显示不可用（后者也未做替代方案）。
- RSA 私钥通过 vendored NIOSSH 补丁支持（RFC 8332 的 `rsa-sha2-256` / `rsa-sha2-512`），默认先试
  `rsa-sha2-512`、失败后自动回退 `rsa-sha2-256`；按 PRD 要求不使用 SHA-1 的 `ssh-rsa` 签名。
  补丁位于 `Vendor/swift-nio-ssh`（`Package.swift` 以 path 依赖引用），涵盖用户认证签名、验证与
  USERAUTH 报文的算法名字段。
- 私钥支持 OpenSSH 新格式 / PKCS#1 / PKCS#8 / SEC1 的 Ed25519、ECDSA 与 RSA；PEM 传统加密格式不支持。
- SSH Agent（`SSH_AUTH_SOCK`）与 HTTPS 代理（PRD 中列为 P2）尚未接入。
- iTerm 配色导入未实现（内置 6 套主题可用）；多语言目前只有中文。
- 目录拖出到 Finder 仅支持普通文件；目录请用传输中心或双栏拖拽入队。
- 终端字节流按 UTF-8 渲染，GBK 编码主机的中文显示可能异常（编码设置仅用于打开远端文本）。
- 建连时 socket 先保持 `autoRead = false`，等 NIOSSH handler 就位后才恢复读取；跳板隧道通道同理
  （子通道创建时暂停读取，下一跳的 handler 装好后才 `startReading`）。这修掉两类“对端先说 KEXINIT
  却被空管线丢掉”的挂起：直连的偶发握手卡住（`SHELLX_RSA_REPEAT=25` 压测 188 项全绿），以及
  跳板链上嵌套 SSH 只交换版本串就停住。
- 跳板链的首个 TCP 连接打在**第一跳**上（此前误连目标机，目标不可路由时直接报
  “建立 TCP 连接失败 …(NIOCore.ChannelError 错误 0)”）；错误按“第 N 跳 user@host:port”归属，
  对手方地址/端口一并回报。底层错误文案由 `Sources/ShellXKit/SSH/TransportFailure.swift` 统一翻译，
  区分 DNS 失败、连接被拒(ECONNREFUSED)、连接超时（SYN 被静默丢弃）、主机/网络不可达。
- keepalive 只在真正的 TCP socket 上设置：启用跳板后根通道是 SSH 子通道，而 NIOSSH 的
  `SSHChildChannel` 对 socket 选项直接 `fatalError`（"setting option ... on SSHChildChannel not supported"），
  进程会以 SIGTRAP 退出（表现为“点一下连接就闪退”）。`startKeepalive` 现在沿父链下探到持有 fd 的通道，
  非 socket 通道直接跳过；`Sources/ShellXChecks/JumpChainChecks.swift` 的单跳/双跳用例都带
  `keepaliveSeconds: 40` 做回归。
- SFTP 面板切换后不出现：`WorkspaceView` / `StatusBarView` 原先只持有 `AppState`（它只发布标签数组），
  在标签对象上改 `showsSFTP` / `connectionState` 不会触发重绘，表现为“点 SFTP 按钮没反应、文件传输像是没做”。
  现已抽出 `TabWorkspaceView`、`TabStatusItems` 用 `@ObservedObject` 订阅标签对象；SFTP 打开、上传下载、
  进度与历史落库的完整链路已用真实服务器跑通。
- 对话框同一时刻只允许一个：`Sources/ShellXApp/ContentView.swift` 之前在同一视图上叠了 11 个
  `.sheet(...)`，而 SwiftUI 只会呈现其中一个，导致“同名文件冲突”对话框永远不出现（拖拽覆盖时不提示）。
  现改为单一 `ActiveSheet` 枚举 + 按优先级选择内容的 Binding（密码 > 主机密钥 > 冲突 > 编辑器 > 各编辑器表）；
  关闭时按类型把对应状态置空，密码/主机密钥的 continuation 也会被显式取消，不会悬挂。
  冲突选择另有 60 秒超时（超时按“取消本次传输”处理并提示），避免传输队列被无人应答的对话框卡死。
- 多远端面板中，主面板复用标签自身的 SSH 连接；额外面板各自建立独立连接（`TerminalTab.remoteClients`），
  关闭额外面板只断开该面板的连接与 SFTP 子系统。面板组合写入工作区快照的
  `additionalHostIDs`（可选字段，旧快照仍可解码），重启后按原顺序恢复。
- 拖拽下载的容错：拖拽时附带私有类型 `com.shellx.remote-path`（记录来源面板的 hostID 与远端路径），
  本地面板优先据此定位来源面板；即使该路径已不在缓存列表里，也会 `stat` 后补一条记录再入队。
  拖拽读不到路径、来源面板已关闭或 SFTP 未就绪时会弹出说明，而不是静默无反应。
  排查拖拽/传输问题可带 `SHELLX_TRACE_TRANSFERS=1` 启动，stderr 会打印 `[xfer] drop path=… host=…` 与
  `[drag] drag started for …` 行（前者来自落点，后者来自拖拽源）。
- 拖拽落点改用 AppKit 实现（`Sources/ShellXApp/DropArea.swift`）：SwiftUI 的 `.onDrop` 依赖指针下的 SwiftUI
  视图层级，对私有 pasteboard 类型常常静默失败。现在整个 SFTP 区包在一个 `DropContainerView` 里
  （`registerForDraggedTypes` + `performDragOperation` 直接读 `NSPasteboard`），远端路径拖到本地栏任意
  位置即下载到本地当前目录，Finder 文件拖到 SFTP 区则上传到主远端面板。行的修饰符顺序固定为
  `onDrag` 在 `onTapGesture` 之前，否则 SwiftUI 会停留在 tap 序列里不启动拖拽。
- 终端与 SFTP 之间用同一套 AppKit 分割条（可拖动、双击复位到 50%），不再用 `VSplitView`：
  后者在窗格变窄时会把下方视图压成零高度，看起来就像 SFTP 面板"消失"；SFTP 打开状态本身存在
  `TerminalTab.showsSFTP` / `BoardPaneDefinition.showsSFTP`，重启后照旧恢复。
- 工作区窗格复用标签页那套 `TerminalTab`（同一份终端、查找、SFTP、传输代码），所以窗格与标签页
  互斥出现在侧边栏“最近/收藏”里；工作区不保存滚动内容（重连后是全新 shell），也不支持窗格内再切成
  上下左右的任意嵌套树——宫格由 `BoardSplitTree` 从当前窗格数推导，手动切分/交换会持久化到工作区 JSON。
- 工作区的“打开状态”记在 `board.open`：升级后第一次启动会把上次的工作区作为标签打开，之后关掉就是关掉；最后聚焦的是工作区标签还是普通终端标签记在 `board.selected`，重启回到同一处；
  旧版本（看板=分组列或“看板模式”开关）的数据不会被读到，主机数据不受影响。
- SFTP 目录记忆按 `host_id` 记录（不看用户/端口），同一台机器换了账号仍共用历史；每台主机只保留
  最近 50 个目录，超出后淘汰最旧的。历史目录不校验是否仍然存在，跳转失败会在面板里报错，可再选别的。
- 服务器在密钥交换阶段直接断开时（典型是只提供 `ssh-rsa`/`ssh-dss` 旧主机密钥的老机器，
  例如库里的 10.103.136.65:23），原先只报“End of file”或“SSH 连接尚未建立”。现在按握手未完成识别，
  提示“服务器在密钥交换阶段关闭了连接 … 请升级服务器 SSH 版本或改用 ed25519/ECDSA 主机密钥”
  （`SSHConnectionError(stage: .keyExchange)`）；ShellX 不会为兼容旧机器而降级启用 SHA-1/ssh-dss。
- 远端目录一次加载整表，未做虚拟滚动与方向键导航；超大目录建议用传输而非浏览。
- 若进程对数据库没有写权限（例如从受限沙盒或受管控的终端启动），启动时会做一次写探测，
  明确提示“数据库不可写”并在状态栏常驻只读标记，而不是等到第一次保存才抛 SQL 错误；
  “设置 → 高级 → 迁移到可写位置…” 可把数据库复制到用户选择的目录（`VACUUM INTO`，含 WAL 内容），
  下次启动使用新位置。数据库位置也可用 `SHELLX_CATALOG_PATH` 或 defaults 的 `ShellXCatalogPath` 覆盖。
- 可写方式打不开时会以只读方式加载原库（先试普通只读句柄，失败再退回 SQLite 的 `immutable=1`），
  主机与分组照常可见可用，不会被一个空的临时库顶替；两种降级都会在 stderr 留下原因。

逐条对照 PRD 的覆盖情况见 [docs/prd-coverage.md](docs/prd-coverage.md)。

## 数据位置

- 数据库：`~/Library/Application Support/ShellX/shellx.sqlite`（可用 `SHELLX_CATALOG_PATH` 或默认值 `ShellXCatalogPath` 覆盖；设置 → 高级可迁移）
- 会话日志（默认关闭，可在分组/主机开启）：`~/Logs/{host}/{date}.log`
- 凭据：登录钥匙串，service `com.shellx.credentials`