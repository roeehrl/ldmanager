<p align="center">
  <img src="docs/assets/icon.png" width="112" alt="LD Manager 图标">
</p>

<h1 align="center">LD Manager</h1>

<p align="center">
  <b>看清 Mac 上在运行什么，修好没能运行的。</b><br>
  一款免费、开源的原生 macOS 应用和命令行工具，用于管理 LaunchAgent 和 LaunchDaemon。
</p>

<p align="center"><a href="README.md">English</a> | <a href="README.zh-CN.md">简体中文</a> | <a href="README.ja.md">日本語</a></p>

<p align="center">
  <a href="https://github.com/roeehrl/ldmanager/actions/workflows/ci.yml"><img alt="CI" src="https://github.com/roeehrl/ldmanager/actions/workflows/ci.yml/badge.svg"></a>
  <a href="LICENSE"><img alt="MIT 许可证" src="https://img.shields.io/badge/licence-MIT-blue"></a>
  <img alt="macOS 26+" src="https://img.shields.io/badge/macOS-26%2B-black?logo=apple">
  <img alt="Swift 6.2" src="https://img.shields.io/badge/Swift-6.2-F05138?logo=swift&logoColor=white">
  <img alt="SwiftUI" src="https://img.shields.io/badge/UI-SwiftUI-0A84FF">
</p>

<p align="center">
  <a href="#what-it-does">功能</a> ·
  <a href="#install">安装</a> ·
  <a href="#the-ldm-command">CLI</a> ·
  <a href="#why-not-launchcontrol-lingon-or-launchctl">为什么不用……？</a> ·
  <a href="#faq">常见问题</a> ·
  <a href="#contributing">参与贡献</a>
</p>

<p align="center">
  <img src="docs/assets/hero.gif" width="880" alt="LD Manager 中一个失败的任务：检查器显示因程序不存在而退出码为 78，Doctor 给出修复方法，编辑器显示只改了一行的差异，随后任务变为绿色">
  <br><sub>一个任务以退出码 78 失败；LD Manager 说明原因，Doctor 给出修复方法，编辑器显示差异，任务随即正常运行。这些图片中的所有数据均为虚构。</sub>
</p>

> 本文是英文 README 的翻译。**[英文 README](README.md) 是权威且最新的版本**，两者如有出入，以英文版为准。较长的参考性章节在这里只做简要概述，并附有指向英文版对应章节的链接。

`launchctl` 只告诉你 `Bootstrap failed: 5: Input/output error`，剩下的全靠你猜。
LD Manager 会读取 launchd 的每一层信息——磁盘上的 plist、是否已加载、启用/停用覆盖设置、登录项中的开关、PID、启动次数以及上一次的退出码——然后用平实的语言告诉你哪里出了问题、该怎么修。

<a id="what-it-does"></a>

## 功能

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/assets/hero-dark.png">
  <img src="docs/assets/hero-light.png" alt="LD Manager 的主窗口：一张列出各个 launchd 任务及其状态、计划、运行次数和上次结果的表格，旁边的检查器显示所选任务每一层的状态">
</picture>

- **看到每个任务及其真实状态。** 你自己的 LaunchAgent、所有用户的 LaunchAgent、系统 LaunchDaemon，以及 Apple 自带的任务（只读）——每个任务都有一个综合各层信息得出的状态：运行中、等待中、失败、已停用、在登录项中已关闭、未加载或无效。
- **找出失败的原因。** Doctor 会检查：plist 无效、缺少 `Label`，程序不存在、不可执行或带有隔离属性（quarantine），`~` 未展开，所有者或权限错误，日志文件夹不存在，重启循环，已启用但未加载的任务，以及运行失败——并为每一项给出修复方法。
- **用人话读懂计划和退出码。** `StartCalendarInterval {Weekday 1, Hour 9, Minute 30}` 显示为 *Mondays at 09:30*（每周一 09:30），并列出接下来几次的运行时间。`78` 显示为 *EX_CONFIG: usually a missing or non-executable program*（通常是程序不存在或不可执行）；`-15` 显示为 *killed by SIGTERM*（被 SIGTERM 终止）。
- **编辑时不丢任何键。** 提供通俗易懂的表单、Keys 视图和原始 XML 三种方式。修改直接作用于文件本身的字典，所以表单不认识的键也会原样保留。每次保存前都会先显示差异，并保留一份备份，可以在 *Recent Changes* 中恢复。
- **启动、停止、启用、停用、加载、卸载**——可以用开关、为已固定任务提供的菜单栏项目，或者 `ldm` 来完成。
- **可以写进脚本。** `ldm` 是同一套核心的命令行版本，支持 `--json`；`--dry-run` 会打印将要执行的确切 `launchctl` 命令；退出码都有文档说明。

