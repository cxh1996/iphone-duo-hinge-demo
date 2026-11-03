# iPhone Duo 铰链 API 研究：可安装的 Demo App

在**没有 Mac、不花一分钱**的前提下，把 iPhone Duo 的铰链角度 Demo 编成 `.ipa` 并装进真机。

当前状态：**已构建成功，产物 `out/iPhoneDuoByExamples-unsigned.ipa`（885 KB）**，等你用 Sideloadly 签名安装。
本版新增 **Hinge Recorder** 示例：把每次铰链回调的「角度 + 单调时间戳」连同切屏重排事件录成 CSV/TXT，可直接分享到电脑。

---

## 1. 这个东西是什么

上游项目 [artemnovichkov/iPhone-Duo-by-Examples](https://github.com/artemnovichkov/iPhone-Duo-by-Examples)（MIT，78 stars），一个 SwiftUI 示例目录 App，15 个示例覆盖 iOS 27.1 全部 iPhone Duo 新 API：

| 分类 | 示例 |
|---|---|
| **铰链读数（你们要的）** | `HingeAngleExample`（`onHingeChange` 实时角度）、`HingeHistoryExample`（角度变化历史） |
| **数据采集（本研究新增）** | `HingeRecorderExample` —— 角度 + 单调时间戳 + 切屏重排事件录成 CSV/TXT，可分享导出 |
| 折痕与布局 | `ReservedRegionsExample`、`AvoidDivisionExample`、`SafeAreasExample`、`ContainerMarginsExample` |
| 分屏形态 | `SplitArrangementExample`、`OverlayArrangementExample`、`CustomArrangementExample`、`EvenColumnsExample`、`DualPanePatternsExample`、`SplitViewSideExample` |
| 姿态相关 | `FoldedUnfoldedExample`、`TabletopExample`、`VerticalToolbarExample`、`ToolbarPriorityExample`、`CoverAccessoryExample` |

源码在 `vendor/iPhoneDuoByExamples/`，上游 24 个 Swift 文件与原始版本逐字节一致；新增 1 个 `HingeRecorderExample.swift`，
并改了 4 个文件（bundle id、示例注册、根视图订阅、View Source 链接）。逐条改动见 `vendor/NOTICE.md`。

## 2. 怎么装到 iPhone Duo

前置：手机开「设置 → 隐私与安全性 → 开发者模式」，Windows 装好 Sideloadly 与 Apple 驱动（`scripts/bootstrap-windows.ps1` 一键装齐）。

1. 双击打开 **Sideloadly**，iPhone 用数据线连电脑，手机上点「信任此电脑」
2. 把 `out/iPhoneDuoByExamples-unsigned.ipa` 拖进 Sideloadly 的 IPA 框
3. **Apple ID** 填你的免费 Apple ID（不需要付费开发者账号）
4. 点 **Start**，按提示输入密码（如需双重认证，Sideloadly 会让你在弹窗里填验证码）
5. 完成后手机上「设置 → 通用 → VPN 与设备管理」→ 信任你的开发者证书
6. 打开 App「Duo by Examples」→ 进 **Hinge Angle** 折手机看角度；要采数据就进 **Hinge Recorder**

**免费账号的三个硬限制**（Apple 定的，与工具无关）：每次签名 **7 天过期**、最多同时 **3 个 App**、不能上 TestFlight/App Store。7 天到期用同一个 ipa 重装即可覆盖，Sideloadly 的 `sideloadlydaemon` 可以自动续签。

> iTunes / iCloud **不用装**。Sideloadly 0.60 的更新日志写明「2FA now works correctly even without iTunes (Windows)」，官网那句「requires iTunes & iCloud」是旧文案。本机 iTunes 也确实装不上（winget 静默参数绕过提权 → MSI 1603；事件日志 `MsiInstaller 10005 没有足够权限为所有机器用户安装`），但不影响安装流程。
>
> 只需要登录 **Sideloadly 里的 Apple ID**（免费账号 + 双重认证）；手机端**不需要登录任何账号**，只要「信任此电脑 / 开发者模式 / 信任证书」三步授权。

## 3. 采一次数据：Hinge Recorder 怎么用

进 **Hinge Recorder**，一次会话的完整流程：

1. 点 **Start Recording**（会话文件在点下的那一刻创建，之后每秒落盘一次）
2. 按界面里 **What to capture** 的三条协议折手机：P1 停在 90° 不动 10 秒 → P2 慢扫 0°→180° 三次 → P3 快速开合三次
3. 想标记某刻就点 **Mark**（可填备注），比如「合到一半停住」
4. 点 **Stop & Save** → 下方 **Exports** 列表出现 `hinge-<时间戳>.csv` 和 `.txt`
5. 点 **Share CSV + TXT** → 分享面板 → 微信「文件传输助手」/ 邮件 / 存到「文件」→ 电脑

生成的两个文件：

| 文件 | 内容 |
|---|---|
| `hinge-*.csv` | 10 列纯原始量：`seq,event,mono_ns,epoch_s,angle_deg,angle_rad,status,w_pt,h_pt,note`，UTF-8 带 BOM（Windows Excel 直接双击不乱码） |
| `hinge-*.txt` | 人眼可读摘要（投递间隔 median/p95/max、角度范围与最小步长、断档、每次切屏的夹逼区间）+ 同一份数据的制表符表格 |

关键设计取舍写在 `docs/MEASUREMENT-PLAN.md`：录制期间**不画图、不统计**，只留 2 Hz 大字 HUD；
回调里只读角度 + 取 `mach_continuous_time` + 追加一行，不做格式化，避免用主线程跟被测对象抢时间。
`geom` 行（窗口尺寸变化）是「切屏」的直接证据，它和 `hinge` 行在同一时钟上，所以能算「切屏发生在多少度」。

## 4. 怎么重新构建

改动 `vendor/` 下的代码后，一条命令：

```bash
python scripts/push-via-api.py --branch main --message "改了什么"   # 推送（增量，只传改动文件）
python scripts/build-and-fetch.py                                   # 等构建 + 下载 ipa 到 out/
```

`build-and-fetch.py` 会按 commit sha 找到对应的 run，轮询到结束；**失败时自动打印失败步骤和日志尾部**，成功则把 ipa 解到 `out/`。

也可以直接去 Actions 页面手动 Run workflow，可调两个参数：`runner`（默认 `xcode-27`）、`min_sdk`（默认 `27.1`）。

## 5. 关键技术事实（踩出来的，别再试错）

| 事实 | 说明 |
|---|---|
| **runner 必须是 `xcode-27`** | 该镜像基于 macOS 27.0.1，预装 **Xcode 27.1（默认）**、27.2 RC、27.0。`macos-26` 只有 Xcode 26.0–26.6，实测直接编不了 —— 已由流水线里的 SDK 闸门拦下 |
| **工程是 Xcode 27 新格式** | `project.xcproj` 是**带尾逗号的 JSON**，不是 `project.pbxproj`。旧版 Xcode 连打开都不行，严格 JSON 解析器也会报错，别去"修"它 |
| **产物必须未签名** | CI 关掉全部签名（`CODE_SIGNING_ALLOWED=NO`），签名交给 Sideloadly + 免费 Apple ID。这样 CI 不需要任何证书/Secrets，也就没有任何付费门槛 |
| **本机 `github.com` 的 git 协议不可达** | 经代理 TLS 握手失败，schannel 和 openssl 两个后端都一样。改用 curl 调 **GitHub REST API**（`api.github.com` 稳定）完成推送 |
| **空仓库不能用 Git Data API** | 会返回 `409 Git Repository is empty`，必须先用 Contents API 落一个文件引导 |
| **本机到 api.github.com 约 50% 丢包** | 所有请求都要重试。推送脚本因此做了增量上传（本地算 blob SHA-1 与远端比对），全量 45 文件要 16 分钟，增量 4 文件几秒 |

## 6. 已验证的产物信息

```
CFBundleIdentifier    = com.cxh1996.iPhoneDuoByExamples
CFBundleDisplayName   = Duo by Examples
MinimumOSVersion      = 27.1
DTSDKName             = iphoneos27.1        ← 确实用 iOS 27.1 SDK 编的
CFBundleSupportedPlatforms = [iPhoneOS]
UIDeviceFamily        = [1, 2]
UIFileSharingEnabled  = true                ← 「文件」App 里能看到 Exports/
LSSupportsOpeningDocumentsInPlace = true
可执行文件              = 2,443,064 B（arm64）
_CodeSignature         = 无（未签名，符合预期）
embedded.mobileprovision = 无
二进制符号             = 含 onHingeChange / DeviceHinge / HingeRecorder / HingeRecordingHost / mach_continuous_time
```

## 7. 文件清单

```
├── vendor/iPhoneDuoByExamples/        上游工程（MIT，见 NOTICE.md）
│   └── iPhoneDuoByExamples/Examples/HingeRecorderExample.swift   ← 新增的采集器
├── docs/MEASUREMENT-PLAN.md           采集方案 + 实施记录 + 离线分析脚本
├── .github/workflows/build-unsigned-ipa.yml   云端构建流水线
├── scripts/
│   ├── gh-device-login.py      设备码登录，拿可写 token 存到 ~/.config/duo-ci-token
│   ├── push-via-api.py         走 REST API 推送（绕过被墙的 git 协议），增量上传
│   ├── build-and-fetch.py      跟踪构建 + 下载 ipa，失败自动打日志
│   └── bootstrap-windows.ps1   装 Apple 驱动三件套 + Sideloadly（需 UAC）
├── out/iPhoneDuoByExamples-unsigned.ipa       ← 构建产物
└── HingeDemo/                          早期自写的极简 demo（含 UIKit 交叉验证页，未参与构建）
```

## 8. 给 display 模块同事的对照

| 维度 | Android | iOS 27.1 |
|---|---|---|
| 角度来源 | `Sensor.TYPE_HINGE_ANGLE`（0–360°，度） | `onHingeChange { _, ctx in ctx.hinge.angle }`（`Angle`，取 `.degrees`；UIKit 版是弧度） |
| 状态 | `FoldingFeature.State`：FLAT / HALF_OPENED | `hinge.status`：`.closed` / `.partiallyOpen` / `.fullyOpen` |
| 姿态 | 由 state + orientation 推导 | **无 pose 枚举**，书本式与三脚架式都报 `partiallyOpen`，要用折痕 frame（高>宽 = 书本式）反推 |
| 采样率 | 传感器固定速率 | **系统策略决定**，官方不承诺固定频率，不能假设等间隔采样 |
