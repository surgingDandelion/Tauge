# PRD 覆盖情况（Tauge，原名 Tauge）

对照 `prd/tauge.md` 的验收清单与功能需求，记录当前实现状态。图例：
✅ 已实现并有自检覆盖 · 🟡 部分实现 · ⛔ 受 SwiftNIO SSH 能力限制 / 未实现

## 验收清单（§2）

| # | 项目 | 状态 | 说明 |
|---|------|------|------|
| 1 | 分组与主机重启后保持 | ✅ | 全部落在 SQLite（WAL），`groups.sort_index`/`is_expanded` 持久化 |
| 2 | 密码 / 私钥 / keyboard-interactive 认证 | 🟡 | 密码与 Ed25519/ECDSA 私钥可用；keyboard-interactive ⛔（NIOSSH 无此能力，选择该方式时回退密码） |
| 3 | 主机指纹变更阻断并提示 | ✅ | `known_hosts` 记录 SHA256，比对不一致时弹窗高亮新旧指纹并拒绝连接 |
| 4 | 多标签运行 vim/tmux/htop/中文与 emoji | ✅ | SwiftTerm + 真实 PTY 请求；宽字符由 SwiftTerm 处理 |
| 5 | 带认证的 HTTP 代理 | ✅ | HTTP CONNECT + Basic，代理仅作用于第一跳 TCP |
| 6 | A → B 两级跳板，断开 B 时提示 | ✅ | direct-tcpip 链式隧道；首跳失败定位到具体跳（`SSHJumpStep` 错误） |
| 7 | 500MB + 200 文件目录拖拽全策略 | ✅ | 传输引擎 8 个 in-flight、32 KiB 分块、递归计划、四种冲突策略 |
| 8 | 拖到终端回填路径且不执行 | ✅ | 上传后写入 shell 转义路径 + 空格，不发回车 |
| 9 | 拖到桌面大文件不爆内存 | 🟡 | 远端拖出按文件表示流式落盘（无整文件驻留），但只支持普通文件 |
| 10 | 8 小时会话与强退恢复 | 🟡 | 指数退避重连 + 工作区快照（标签、最后目录）；未做 8 小时长跑基准 |

## 功能需求

### FR-1 主机与分组管理 ✅
主机字段（名称/备注/标签/颜色/地址/端口/用户名/认证/私钥与口令/代理/跳板/终端类型/编码/起始目录/启动命令/保活/复用）、
无限层级分组、组默认值向下继承、拖拽移动、重命名、删除二次确认、排序与折叠持久化、右键新建/批量连接、
名称/地址/用户名/标签/备注搜索 + 拼音首字母、收藏与最近 20 台、`~/.ssh/config` 导入（Host/HostName/User/Port/
IdentityFile/ProxyJump/ProxyCommand 及 `Host *` 默认值、Host 别名之间的 ProxyJump 解析）。

