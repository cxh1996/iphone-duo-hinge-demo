# iPhone Duo 铰链角度探针 Demo —— 从 Windows 电脑到真机

> 目标：在 iPhone Duo 真机上跑一个能实时显示折叠角度的最小 App，用来对照你们 Android display 模块的折叠屏方案。

---

## 0. 先说结论（重要）

iOS 真机 App 的构建与安装，必须经过「macOS + Xcode 签名 + USB/网络配对」这条链路。
**Windows 上没有任何官方手段能编译或安装 iOS 应用**（Apple 的「设备」App 只能备份/升级，不装应用；
Transporter 也只有 Mac 版）。

所以对你们目前「一台 Windows 电脑 + 一台 iPhone Duo」的组合，有四条现实路径（**不想花钱就走第 5 节的路径 D**）：

| 路径 | 需要什么 | 花钱吗 | 耗时 |
|---|---|---|---|
| **D. GitHub Actions 编译 + Windows 本机免费签名**（零成本，见第 4 节） | 一个 GitHub 仓库 + Windows 上的 Sideloadly + 免费 Apple ID | **0 元** | 1 小时 |
| **A. 借/租一台 Mac** | 任意 Apple Silicon Mac，macOS Tahoe 26.6+，Xcode 27.1 | 借 = 0 元；租 = 几美元/小时 | 半天 |
| **B. 纯 Windows + CI + TestFlight/OTA 分发** | 付费 Apple Developer Program（$99/年） | 99 美元/年 | 1~2 天 |
| **C. 让人代跑模拟器** | 同事有 Mac；Device Hub 有 Closed / Partially Open / Open 按钮和角度滑块 | 0 元 | 1 小时 |

不要走的弯路：在 Windows 上装 macOS 虚拟机。既违反 Apple 许可，而且 Xcode 27.1 要求
Apple Silicon + macOS 26.6+，Intel 虚拟机根本跑不起来。

---

## 1. 你要研究的那个 API（iOS 27.1 新增）

iPhone Duo 的铰链 API 在 **iOS 27.1 SDK / Xcode 27.1** 里提供，SwiftUI 和 UIKit 各一套：

| | SwiftUI | UIKit |
|---|---|---|
| 入口 | `View.onHingeChange(isEnabled:_:)` | `UIHingeInteraction`（挂在某个 view 上） |
| 回调 | `(previousContext, currentContext)` | `(previous, update)` |
| 当前值 | `context.hinge`（optional，nil = 无铰链设备） | `update.hinge` |
| 离散状态 | `hinge.status`：`.closed` / `.partiallyOpen` / `.fullyOpen` | 同左 |
| 连续角度 | `hinge.angle`（SwiftUI `Angle`，取 `.degrees` / `.radians`） | `hinge.angle`（**弧度**） |

配套的布局 API：

- `GeometryProxy.reservedRegions(kind:)`：`.division` 取折痕位置，`.occlusion` 取灵动岛/摄像头遮挡。**判断「书本式 vs 三脚架式」只能靠这个**——两者 status 都是 `partiallyOpen`，区别是折痕横着还是竖着。
- `ArrangementView` / `UIArrangementViewController`：`.split` / `.overlay` 两套排版。
- `toolbarVerticalBehavior`：外屏和横屏内屏时导航栏/工具栏竖排。

两个关键限制（Apple 在 Group Lab 里明确说过）：

1. **没有统一的 pose 值**，要自己用 status + 角度 + size class + 折痕方向组合推断。
2. **角度更新频率和精度属于系统策略**，会随系统状态变化，不要依赖固定采样率做算法（这点和 Android 的传感器模型差别很大，做 display 模块时序设计时要留余量）。

### 和 Android 的对照（你们最关心的映射关系）