<table>
  <tr>
    <td width="50%"><picture><source media="(prefers-color-scheme: dark)" srcset="docs/assets/doctor-dark.png"><img src="docs/assets/doctor-light.png" alt="Doctor：需要处理的任务列表；对所选任务，列出每一项检查、依据和修复按钮"></picture><br><b>Doctor</b> 解释失败原因并给出修复方法。</td>
    <td width="50%"><picture><source media="(prefers-color-scheme: dark)" srcset="docs/assets/editor-dark.png"><img src="docs/assets/editor-light.png" alt="编辑器：用于设置程序、计划和日志文件的表单，底部显示唯一被修改的那个键的差异"></picture><br><b>无损编辑</b>：保存前先看差异。</td>
  </tr>
  <tr>
    <td width="50%"><picture><source media="(prefers-color-scheme: dark)" srcset="docs/assets/recent-dark.png"><img src="docs/assets/recent-light.png" alt="Recent Changes：plist 备份列表，带有 Show 和 Restore 按钮"></picture><br><b>Recent Changes</b>：每次保存都会保留备份。</td>
    <td width="50%"><img src="docs/assets/cli.png" alt="终端中运行 ldm list、ldm doctor 和 ldm explain 78"><br><b><code>ldm</code></b>：终端里的同一个 Doctor。</td>
  </tr>
</table>

需要 macOS 26 或更高版本。

<a id="install"></a>

## 安装