工作区（原“看板”，PRD 未单列，按用户 m03259 追加，按"看板里也要有 SFTP"重做为分屏工作区，
再按 m04457 改成**标签栏里的普通标签**）：一个工作区承载多个
SSH 窗格，`BoardSplitTree` 负责宫格推导、按窗格切分（可指定新窗格方位）、关闭后塌陷、窗格交换、
分割条比例吸附（25/33/50/67/75%）与剪枝；分割条本身是 AppKit 视图（`BoardSplitHandle`，
用窗口坐标计算位移以避免"拖动时被拖视图自己也在移动"的反馈环），8pt 槽位、悬停高亮、双击复位，
拖动时磁吸并显示百分比徽标；把窗格标题栏拖到另一窗格的上/下/左/右边缘即在该方向切分、
拖到中心则交换，落点有高亮预览；双击窗格标题栏最大化/还原；每个窗格是一个 `TerminalTab`（终端 + `⌘F` 查找 + 拖拽上传 + 会话日志 + 断线重连），窗格右上角的
SFTP 按钮只在该窗格打开本地/远端浏览器，状态随 `BoardPaneDefinition.showsSFTP` 持久化；
**新建工作区走表单**（名称 + 布局宫格/单窗格 + 按分组分节的服务器多选 + “创建后立即连接”），
一次把整组服务器铺成宫格；「添加主机」菜单也可“整组添加：<分组>”或从列表挑选（按 m06741 追加）；
工作区作为标签与普通连接并排（网格图标 + 名称，选中态与普通标签一致），标签栏右侧「工作区」菜单可新建或打开已有工作区，
`⇧⌘B` 新建，主机右键「在工作区中打开」把主机加为窗格；工作区本身支持新建/重命名/删除（二次确认）并落 `boards` 表，
**开着的标签**记在设置 `board.open`（旧 `navigationMode` 仍可读），关掉后再启动不会自己冒出来；最后聚焦的视图记在 `board.selected`，重启回到同一个标签（工作区或普通终端）。
**起始页**（按 m07012 / m08304 / m08539 追加）：没有任何标签被选中时显示两栏概览——
左边是可滚动的“工作区 + 分组”清单（工作区一行一个并显示窗格数；分组按层级缩进、右侧只统计该分组自己的主机（子分组主机不在父组里重复出现，按 m09710 修正），
还有全部主机/收藏/最近连接/未分组入口），点一行右边就只显示这个分组，因此有几十个分组也仍是一屏，不会向下堆成一条长卷；
右边是所选分组的主机卡片网格（自适应 240–420pt：名称、地址、分组/跳板/代理/标签、上次连接与使用次数，悬停浮出连接与
新建 SFTP，双击连接，右键在工作区中打开/编辑/收藏/删除，分组视图里还能“全部连接”与“新建主机到此分组”；卡片可拖动排序（拖到另一张卡上）与跨分组移动（拖到左侧分组行或组内空白处，是移动而非复制），落点高亮描边，顺序写入 hosts.sort 字段，配色改为低饱和图标色 + 中性选中描边，不再用系统蓝（按 m09541 追加）；选中含子分组的分组时标题行提供「含子分组（N）/仅本组」切换（按 m09710 追加））；
顶栏只有一行：计数、搜索框（名称/地址/用户名/标签/备注/拼音首字母）、**「新建 SFTP」**（弹服务器多选，勾几台就并排挂几个远端面板）、
「新建主机」和“更多”菜单（新建工作区/导入 ~/.ssh/config/快速打开/传输中心/设置），底部只留一行快捷键提示；
空库时右侧改为“新建主机 / 导入 ~/.ssh/config / 新建工作区”三张引导卡。所以零标签状态下也能进入工作区、SFTP 或任意主机；
分组的增删改入口（按 m09086 追加）：左侧“分组”标题右侧 `+`、“更多”菜单的“新建分组…”、选中分组后标题行的“新建子分组”、
分组行右键（连接组内全部主机 / 新建主机到此分组 / 新建子分组 / 重命名 / 删除，删除带二次确认），以及 `⇧⌘N`、文件菜单与 `⌘K` 快速打开；
新建子分组后自动展开父分组（`AppState.beginNewGroup(parentID:)`）。
状态写入 `AppSettings.sidebarVisible`。工作区的窗格增删不再即时落库：标题栏显示橙点「未保存」，
`⌘S`（菜单 文件 → 保存工作区）提交，切换工作区、关闭工作区标签或退出应用时自动提交，纯布局改动仍即时保存。
`⌘K` 快速打开是窗口内的悬浮卡片而不是 sheet：输入即搜主机（名称/地址/用户名/端口/分组路径/标签/备注/拼音首字母）、
工作区（名字，或其中任一主机）与命令，结果按“完全匹配 > 前缀 > 词边界子串 > 普通子串 > 子序列”打分，
同分才看最近使用（一天内 +40 / 一周内 +20 / 一月内 +10，使用次数上限 20），空格分隔的多个词必须全部命中；
↑↓ 选择（到头即停；输入让结果变短时高亮会自动收回到最后一行）、↩ 打开并连接、`⌘↩` 直接开 SFTP 标签、Esc 关闭，
空结果给出“换个关键词”的提示（按 m00750 重做）。每台主机只列一行：SFTP 走 `⌘↩` 或 `⇧⌘T`，不再为每台机器重复一条“· SFTP”行。
终端区域不再贴着窗口边缘：内容嵌在圆角卡片里（6pt 内边距 + 12pt 外边距，卡片底色跟随所选终端主题）。