| 概念 | Android | iOS 27.1 |
|---|---|---|
| 连续角度 | `Sensor.TYPE_HINGE_ANGLE`，`values[0]` 为 0~360°，单位**度**（旧机型靠名字 "Hinge Angle" 查；Jetpack WindowManager 的 `FoldingFeature` 不给角度） | `hinge.angle`，**弧度**，实际范围约 0~π。粒度/频率由系统决定 |
| 离散状态 | `FoldingFeature.state`：`FLAT` / `HALF_OPENED`；`DeviceState`：`CLOSED`/`OPEN`/`HALF_OPENED` | `hinge.status`：`closed` / `partiallyOpen` / `fullyOpen` |
| 折痕方向 | `FoldingFeature.orientation`：`HORIZONTAL` / `VERTICAL` | 无直接枚举，用 `reservedRegions(kind: .division)` 的 frame 长宽比反推 |
| 折痕位置 | `FoldingFeature.bounds` | `reservedRegions(kind: .division)` 的 frame |
| 分屏容器 | `SlidingPaneLayout` / 双栏布局 | `ArrangementView` / `UIArrangementViewController` |

一句话：Android 是「传感器给连续角度 + WindowManager 给状态」，iOS 是「一个回调同时给状态和角度」，
但 iOS 没有 pose 枚举，也没有 0~360 的完整量程（360° 那种反面折叠 iPhone Duo 不存在）。

---

## 2. Demo 代码

目录 `HingeDemo/`，全部是可直接粘进 Xcode 新工程的单个文件（SwiftUI App 模板）：

| 文件 | 作用 |
|---|---|
| `HingeDemoApp.swift` | App 入口 |
| `ContentView.swift` | **主力**：大号角度读数、状态胶囊、0~180° 刻度条、最近变化日志、`print("[HINGE] ...")` 打控制台 |
| `HingeProbeViewController.swift` | UIKit 版（`UIHingeInteraction`），验证两套 API 数据是否一致 |
| `PoseProbeView.swift` | 可选：读 `reservedRegions` 判断书本式/三脚架式 |

要点：

- 若项目 deployment target 设成 iOS 27.1，`@available` 都不用加；设成 27.0 则相关代码要加 `@available(iOS 27.1, *)`。
- Swift 6 严格并发模式下，如果在 `onHingeChange` 闭包里改 `@State` 报错，把整段包进 `MainActor.assumeIsolated { ... }`，或把工程 Language Mode 调成 Swift 5。
- 想把 `PoseProbeView` 显示出来，在 `ContentView` 底部加一行 `if #available(iOS 27.1, *) { PoseProbeView().frame(height: 80) }`。

---

## 3. 路径 A：借/租一台 Mac（半天搞定）

### 3.1 Mac 侧

1. Mac 必须 **Apple Silicon + macOS Tahoe 26.6 或更高**（Xcode 27.1 的硬性要求，Intel Mac 不行）。
2. 装 **Xcode 27.1**（27.1 才是第一个正式支持 iPhone Duo 的版本；27.0 不支持）。
   `xcode-select -p` 确认路径，首次启动装组件。
3. Xcode → File → New → Project → **iOS App**，Interface 选 **SwiftUI**，Language 选 **Swift**。
4. 删掉自动生成的 `ContentView.swift`，把本目录下的 4 个文件拖进去（勾选 Copy items if needed + 目标 target）。
5. 选中 target → Signing & Capabilities → 勾 **Automatically manage signing** → Team 选你的 Apple ID
   （免费 Apple ID 也行，但证书 **7 天后过期**，需要重新 Run 一次；付费账号则是 1 年）。
6. 数据线连 iPhone Duo → 手机上点「信任此电脑」。
7. Xcode 顶部 run destination 选你的 iPhone Duo → ⌘R。
8. 手机上第一次打开会拦：设置 → 隐私与安全性 → **开发者模式** → 打开 → 重启 → 输入密码确认。
   再打开 App 若提示未受信任的开发者：设置 → 通用 → VPN 与设备管理 → 信任你的开发者证书。

### 3.2 没 Mac 但能租

- MacinCloud / MacStadium / Scaleway Apple Silicon / AWS EC2 mac 实例，按小时计费，几美元起。
- 租来的机器同样要检查：能否装 Xcode 27.1、USB 是否能直通（云 Mac 一般用 **网络配对**：
  Xcode 27 的 Device Hub 支持无线连接设备，前提是手机和 Mac 在同一网络；云 Mac 会麻烦一些，
  通常改用 **Ad Hoc 打包 + OTA 安装**，见路径 B）。

---

## 4. 路径 B：全程 Windows（CI 构建 + TestFlight / OTA 安装）

