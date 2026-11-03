# 第三方代码来源说明

## iPhoneDuoByExamples

- **上游仓库**：https://github.com/artemnovichkov/iPhone-Duo-by-Examples
- **作者**：Artem Novichkov
- **许可证**：MIT（见同目录 `LICENSE`，完整保留未改动）
- **取用版本**：`main` @ `50f8ea9f8eba1bdce44b50e4ab3ce404ca2b1e3c`（2026-10-10）
- **获取方式**：`codeload.github.com` 的 tarball（本机 `github.com` 的 git 协议不可达）

### 做了什么改动

| 文件 | 改动 | 原因 |
|---|---|---|
| `iPhoneDuoByExamples.xcodeproj/project.xcproj` | `PRODUCT_BUNDLE_IDENTIFIER` 由 `com.artemnovichkov.iPhoneDuoByExamples` 改为 `com.cxh1996.iPhoneDuoByExamples` | 原 bundle id 属作者团队，免费 Apple ID 签名时无法注册同名 App ID，会直接失败 |
| `iPhoneDuoByExamples.xcodeproj/project.xcproj` | 登记新文件 `HingeRecorderExample.swift` 与 `Info.plist`；target 增加 `INFOPLIST_FILE` | 本工程是**显式登记**（不是目录自动同步），不登记就不参与编译 |
| `Examples/HingeRecorderExample.swift` | **新增文件**（不属于上游） | 采集需求：角度 + 单调时间戳 + 切屏重排事件 → CSV/TXT，可分享导出 |
| `Catalog/Example.swift` | 新增 `hingeRecorder` case（7 处 switch 补齐） | 侧栏出现入口 |
| `App/iPhoneDuoByExamplesApp.swift` | 根视图加 `.modifier(HingeRecordingHost())` | 录制跨页面存活，不依赖示例页 |
| `Catalog/ExampleScreen.swift` | `Repository.url` 改指本仓库并补 `vendor/` 前缀 | 否则新示例的 "View Source" 是 404 |
| `iPhoneDuoByExamples/Info.plist` | **新增文件**，只含 `UIFileSharingEnabled` | Xcode 的 plist 生成器**不接受** `INFOPLIST_KEY_UIFileSharingEnabled`（实测 31 个键里缺失），只能用基础 plist 合并 |
| 目录裁剪 | 未纳入 `.github/images/`（6.4 MB 截图）、`.agents/`、`.codex/`、`.mcp.json`、`AGENTS.md`、`skills-lock.json` | 与编译无关；`README.md` 里的图片链接因此失效，其余内容保持原样 |

**上游原有的 24 个 Swift 文件一行未改**；新增的 `HingeRecorderExample.swift` 是本仓库独立编写，同样以 MIT 分发。

### 这个工程的技术特征（供参考）

- Xcode 27 的**新工程格式**：`project.xcproj` 是带尾逗号的 JSON（**不是**传统 `project.pbxproj`），必须用 Xcode 27+ 打开，旧版 Xcode 完全无法识别。
- `IPHONEOS_DEPLOYMENT_TARGET = 27.1`、`SWIFT_VERSION = 6.0`、`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`。
- 单 target `iPhoneDuoByExamples`，app 类型，`TARGETED_DEVICE_FAMILY = 1,2`。
- 工程内**没有** `xcshareddata/xcschemes`，scheme 依赖 Xcode 自动生成 —— CI 里因此优先用 `-target` 构建，失败再退回 `-scheme`。

### 复用它做什么

在本仓库的 GitHub Actions 里编译成**未签名 IPA**，再在 Windows 上用 Sideloadly + 免费 Apple ID 签名装到 iPhone Duo。
上游项目本身不提供任何构建产物（无 CI、无 Release），所以必须自己编。

按 MIT 条款，本目录保留原始版权声明与许可证全文；上述改动仅用于适配个人侧载，不改变原作者著作权。