### FR-2 安全与认证 🟡
- ✅ 密码、口令存 Keychain（`kSecAttrAccessibleAfterFirstUnlock`），SQLite 不落明文；会话日志可对密码脱敏。
- ✅ 私钥：OpenSSH 新格式、PKCS#1、PKCS#8、SEC1；类型 Ed25519、ECDSA P-256/384/521、RSA。
- ✅ RSA：以 vendored NIOSSH 补丁实现 RFC 8332 的 `rsa-sha2-256` / `rsa-sha2-512`（默认 512，
  失败自动回退 256），USERAUTH 报文的算法名字段按 RFC 8332 §3.2 填写，公钥 blob 仍为 `ssh-rsa`；
  按 PRD 的安全要求不使用 SHA-1 的 `ssh-rsa` 签名。自检覆盖 2048/4096 位的 OpenSSH、PKCS#1、
  PKCS#8 三种编码与两种签名算法的端到端认证。
- ⛔ PEM 传统加密格式（`BEGIN RSA PRIVATE KEY` + `Proc-Type: 4,ENCRYPTED`）：不支持，需先移除口令。
- ⛔ keyboard-interactive：NIOSSH 仅支持 password/privateKey/none。
- ✅ 主机密钥 TOFU，SHA256（可查 MD5），变更阻断。
- ✅ 连接错误按阶段归类（DNS / TCP / 代理 / 密钥交换 / 主机密钥 / 认证 / 通道）并给出建议；
  认证被拒时在 `connectTimeout` 内明确报错而不是挂起。
- ✅ 建连顺序：TCP 连接成功后先保持 `autoRead = false`，等 NIOSSH handler 装入管线再恢复读取，
  避免服务端 KEXINIT 在空管线期间被静默丢弃（本机/低延迟链路上曾因此出现约 4% 的偶发握手挂起，
  修复后以 25 轮重复的 RSA 认证矩阵回归，188 项全绿）。

### FR-3 终端 ✅（个别项见备注）
标签快捷键 `⌘T`/`⌘W`/`⌘1..9`、拖拽重排；xterm-256color、24 位色、UTF-8；
CJK 宽字符、鼠标上报、括号粘贴、OSC 8/52（SwiftTerm 内建）；`⌘F` 增量搜索（显示 `命中/总数`）；
选中即复制（可关，拖动过程中就写剪贴板，指针移出视图也不漏）、右键直接粘贴（开启鼠标上报的程序保留右键）、
多行粘贴确认；Option 作为 Meta；字体/字号/行高/背景透明度/六套内置主题；
断线保留内容 + 原因 + 指数退避重连 + tmux attach 提示；会话日志（`~/Logs/{host}/{date}.log`）；
状态栏显示状态、路由（代理 + 跳板链）、编码与传输数。
- ✅ 键盘焦点：SwiftTerm 的 `mouseDown` 不会 `makeFirstResponder`，焦点被 SwiftUI 界面拿走后再点终端也回不去，
  这是“终端有时无法输入命令”的根因。现在点击终端、切换标签/窗格、关闭查找栏或任何对话框、从别的 App 切回都会显式交还焦点
  （`Sources/TaugeApp/TerminalBridge.swift` 的 `takeFocus()`、`Sources/TaugeApp/AppState.swift` 的 `focusTerminal`/
  `scheduleTerminalFocus` 与窗口 key monitor 的 `handOffKeyEventToTerminalIfNeeded`），未改 vendor 源码；
  `TAUGE_FOCUS_SELFTEST=1` 的进程内自测会夺走焦点、派发合成按键，验证键盘回到 `TaugeTerminalView` 且命令能回显。
