# 铰链角度采集方案与实施记录（iPhone Duo）

> 目标：搞清楚「一次开合过程中，铰链角度随时间如何变化」，以及「系统真正的切屏（窗口重排）发生在多少度」。
> 状态：**已实现并编入 IPA**，实现在
> `vendor/iPhoneDuoByExamples/iPhoneDuoByExamples/Examples/HingeRecorderExample.swift`（示例名 **Hinge Recorder**）。

---

## 1. 先说结论：系统不缓存，缓存只能我们做

- iOS **没有**任何「铰链角度历史」API。`onHingeChange` 只在更新发生的瞬间投递一次回调，
  频率与粒度由系统策略决定（上游示例 `HingeHistoryExample.swift` 头部注释原文：
  *"The rate and granularity of angle updates are system policy"*）。
- `isEnabled: false` 期间的回调**直接丢弃、事后不补发**。
- 因此「切屏那一刻的角度」在 App 侧只能是**夹逼区间** `[angle_before, angle_after]`，
  误差上界 = 该时刻前一条样本的 `dt`。**不做插值**（折叠过程中若有回弹，插值结果是错的）。

## 2. 三个硬约束

| 约束 | 含义 | 应对 |
|---|---|---|
| 投递通道即上限 | App 再优化也不会比系统投递更细 | 先测通道（P1/P2/P3 协议），别急着建管道 |
| 主线程竞争 | 回调在 main actor；UI 动画、图表、格式化都在抢同一线程 | 录制期间不画图、不统计、不格式化，只留 2 Hz 大字 HUD |
| 合盖即断档 | 合到接近 0° iOS 会锁屏，那段采不到 | 显式记 `phase` 行 + `gap>` 统计标记断点，不填补 |

## 3. 仪器设计（已实现）

- 录制器是 `HingeRecorder.shared` 单例，订阅挂在**根视图**（`HingeRecordingHost` 加在 `iPhoneDuoByExamplesApp` 的
  `CatalogView()` 上），不是示例页 —— 翻页、切示例、进别的示例都不丢数据。
- `isEnabled` 恒为 `true`；没在录制时回调仍会更新 HUD 读数，只是不入库。
- 回调里只做三件事：读角度、取 `mach_continuous_time`、把 `HingeRawRow` 追加进数组。
  **不格式化、不判断、不动画、不触发 `@Observable` 状态变更。**
  HUD 上那几个会高频变化的读数（当前角度、样本数、上一帧 Δt）故意标了 `@ObservationIgnored`，
  只由 2 Hz 的 `TimelineView` 重绘 —— 否则每来一次回调就失效一次视图，等于用主线程跟被测对象抢时间。
- 落盘：内存里累积，**每秒 flush 一次** `FileHandle` 追加，不 fsync。
  进程被杀最多丢最后 1 秒，而不是整场录制。

### CSV 列（10 列，纯原始量，派生量一律离线算）

```
seq,event,mono_ns,epoch_s,angle_deg,angle_rad,status,w_pt,h_pt,note
```

| 列 | 说明 |
|---|---|
| `seq` | 会话内自增序号，用于发现丢行 |
| `event` | `hinge` / `geom` / `phase` / `mark` |
| `mono_ns` | `mach_continuous_time` 换算成纳秒，单调、**含休眠时间** |
| `epoch_s` | Unix 时间戳（`Double`，保留 6 位小数，不经过 `DateFormatter`） |
| `angle_deg` | 全精度，保留 3 位小数，**不取整** |
| `angle_rad` | 同上，保留 4 位，方便和 UIKit 侧（UIKit 给弧度）交叉核对 |
| `status` | `closed` / `partiallyOpen` / `fullyOpen` / `unknown` |
| `w_pt` `h_pt` | 仅 `geom` 行有值：窗口尺寸，即**切屏重排的直接证据** |
| `note` | `mark` 行的标注；`phase` 行填 `foreground` / `background`；会话首行 `start`、末行 `stop` |

> 为什么 `geom` 比角度更重要：你真正要对齐的是「角度 ↔ 布局切换」。
> 窗口尺寸变化就是系统实际重排的时刻，它和 `hinge` 行在同一个时钟上，才能算出切屏区间。
> `geom` 行**自己不携带角度**（不复制上一个角度，避免误读），区间要拿前后两条 `hinge` 夹。

## 4. 测试协议（产出知识的部分）

| 协议 | 操作 | 能回答 |
|---|---|---|
| **P1 静止** | 停在 90° 不动 10 秒 | 回调是周期性还是变化驱动。若 10 秒 0 条 → 变化驱动 |
| **P2 慢扫** | 0°→180° 匀速开约 5 秒，重复 3 次 | 角度分辨率（Δangle 最小非零值）、间隔分布 |
| **P3 快扫** | 0.5 秒内快速开合，重复 3 次 | 是否丢帧、最大单步跳变、假回弹 |

**P1 的结论最值钱**：如果确认是变化驱动，那么任何「固定采样率」的 display 时序假设在 iOS 上都不成立。
App 内「What to capture」一节把这三条写在界面上，照着做三遍即可。

## 5. 数据存在哪（手机上）

App 沙盒内：