**[下载 LD Manager for Mac](https://github.com/roeehrl/ldmanager/releases/latest/download/LD-Manager.dmg)**（需要 macOS 26 或更高版本）。应用已经过 Apple 签名和公证：打开磁盘映像，将 LD Manager 拖到“应用程序”文件夹即可。`ldm` 命令就在应用内部，可以在 **Settings → Command-line tool** 中安装，也可以单独下载 [`ldm-macos.zip`](https://github.com/roeehrl/ldmanager/releases/latest/download/ldm-macos.zip)。每个版本都附有 SHA-256 校验和。

<a id="from-source"></a>

### 从源代码构建

你需要 Xcode 26 和 [XcodeGen](https://github.com/yonaskolb/XcodeGen)（`brew install xcodegen`）。

```bash
scripts/build-app.sh
```

这会生成 `build/LD Manager.app`，`ldm` 打包在 `Contents/Helpers` 中。在应用的 **Settings → Command-line tool** 中可以把它链接到 `/usr/local/bin`。

脚本会使用你的第一个 *Developer ID Application* 或 *Apple Development* 证书签名（启用 hardened runtime，可直接公证）；如果设置了 `SIGN_IDENTITY`，则使用它。`SIGN_IDENTITY=-` 表示 ad-hoc 签名：除了特权辅助程序之外，其他功能都能正常使用。

要制作发布版本（签名、公证、staple、磁盘映像、独立的 `ldm` 以及校验和，输出到 `build/release`），请使用 App Store Connect API 密钥凭据或 notarytool 配置文件运行 `scripts/release.sh`，详见脚本开头的说明。

命令行工具也可以单独构建：

```bash
swift build -c release --product ldm
```

用 `swift test` 运行测试。

<a id="quick-start-with-ldm"></a>

### `ldm` 快速上手

```bash
ldm list --status problems     # jobs that need attention
ldm doctor report              # why "report" fails, and how to fix it
ldm explain 78                 # what an exit code means
ldm new backup --every 1h -- ~/bin/backup.sh
ldm logs backup -f
```

依次是：列出需要处理的任务；查看 `report` 为什么失败以及如何修复；查看某个退出码的含义；新建一个每小时运行一次的任务；持续查看它的日志。

<a id="the-ldm-command"></a>

## `ldm` 命令

```text
ldm list [--status failed|running|disabled|problems] [--scope user|allUsers|system] [--json|--plain]
ldm show <job> [--json] [--background]
ldm doctor [<job>] [--json] [--background]
ldm start|stop|restart|load|unload|enable|disable <job> [--dry-run]
ldm logs <job> [-n 40] [-f]
ldm new <name> (--every 15m | --cron "30 9 * * 1" | --keep-alive | --watch <path>) [--log <file>] -- <program> [args…]
ldm edit <job> [--program <path>] [--every …] [--log <file>] [--dry-run]
ldm remove <job> --confirm <label>
ldm explain <code>
ldm helper
```

指定任务时，可以用完整的 label、label 的最后一段、文件名，或者 label 中任何能唯一确定该任务的部分。`--dry-run` 只打印确切的 `launchctl` 命令而不执行。当输出不是终端或设置了 `NO_COLOR` 时，不使用颜色。

`--background` 会重新读取“登录项与扩展”中的“App 后台活动”。macOS 每次都会要求输入密码，所以不加这个参数时，`ldm` 使用上一次读取到的结果。

| 退出码 | 含义 |
|---|---|
| 0 | 成功 |
| 1 | 一般错误 |
| 2 | 用法错误，或名称匹配到多个任务 |
| 3 | 没有这个任务 |
| 4 | 需要管理员授权，或授权被取消 |
| 5 | launchd 拒绝了该操作 |
| 6 | `doctor` 发现了问题 |

<a id="why-not-launchcontrol-lingon-or-launchctl"></a>

## 为什么不用 LaunchControl、Lingon 或 launchctl？

- **LaunchControl** 是功能最完整的 launchd 工具，如果你天天和 launchd 打交道，它物有所值。LD Manager 免费开源，解释得更通俗，还有支持 JSON 输出、可写成脚本的命令行工具。目前 LaunchControl 的专家级功能更多。
- **Lingon** 让创建任务变得很简单，但很少告诉你任务为什么没有运行。LD Manager 正是围绕这个问题打造的。
- **KnockKnock / BlockBlock** 出于安全目的，展示 Mac 上有哪些持久化项目，并在出现新项目时发出提醒。它们不编辑、不启动、也不诊断任务。可以和 LD Manager 一起使用。
- **系统设置 › 通用 › 登录项与扩展** 只为已注册的项目提供开关：没有计划、日志、退出码，也不能编辑。
- **`launchctl` 加文本编辑器** 适合非常熟悉 launchd 的人。LD Manager 会把错误翻译成人话，显示确切的命令（`--dry-run`），并为每次编辑保留备份。
- **`brew services`** 只管理 Homebrew 的软件包。

<a id="faq"></a>

## 常见问题

**用它编辑系统任务安全吗？**
每次保存都会先显示差异并保留备份；签名系统宗卷上的 Apple 任务是只读的；对系统 LaunchDaemon 和 `/Library` 的修改，会通过 macOS 的管理员授权提示，或者经由你只需批准一次的可选辅助程序进行。

**它会往外发送任何数据吗？**
不会。它不建立任何网络连接，也没有任何统计分析。它通过 `launchctl` 读取 launchd 的状态，并读取你磁盘上的 plist 文件。

**为什么需要 macOS 26？**
它使用了最新的 SwiftUI，以及新版 macOS 中登录项（Background Task Management）的行为。是否支持更早的版本可以讨论——请参阅“参与贡献”。

**为什么不上架 Mac App Store？**
沙盒应用无法调用 `launchctl`，也无法读取其他应用的 launchd 任务。

**“LD”是什么意思？**
launchd。

<a id="how-it-works"></a>

## 工作原理（概要）

launchd 的状态没有公开 API，因此 LD Manager 像管理员一样去读取：对每个 domain 运行 `launchctl print`、用 `launchctl print-disabled` 读取覆盖设置，并直接读取 plist 文件；解析器会忽略它不认识的行。“App 后台活动”（早期 macOS 版本中称为“允许在后台”）的开关保存在只有 root 才能读取的 Background Task Management 数据库中，LD Manager 通过 `sfltool dumpbtm` 读取它：没有辅助程序时只在你要求时读取（每次都会弹出管理员授权提示），有辅助程序时则静默读取。这些开关无法通过程序修改，应用会改为打开系统设置中的“登录项与扩展”面板。详见英文版的 [How it works](README.md#how-it-works)。

<a id="the-privileged-helper"></a>

## 特权辅助程序

修改系统 LaunchDaemon 以及 `/Library` 中的文件需要 root 权限。如果不借助辅助程序，每一次这样的操作都会弹出 macOS 的管理员授权提示。LD Manager 也可以安装一个小型辅助程序（`SMAppService` 守护进程，随应用打包），你只需在 **系统设置 › 通用 › 登录项与扩展 › App 后台活动** 中批准一次。

- 启动时不会询问任何事。当你第一次执行需要 root 权限的操作时，LD Manager 会先介绍这个辅助程序，并提供 **Continue**（继续）、**Use Password Instead**（改用密码）或 **Cancel**（取消）三个选项。如果选择使用密码，这个选择会被记住；之后用横幅而不是对话框来提醒你。
- 选择 **Continue** 后，系统设置会打开，旁边附带一份简短的指引。LD Manager 会自动检测到你的批准，确认辅助程序能够响应，然后完成你刚才要做的操作。
- 辅助程序只接受 LD Manager 及其内置的 `ldm`，并通过代码签名验证（同一团队、指定的 bundle identifier）。它只做固定的几件事，每一件都会经过校验：在 `system` domain 上执行 `launchctl`，在 `/Library/LaunchDaemons` 和 `/Library/LaunchAgents` 中写入或删除 plist，修正它们的权限，创建日志文件夹，移除隔离属性，以及读取登录项。
- 随时可以在 **Settings › Privileged helper** 中移除它。`ldm helper` 会报告它是否可以连接。它空闲时会退出，launchd 会从当前的应用重新启动它，所以更新会自动生效（`ldm helper --restart` 可以强制重启）。

修改通过 `launchctl bootstrap`、`bootout`、`enable`、`disable`、`kickstart` 和 `kill` 完成。对系统 LaunchDaemon 的修改以及对 `/Library` 的写入，会通过 macOS 要求输入管理员密码。

<a id="layout"></a>

## 代码结构（概要）

`Sources/LDCore` 是核心（任务模型、plist 读取与无损编辑、`launchctl` 适配层、计划、退出码和 Doctor），`Sources/ldm` 是命令行工具，`Sources/LDManagerHelper` 是以 root 运行的特权辅助程序，`App/` 是 SwiftUI 应用，`Tests/` 是单元测试，`demo/` 是用于生成截图的虚构演示环境。完整目录说明见英文版的 [Layout](README.md#layout)。

<a id="contributing"></a>

## 参与贡献

欢迎提交 issue 和 pull request——附上 `ldm show <job> --json` 输出的 bug 报告最有帮助。可以从标有 [`good first issue`](https://github.com/roeehrl/ldmanager/labels/good%20first%20issue) 和 [`help wanted`](https://github.com/roeehrl/ldmanager/labels/help%20wanted) 的 issue 入手。60 秒完成开发环境配置的方法见 [CONTRIBUTING.md](CONTRIBUTING.md)；截图所用的虚构演示环境见 [`demo/`](demo/README.md)，这样测试改动时完全不必动你自己的 launchd 任务。

<a id="roadmap"></a>

## 路线图

- 在有程序添加或修改 launchd 任务时发出通知，并提供即将运行的任务时间线。
- 后台项目浏览器：所属应用、Team ID、孤立项目。
- 快捷指令操作，以及常见任务的模板。

<a id="license"></a>

## 许可证

MIT——见 [LICENSE](LICENSE)。LaunchControl、Lingon、KnockKnock 和 BlockBlock 是其各自所有者的产品；LD Manager 与它们以及 Apple 均无关联。