- 🟡 GBK：编码设置已进模型并用于打开远端文本，但终端字节流仍按 UTF-8 渲染。
- 🟡 iTerm 配色导入未做；RTT 与协商算法未显示（NIOSSH 未暴露协商结果）。

### FR-4 SFTP 🟡
- ✅ SFTP 可独立成标签（TerminalTab.kind == .sftp；标签栏 +、主机右键、起始页卡片都能新建）：
  不需要终端就能同时挂多台服务器，本地 ↔ 远端、远端 ↔ 远端都在同一个页面里。
- ✅ 远端 ↔ 远端“服务器到服务器”中转：把 A 面板的行拖到 B 面板，直接由进程内存转发
  （Sources/TaugeApp/RelayTransfers.swift，读 A 的 SFTP 写 B 的 SFTP，不经本地磁盘），
  中转也走同一套冲突策略、进度、暂停/取消；拖到本地面板则落盘下载。
- ✅ 工具条不再错位：面板头部按宽度分级让位（名称 → 路径 → 按钮），窄面板只留图标，
  路径栏去掉内嵌刷新按钮（头部已有），隐藏文件/排序/历史收进 ⋯ 菜单。
- ✅ 列表列宽与日期：大小 66pt、时间 96pt；同年只显示“月-日 时:分”，跨年显示日期，
  完整权限/八进制/时间/路径在行悬停提示里；本地与远端 footer 语义统一（左计数、右操作提示）。
- ✅ 双栏基础布局：左本地面板 + 右侧可并发挂多个远端面板（工具栏 `+` 从主机列表添加，`×` 关闭；
  主面板复用标签的 SSH 连接，额外面板各自建连，关闭只断自己那一栏）；面板组合随工作区快照恢复
  （`WorkspaceSnapshot.Tab.additionalHostIDs`，可选字段，旧快照仍可解码）。
- ✅ 两端地址栏都是常显输入框（回车跳转，支持 `~`、相对路径与绝对路径；失败在面板内提示），
  前进/后退/上级/刷新、隐藏文件开关、排序、多选（⌘ 点选加选、⇧ 连选整段；选中多行后拖一次即整批上传/下载，冲突询问每批只问一次）。
- ✅ 目录记忆：每次进入远端目录写入 `sftp_history`（每台主机保留最近 50 条），仅供工具栏时钟图标的
  历史目录列表跳转或清空，不再用于决定打开目录。恢复改为按标签/窗格各存各的目录：
  `WorkspaceSnapshot.Tab` 记住每个普通标签的终端与 SFTP 位置，`BoardPaneDefinition`
  记住每个工作区窗格的终端与 SFTP 位置，因此同一台机器开多个标签或窗格时互不覆盖，
  普通标签的目录变化也不会影响工作区恢复。本地目录记在 `AppSettings.lastLocalDirectory`，
  下次启动沿用。顺序优先级：本标签/本窗格已列出的目录 > 本次显式起始目录 > 主机起始目录。
- ✅ SFTP 区域底部常驻活动条：进行中传输的进度条、百分比、速度、剩余时间与暂停/继续/取消，
  超过 3 条折叠为“另有 N 个传输”，无传输时隐藏。
- ✅ 列：名称/大小/修改时间；权限以 rwx 与八进制双显（行提示与 chmod）；owner/group 在行提示中显示。
- 🟡 未做虚拟滚动与键盘方向键导航；目录整表加载（大目录建议用传输而非浏览）。
- ✅ `<2MB` 内置编辑器、新建文件夹/空文件、重命名、删除、复制路径、八进制 chmod。
- ✅ 上传下载（递归、多选、进度/速度/剩余时间、暂停/继续/取消、失败重试 3 次、重试全部）。
- ✅ 断点续传（按 offset 续写；自检覆盖"仅传剩余 55KB"）。
- ✅ 窄面板（工作区窗格 <520pt）自适应：chip 切换本地/远端，工具栏只留上级/刷新/`⋯` 溢出菜单，
  避免按钮被窗格右边缘裁掉；终端与 SFTP 的高度分配保证 SFTP 至少可见约 150pt，不再把工具栏顶出可见区。