这条路的本质：**把「构建签名」搬到云端 macOS runner，Windows 只负责点按钮和收包。**

前置条件：

- 付费 **Apple Developer Program**（$99/年）。免费 Apple ID 无法做 Ad Hoc / TestFlight 分发。
- 记下 iPhone Duo 的 **UDID**（手机连 Windows，用苹果「设备」App 或 `iTunes`/第三方工具读；也可以在
  手机 Safari 打开一个描述文件安装页读 UDID）。Ad Hoc 描述文件里必须包含这个 UDID。
- runner 上要有 **Xcode 27.1**。GitHub Actions 的 `macos-*` 镜像版本会滞后，先在 workflow 里
  `xcodebuild -version` 打印确认；没有就用自托管 Mac、Codemagic / Bitrise（它们更新快）或云 Mac 手动打一次包。

流程：

1. 在 GitHub 建私有仓库，提交本目录代码 + 一个 `.xcodeproj`（**xcodeproj 只能在 Mac 上生成**，
   所以这一步要么找有 Mac 的同事生成一次并提交，要么直接用 XcodeGen 的 `project.yml` 在 CI 里生成）。
2. CI 里 `xcodebuild archive` + `-exportArchive`（`method: ad-hoc` 或 `development`）产出 `.ipa`。
   签名用 App Store Connect API Key + `-allowProvisioningUpdates`（云端证书），证书不用手动搬。
3. 把 `.ipa` 送到手机，二选一：
   - **TestFlight**：CI 里上传到 App Store Connect（`xcrun altool` / `notarytool` / fastlane `pilot`），
     在 App Store Connect 加内部测试员（自己），手机装 TestFlight App 接受邀请即可安装。**Windows 全程浏览器操作。**
   - **OTA 安装链接**：把 `.ipa` 和 `manifest.plist` 放 HTTPS 服务器，手机上 Safari 打开
     `itms-services://?action=download-manifest&url=https://.../manifest.plist` 点安装。
4. 手机侧仍需：开启 **开发者模式** + 信任开发者证书；Ad Hoc/Development 包首次启动要联网向 Apple 校验。

> 顺带一提：市面上有 Windows 端签名/安装工具（Sideloadly、Appuploader 之类），它们能解决「把已签名的
> ipa 装到手机」这一步，但仍然需要一个已签名的 ipa —— 编译环节绕不开 macOS。

---

## 5. 路径 D：零成本路线（不付费、不用 Mac）★ 推荐给你们

原理只有两句话：

1. **编译**放在 GitHub Actions 的免费 macOS runner 上做，而且**产出「未签名 IPA」**——不做签名就不需要任何证书、任何付费账号。
2. **签名 + 安装**在你们这台 Windows 上做：用免费 Apple ID 调 Apple 的免费签名（Personal Team）接口，通过 USB 装进 iPhone Duo。

免费签名能干什么、不能干什么（这是 Apple 的规则，不是工具的限制）：

| 项目 | 免费 Apple ID（Personal Team） |
|---|---|
| 有效期 | **7 天**，到期重新签一次即可（App 不用删，覆盖安装） |
| 同时装的 App 数 | **3 个** |
| 7 天内可新建 App ID | 10 个 |
| 能上 TestFlight / App Store | **不能**（那是付费账号才有的分发方式） |
| 能让别人装 | 不能，只签给自己的设备 |

对「临时装个 Demo 研究一下铰链角度」这个需求，7 天完全够用。

### 5.1 仓库结构（已经给你写好了）

```
iPhoneDuoHingeDemo/
├── project.yml                              # XcodeGen 工程描述，CI 上现场生成 .xcodeproj
├── HingeDemo/                               # 4 个 Swift 源文件
└── .github/workflows/build-unsigned-ipa.yml # 流水线：选 Xcode 27.1 → 编译 → 出未签名 ipa
```

`.xcodeproj` 是二进制式的工程文件，在 Windows 上没法生成，所以用 **XcodeGen**：工程结构用
`project.yml` 这个纯文本描述，runner 上 `xcodegen generate` 现生成。这样仓库在 Windows 上维护毫无障碍。

### 5.2 Windows 侧操作步骤

**第 1 步：把代码推到 GitHub**