```
<App 沙盒>/Documents/Exports/
├── hinge-20261103-141005.csv    # 原始数据，一行一个事件
└── hinge-20261103-141005.txt    # 人类可读摘要 + 同样的数据（制表符对齐）
```

沙盒真实路径形如 `/var/mobile/Containers/Data/Application/<UUID>/Documents/Exports/`。

Info.plist 已打开（构建后实测确认，见 README §6）：

- `UIFileSharingEnabled = YES`
- `LSSupportsOpeningDocumentsInPlace = YES`

「文件」App → 我的 iPhone → Duo by Examples 里就能看到这些文件，也可以长按分享。

> 踩坑记录：`INFOPLIST_KEY_UIFileSharingEnabled` 写在工程里**不会**被 Xcode 的 plist 生成器采纳
> （实测 31 个键里没有它，而同批的 `LSSupportsOpeningDocumentsInPlace` 正常写入）。
> 所以本仓库额外带了一份最小 `Info.plist`（只放这一个键），通过 `INFOPLIST_FILE` 与自动生成的键合并。

**保留历史**：录制结束不删旧文件，App 内「Exports」列表列出最近 20 条，每条都能再次分享。

## 6. 怎么导出到电脑

### 6.1 首选：分享面板（「直接走分享，发到别的应用」）

App 里「Exports」列表每一行一个 **Share CSV + TXT** 按钮，一次把两个文件交给系统分享面板
（`UIActivityViewController`，`activityItems` 传**文件 URL** 而不是字符串 —— 传 URL 才能保留文件名和扩展名，
微信/邮件收到的才是可打开的附件）。

| 去向 | 到电脑的方式 | 适用 |
|---|---|---|
| **微信「文件传输助手」** | PC 微信另存 | 最快，推荐 |
| **邮件** | 收件箱下载附件 | 稳定，适合归档 |
| **存储到「文件」→ iCloud Drive** | 电脑浏览器登录 `icloud.com` 下载 | 不需要装 iCloud 客户端 |
| AirDrop | 需要有 Mac | 有 Mac 时最顺 |

> CSV 与 TXT 都写成 **UTF-8 with BOM**。不加 BOM 时 Windows 版 Excel / 记事本双击打开中文是乱码 ——
> 这是导出最常见的坑。

### 6.2 备用：文件 App 里手动拷

「文件」App → 我的 iPhone → Duo by Examples → `Exports/` → 长按 → 共享/拷贝。

### 6.3 不推荐：Apple Devices / iTunes 文件共享

需要额外安装 Apple Devices（Microsoft Store），而且本机 iTunes 装不上（MSI 权限问题，详见 README §2 末尾的说明）。

## 7. 导出后怎么算（离线，Python 一行）

```python
import pandas as pd
df = pd.read_csv("hinge-20261103-141005.csv", comment=None)
h = df[df.event == "hinge"].copy()
h["t_ms"] = (h.mono_ns - h.mono_ns.iloc[0]) / 1e6
h["dt_ms"] = h.t_ms.diff()
h["d_deg"] = h.angle_deg.diff()
h["deg_per_s"] = h.d_deg / h.dt_ms * 1000

print(h.dt_ms.describe(percentiles=[.5, .95, .99]))   # 投递稳定性
print(h.d_deg.abs().replace(0, pd.NA).dropna().min()) # 角度分辨率
g = df[df.event == "geom"]
print(g[["t_ms", "w_pt", "h_pt"]])                    # 切屏时刻
```

- `dt = Δmono_ns`；`delta = Δangle`；`velocity = delta / dt`
- 切屏区间：取 `geom` 行前后各一条 `hinge` → `angle_before / angle_after / bracket_width`
  （TXT 已经把这一段算好并写成 `angle 79.5° -> 76.2°  (bracket 3.3°)`）
- 采样质量：`dt` 的 min / median / p95 / max
- 断档：`dt > 200ms` 的行全部标出（TXT 里有 `# gaps >200ms` 段），与 `phase` 行对照区分「锁屏」还是「丢帧」

## 8. 不确定性（写进报告，不藏）

- 切屏角度误差上界 = 该时刻前一条 `dt`
- 合盖尾段必有断档，显式标记，不插值
- 结论只对当前这台 Duo、当前朝向成立，不外推
- 会话上限 **50 000 行**，到顶会自动停止并记一条 `stop: row limit`，不会静默丢最旧的样本

## 9. 实施清单（已完成）

| 项 | 说明 |
|---|---|
| `Examples/HingeRecorderExample.swift` | 新增：`HingeRecorder` + HUD + 导出 + `HingeRecordingHost` + `ActivityView` |
| `Catalog/Example.swift` | 新增 `hingeRecorder` case（7 处 switch 全部补齐） |
| `App/iPhoneDuoByExamplesApp.swift` | 根视图挂 `HingeRecordingHost()`，录制跨页面存活 |
| `Catalog/ExampleScreen.swift` | `Repository.url` 改指本仓库，并补 `vendor/` 前缀，否则 View Source 404 |
| `vendor/.../Info.plist` | 新增最小 plist，`INFOPLIST_FILE` 合并，补 `UIFileSharingEnabled` |
| `project.xcproj` | 登记新源文件 + 新 plist |