- ✅ 冲突策略覆盖/跳过/重命名/仅较新，可“应用于全部”；拖拽与按钮共用同一判断。
- ✅ 冲突对话框此前永远不弹出：`ContentView` 在同一视图上叠了 11 个 `.sheet`，SwiftUI 只会呈现一个，
  其余静默失效 → 覆盖同名文件不提示。现为单一 `ActiveSheet` 枚举，按优先级（密码 > 主机密钥 > 冲突 >
  编辑器 > 各编辑器表）选择内容，关闭时按类型清空对应状态；冲突选择另有 60 秒超时兜底。
- ✅ 传输中心（筛选、冲突策略、暂停/继续/重试/取消/移除）。
- ✅ 传输完成后自动刷新对应面板（上传刷新远端列表、下载刷新本地列表），并把终态记录写入 `transfers` 表，
  重启后传输中心仍显示历史；“清除已完成”与“移除”同步删除数据库记录。
- ✅ 传输入口不再静默失败：SFTP 未建立时点上传/下载会弹出说明；未选中项目时按钮禁用并给出提示。
- ✅ SFTP 面板可见性：`WorkspaceView` / `StatusBarView` 原先只订阅 `AppState`（它只发布标签数组），
  直接改标签对象上的 `showsSFTP` / `connectionState` 不会触发重绘，表现为“点 SFTP 按钮没有任何反应、
  文件传输像是没做”。已抽出 `TabWorkspaceView`、`TabStatusItems` 用 `@ObservedObject` 订阅标签对象。
- ✅ 服务器在密钥交换阶段直接断开（只提供 ssh-rsa/ssh-dss 旧主机密钥的老机器，如 10.103.136.65:23）
  不再只报 “End of file”：SSHClient 记录 openedChannelCount == 0 时的关闭，映射为
  SSHConnectionError(stage: .keyExchange)，并建议升级服务器或改用 ed25519/ECDSA 主机密钥。
- ✅ 传输链路对真实 SFTP 服务器验证过（上传 256KB 后端字节一致、下载一致、递归目录保持树形），
  见 `Sources/TaugeChecks/RealTransferCheck.swift`（`TAUGE_REAL_TRANSFER=1`，可经跳板）。
- ✅ 拖拽落点改为 AppKit 容器（Sources/TaugeApp/DropArea.swift）：SwiftUI 的 `.onDrop` 依赖指针下的
  SwiftUI 视图层级，对远端行发布的私有类型 `com.tauge.remote-path` 会静默失败（表现为“拖动没有触发传输”，
  而右键下载正常）。现在整个 SFTP 区包在 `DropContainerView`（`registerForDraggedTypes` +
  `performDragOperation` 读 `NSPasteboard`）内：远端路径拖到本地栏即下载到本地当前目录，Finder 文件拖到
  SFTP 区即上传到主远端面板。行的修饰符顺序固定为 `onDrag` 在 `onTapGesture` 之前，否则 SwiftUI 会停在
  tap 序列里不启动拖拽；`Resources/Info.plist` 声明了导出的 UTI `com.tauge.remote-path`。
- 🟡 拖拽五条路径中四条已实现（Finder→远端、Finder→终端、远端→Finder、远端↔本地）；
  Finder→侧边栏主机尚未接（侧边栏仅支持主机拖到分组）；重命名走右键菜单，未绑定 F2。