```bash
cd iPhoneDuoHingeDemo
git init && git add . && git commit -m "iPhone Duo hinge demo"
gh repo create hingedemo --public --source=. --push     # 或网页手动建仓库再 push
```

> **建议用 public 仓库**：GitHub 对 public 仓库的 Actions 分钟数不限量；private 仓库 macOS runner 有
> **10 倍系数**（免费额度 2000 分钟 ≈ 实际 200 分钟），虽然一次构建只要 3~5 分钟也够，但没必要冒额度风险。
> 代码里没有敏感信息（只是 demo）。

**第 2 步：跑流水线**

Actions 页面 → `build-unsigned-ipa` → Run workflow。它会：

- 在 `xcode-27` 镜像（macOS 27 + Apple Silicon，2026-10-15 GA）里挑出 **Xcode 27.1** 并 `xcode-select`
- 打印 `xcodebuild -version` 和 iPhoneOS SDK 版本，方便你核对是 27.1
- `xcodegen generate` 生成工程
- `xcodebuild ... CODE_SIGNING_ALLOWED=NO` 编译（全关签名）
- 打包成 `Payload/HingeDemo.app` → `HingeDemo-unsigned.ipa` → 作为 artifact 上传

跑完在页面底部下载 `HingeDemo-unsigned-ipa`（是个 zip，解开拿到 `.ipa`）。

> 如果 `xcode-27` 标签在你的账号下不可用，或报「镜像里没有 Xcode 27.x」：
> 换 Codemagic（免费额度 500 分钟/月，Xcode 版本跟进最快）或 Bitrise 免费层跑同一份脚本；
> 也可以临时用 `macos-15` 标签试运气——但**没有 iOS 27.1 SDK 就编不出带 `onHingeChange` 的代码**，
> 这一步会是硬失败，而不是静默降级。

**第 3 步：Windows 上签名安装（免费 Apple ID）**