### FR-5 跳板 ✅（可视化除外）
从现有主机选择 1–3 级、循环检测、每跳独立认证或复用目标机凭据、并发复用同一连接、
失败定位到具体跳并提示 direct-tcpip 不支持。链路状态灯与逐跳耗时未做（状态栏显示跳板链文本）。
首个 TCP 连接打在第一跳（此前误连目标机，目标不可路由时报“建立 TCP 连接失败 …(ChannelError 错误 0)”）；
隧道子通道在下一跳 handler 就位前保持 `autoRead = false`，避免对端先发的 KEXINIT 被空管线丢弃。
错误归属形如“第 1 跳 user@host:22：连接被拒绝”，底层错误文案由 `Sources/TaugeKit/SSH/TransportFailure.swift`
统一翻译（DNS 失败 / 连接被拒 / 连接超时 / 主机或网络不可达）。
保活只在真正的 TCP socket 上设置（`startKeepalive` 沿父链找 `SocketOptionProvider`）：跳板连接的根通道是
SSH 子通道，NIOSSH 的 `SSHChildChannel` 对 socket 选项直接 `fatalError`，此前会以 SIGTRAP 闪退。
除此之外每条连接还发应用层 `keepalive@openssh.com` 全局请求（`ServerAliveInterval`，默认 30 秒；
`max(间隔, 5)` 秒内无应答即判定链路已死并关闭连接），系统 ssh 传输额外带
`-o ServerAliveInterval=… -o ServerAliveCountMax=3`；断链后主面板按 2 秒退避自动重连、额外面板在通道
失效时重建自己的连接，SFTP 刷新按钮在断连时不再置灰而是直接触发重连（按 m00001 追加）。

### FR-6 代理 ✅（HTTPS 除外）
HTTP CONNECT（Basic）、SOCKS5/SOCKS5h（RFC 1929）、作用域 主机 > 分组 > 全局（UI 显示生效来源）；
HTTPS 代理（P2）与 PAC、连通性测试分阶段耗时未做。

### FR-7 设置与恢复 ✅
设置分为 通用/外观/终端/传输/安全/快捷键/高级/关于；崩溃退出后恢复标签与最后目录（不恢复内容与密码）
以及开着的工作区标签（`board.open`）；
深浅色跟随系统或手动；数据不上传。多语言目前只有中文（`AppSettings.language` 已预留）。
数据库不可写时（受限沙盒、受管控终端等）启动即探测并提示，状态栏常驻只读标记，设置 → 高级可迁移到可写目录。
默认视图（标签 / 工作区）与侧边栏显隐都记在设置里，设置 → 通用可改（`navigationMode`、`sidebarVisible`）。

## 非功能

- 冷启动、按键回显、SFTP 吞吐、内存占用未做基准（`scripts` 中无 bench）；架构上无阻塞主线程的磁盘/网络操作。
- 算法：NIOSSH 默认仅现代算法（无 ssh-rsa / SHA-1 / CBC / 3DES）；依赖均为 MIT/Apache-2.0，无 GPL。
- 窗口生命周期（m09297）：关闭主窗口即退出进程，菜单栏图标与 Dock 状态一起消失，不留无窗口的后台进程；
  再次打开或点 Dock 会唤醒窗口；单实例运行（重复启动激活已有窗口，`TAUGE_SINGLE_INSTANCE=0` 仅测试旁路）。
  原因是 SwiftUI 保留一个不可见宿主窗口，`applicationShouldTerminateAfterLastWindowClosed` 永远不触发，
  改为监听 `NSWindow.willCloseNotification`，在 `observeWindowClosing()` 里检查是否还有可见的 `canBecomeMain` 窗口。

## 自检覆盖（默认 360 项；另加 3 项真实跳板检查、7 项真实传输检查、21 项 Termius 导入检查）

- 键盘焦点（进程内自测，不在 CLI 自检里）：`TAUGE_FOCUS_SELFTEST=1` 把 first responder 设为窗口本身（模拟点标签栏/
  关闭对话框后的状态），派发合成 keyDown，断言键盘被改派回 `TaugeTerminalView`，并通过终端写入命令、在缓冲区里找到回显。
- SFTP v3 编解码往返、分片等待、状态解析、截断报错。
- 工作区快照兼容性：旧版 JSON（无 `additionalHostIDs`）仍可解码，新快照 round-trip 保留额外面板。
- 看板分屏树：宫格推导（0/1/2/4/5 个窗格）、切分（含 newFirst 方位）、关闭塌陷、交换（四边重挂与自移 no-op）、
  分割条比例吸附、剪枝、分割条拖动在窗口坐标下的位移换算，
  以及 `BoardDefinition` 的 JSON 与 SQLite round-trip、窗格 SFTP 标记、无该标记的旧看板 JSON 仍可解码
  （`Sources/TaugeChecks/BoardTreeChecks.swift`）。
- SFTP 目录历史：按主机隔离、重复路径不产生重复行并提升为最新、最新优先排序、每主机上限 50 条且淘汰最旧、
  清空与随主机删除清理（`Sources/TaugeChecks/BoardChecks.swift`）。
- 导航设置：`navigationMode` 与 `lastLocalDirectory` 存读一致；缺少这两个键的旧设置 JSON 仍能解码并回落到默认值。
- ssh_config 解析、`Host *` 默认值、OpenSSH 首个取值优先。
- 分组继承、代理来源、跳板链顺序与环路拒绝。
- 跳板链端到端：mock 服务端实现 direct-tcpip 隧道，单跳/双跳各跑通一次嵌套 SSH 会话（SFTP realPath）；
  “哪一跳拒绝登录”“TCP 连接被拒”“主机名解析失败”三类错误的目的地与跳次归属
  （`Sources/TaugeChecks/JumpChainChecks.swift`）；这些用例都显式开启 keepalive，回归“设 socket 选项导致闪退”。
- 可选真实环境检查（默认跳过）：`TAUGE_LIVE_SSH=1` 连真实 sshd；`TAUGE_REAL_JUMP=1` 走真实跳板机
  （`Sources/TaugeChecks/RealJumpCheck.swift`），已对真实 bastion + RSA 私钥跑通 SFTP 与 shell；
  `TAUGE_REAL_TRANSFER=1` 用同一套跳板配置跑 `TransferEngine` + 真实 SFTP
  （`Sources/TaugeChecks/RealTransferCheck.swift`）：256KB 上传后远端字节比对、下载回本地比对、递归上传保持目录树。
- POSIX 路径、权限/大小格式化、SHA256 指纹、本地文件服务生命周期。
- Termius 导入：XSalsa20-Poly1305 与 libsodium 生成的 7 组向量（0/1/31/32/200/1024 字节与固定向量）双向一致，
  篡改 tag、过短密文、错误 key 都返回对应错误；`TAUGE_TERMIUS=1` 再用真实库校验解密条数、
  主机/身份/私钥/known_hosts 非空、endpoint 唯一、临时库里的导入结果（分组、数量、私钥文件 0600、
  known_hosts 的 `SHA256:` 指纹、二次导入不重复）。
- 传输引擎：上传/下载/断点续传/递归树形/冲突跳过/进度流（内存 mock SFTP）。
- 数据库可写性：正常库探测通过、只读文件与只读目录（WAL 已清理）被识别、只读句柄仍能列出原有数据、
  `VACUUM INTO` 迁移保留数据。
- RSA 私钥解析：OpenSSH / PKCS#1 / PKCS#8，2048 与 4096 位，公钥串与指纹对照 `ssh-keygen`。
- **端到端**：进程内 NIOSSH 服务端 + 真实客户端完成握手、公钥认证、PTY+shell 通道往返、
  SFTP 子系统读写（`Sources/TaugeChecks/MockSSHServer.swift`）；RSA 的 `rsa-sha2-256` /
  `rsa-sha2-512` 认证矩阵（`Sources/TaugeChecks/RSAKeyChecks.swift`，可用
  `TAUGE_RSA_REPEAT=N` 重复压测）。

> 说明：本机没有可用的 `~/.ssh/authorized_keys`，且此沙盒下 `sshd` 无法初始化自身沙盒，
> 因此端到端验证使用进程内 NIOSSH 服务端：它按标准 SSHRSA 流程解析 USERAUTH 报文，
> 并用 Security 框架的 `SecKeyVerifySignature` 严格验签（非放行），签名算法名不一致即失败。
> 真实 OpenSSH 服务器的互通仍建议在目标环境实测一次。

## Termius 导入（m09841）

- Termius 9.x 的本地库是加密的 IndexedDB（Electron）：每个值是
  base64(`version=4 | options | nonce(24) | secretbox(tag||ciphertext)`)，密钥由 Termius 写进登录钥匙串
  （`service=Termius, account=localKey`，32 字节的 base64）。