1. 装 [Sideloadly](https://sideloadly.io)（只从官网下），Windows 上另需装 **网页版 iTunes 和 iCloud**
   （Sideloadly 靠它们的驱动识别设备）。
2. 手机用数据线连电脑，解锁，点「信任此电脑」。
3. 手机：设置 → 隐私与安全性 → **开发者模式** → 打开 → 重启 → 输密码。
4. 打开 Sideloadly，确认顶部设备选中了 iPhone Duo，把 `HingeDemo-unsigned.ipa` 拖进去。
5. Apple ID 填你的免费账号，点 Start，按提示完成双重认证（**不要用 App 专用密码**，Sideloadly 的
   App 专用密码只对付费账号有效）。
6. 装完如果打不开、提示未受信任：设置 → 通用 → VPN 与设备管理 → 点你的 Apple ID → 信任。
7. 打开 App，来回折手机，看角度数字变化。

**第 4 步：7 天后续期**

到期后 App 打不开是正常现象。重新用 Sideloadly 装一次**同一个 ipa、同一个 Apple ID**即可覆盖（不用先删，
数据也在）。Sideloadly 提供了 auto-refresh 守护进程：电脑只要还能 USB/同 Wi-Fi 连上手机，会提前自动重签。
若嫌麻烦，另一条路是 AltStore 的 AltServer（Windows 版），逻辑一样。

### 5.3 这条路的 3 个坑

1. **bundle ID 可能被迫改名**：Apple 不允许免费账号签名与 App Store 已上架应用同 bundle ID 的包，
   Sideloadly 会强制换一个唯一 ID。我们用的是 `com.example.hingedemo`，不会冲突，包名正常不变。
2. **每次改代码都要走一轮「push → 等 CI → 下载 → 重签」**，约 5~10 分钟一轮。调 UI 时比较磨人，
   建议一次性把要观察的指标都做进界面（当前 `ContentView` 已经包含角度、弧度、状态、回调计数、变化日志）。
3. **不要在 CI 里试图做「带签名的 ipa」**：免费账号没有 Ad Hoc 分发能力，且把证书塞进 GitHub Secrets
   属于长跑场景。未签名 + 本机签名是零成本路线唯一稳的组合。

---

## 6. 路径 C：只验证 API 语义（不用真机）

Xcode 27.1 的 **Device Hub** 里有 iPhone Duo 模拟器，带 Closed / Partially Open / Open 三个按钮
和一个角度滑块，可以把角度拖到任意值看你的 UI 反应。已知限制（Apple release notes）：

- `simctl` / `devicectl` / XCUIDevice 都**没有**命令行改姿态/角度的接口，只能手拖。
- 模拟器里 StandBy 和大部分 App Extension 不可用。
- 模拟器的角度是「人造输入」，**不能替代真机的时序、抖动、精度特性**——做 display 模块的时序逻辑
  必须回真机验证。

---

## 7. 常见坑

1. **黑边**：用 iOS 26 SDK 或更早编译的 App，在展开的内屏上会保留 iPhone 尺寸窗口。必须用 iOS 27.1 SDK 重编。
2. **布局判断错**：不要用 device idiom、不要用 interface orientation 决定布局，用 scene 尺寸 + size class + `reservedRegions`。
3. **把 angle 当成 0~360**：iOS 侧大致只有 0~180（闭合 0、半开中间值、展平 π）。跨端做角度归一化时注意量纲和单位（弧度 vs 度）。
4. **依赖固定回调频率**：官方明确说频率/精度是系统策略，别写死 60Hz 之类的假设。
5. **免费账号 7 天掉签**：Demo 忽然打不开了，重新插线 Run 一次即可。

---

## 8. 下一步

零成本路线的最小动作清单：

1. Windows 上装好 Sideloadly + 网页版 iTunes/iCloud，手机上打开开发者模式（这两步不依赖 CI，可以并行做）。
2. 把 `iPhoneDuoHingeDemo/` 推到 GitHub public 仓库，跑一次 `build-unsigned-ipa`，确认 artifact 里有 `.ipa`。
3. 用免费 Apple ID 签进去，先确认「App 能装能开、角度能跳」。
4. 再谈要不要在真机上做更细的验证（回调频率分布、角度抖动、0°/180° 边界、开合过程中的重复回调等）——
   这些是你们做 display 模块时序设计真正需要的数据，我可以把采样统计和导出 CSV 也加到界面里。

如果第 2 步卡住（例如 `xcode-27` 镜像里确实没有 Xcode 27.1），把 Actions 的日志贴给我，我按报错改流水线。

---

## 9. 本机执行记录（2026-11-02，Windows）

已经自动做完的部分：

| 项 | 状态 | 说明 |
|---|---|---|
| 检查工具链 | ✅ | git 2.55 / gh 2.102 / winget 1.29 / python 3.13 均在位 |
| GitHub 登录态 | ✅ | `gh` 已登录为 **cxh1996**（fine-grained PAT） |
| 本地仓库 | ✅ | `git init` + 3 次提交，分支 `main`，含 `.gitattributes` |
| 一键脚本 | ✅ | `scripts/bootstrap-windows.ps1`、`scripts/fetch-ipa.sh` |
| Apple 驱动三件套 | ✅ | `Apple Mobile Device Support 19.4.0.10`（服务 **Running**）、`Apple Application Support 8.7`、`Bonjour 3.1.0.1` |
| Sideloadly 安装包 | ✅ 已下载 | `~/Downloads/SideloadlySetup64.exe`，137.5 MB，官方站直下（`NotSigned` 属正常） |
| Sideloadly 安装 | ⏳ 待双击 | `/S` 静默安装退 0 但未落地；提权启动被本机安全策略拦 |
| 建远端仓库 | ❌ | PAT 缺 **Repository creation** 权限（重试 5 次均 403，已排除网络抖动） |

接下来两件事需要人点：

1. **建空仓库**：github.com → New repository → `iphone-duo-hinge-demo` → **Public** → 不要初始化。
   或者：Settings → Developer settings → Fine-grained tokens → 该 token → Account permissions →
   **Repository creation: Read and write** → 保存。之后一条命令就能跑到出 ipa。
2. **装 Sideloadly**：双击 `C:\Users\xuhui\Downloads\SideloadlySetup64.exe` → 允许 UAC → 下一步到底。

仍然必须人工的：插手机点「信任此电脑」、手机里开开发者模式、Sideloadly 里输 Apple ID + 双重认证。