- Tauge 侧不引入第三方依赖：`Sources/TaugeKit/Import/Salsa20Poly1305.swift` 是纯 Swift 的
  XSalsa20-Poly1305（用 libsodium 生成的测试向量逐长度校验，并覆盖篡改 tag、短密文、错误 key）；
  `TermiusVault.swift` 扫描 `~/Library/Application Support/Termius/IndexedDB` 与容器副本两处，
  按 `B A` 前缀抽取 base64 片段、解密、解析 JSON，自动选择解密记录最多的目录（容器里常是旧副本）；
  `TermiusImporter.swift` 把结果映射成分组 / 主机 / 私钥 / known_hosts。
- 映射：`address` → hostname，连接历史补 port / username / tags / startup_command / charset，
  身份（identity.label 与主机 label 同名）提供 username 与 password；私钥实体写到
  `~/Library/Application Support/Tauge/Keys/<sanitized>.pem`（0600），公钥串与指纹由 TaugeKit
  自己从私钥算（不采信 Termius 的 public_key 字段），私钥口令与主机密码存 Keychain；
  known_hosts 的 hostnames 展开成 `host:port` 记录，指纹为 SHA256。
- 去重：同一 `host:port/username` 只保留一台（先已保存主机、后连接历史），重复执行导入不会产生副本。
- UI：`Sources/TaugeApp/TermiusImportView.swift` 单页预览（各类条数、主机勾选、是否包含连接历史、
  目标分组名、三个导入开关）；钥匙串授权失败时提示
  `security find-generic-password -s Termius -a localKey -w` 并支持手动粘贴密钥。
- 读取体验：解密与钥匙串读取在 `Task.detached` 里做（`SecItemCopyMatching` 会卡主线程），
  面板仍立刻出现；6 秒没读完就提示“还在等待钥匙串授权”，30 秒超时改成可重试的错误文案，
  以免只看到一个永久转圈。
- 安全细节：`导入` 不是默认按钮（不绑 `.defaultAction`），避免面板打开时误按回车把几十台主机
  一次性写进库；导入是显式点击才会发生的操作。
- 端到端自检（默认跳过）：`TAUGE_TERMIUS=1` 读取真实库并在临时库里完整导入一遍，
  断言分组创建、主机/私钥/known_hosts 数量一致、私钥文件 0600、known_hosts 指纹以 `SHA256:` 开头、
  二次导入 `importedHosts == 0`；`TAUGE_TERMIUS_KEY` 可绕过钥匙串授权。
- 局限：Termius 不把分组层级写进本地库（只有分组名对象），因此导入为单一分组；
  `key_id` 在库里没有映射表，私钥只能按 label 关联；只处理 `ssh` 类型连接，
  端口转发与代码片段只统计标签。

## 品牌更名（m08667）

- 应用名改为 **Tauge**：`Resources/Info.plist` 的 `CFBundleName`/`CFBundleDisplayName`/
  `CFBundleExecutable` 为 Tauge，打包产物 `dist/Tauge.app`，二进制 `Contents/MacOS/Tauge`。
- 保留 `CFBundleIdentifier=com.tauge.app`、Keychain service `com.tauge.credentials`、
  数据目录 `~/Library/Application Support/Tauge`、`Sources/TaugeApp`/`Sources/TaugeKit`
  模块名与 `com.tauge.remote-path` 拖拽类型，避免已有主机、密码与工作区丢失。
- 应用图标 `Resources/AppIcon.icns`（由根目录 `tauge.png` 抠出圆角方块生成），
  菜单栏用 18pt 黑白 template 图标 `Sources/TaugeApp/Assets/MenuIcon*.png`（`.copy("Assets")`
  资源，`Bundle.main` / `Bundle.module` 都能取到），点击后的菜单可打开窗口、新建 SFTP/终端标签、
  快速打开、传输中心与退出。
- 终端主题名 `Tauge Dark/Light` → `Tauge Dark/Light`，`AppSettings` 解码时迁移旧值，
  老配置不会掉回默认主题。
