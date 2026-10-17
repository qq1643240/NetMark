# NetMark

修改 iOS 状态栏中 4G / 5G 网络标识的越狱插件（Theos + Logos）。

- 名称：**NetMark**
- 标识符：**`com.netmark.logo`**
- 当前版本 **6.0.3**：只保留 4G 与 5G，支持 `4Gᴀ` / `4G+` / `5Gᴀ` / `5G+` / `5G UWB` / `5G UC` 与自定义文本

> 由 [Data Logo Switcher](https://github.com/hirakujira/DataLogoSwitcher) 重构而来，MIT 协议与原作者署名保留。

## 更新记录

**6.0.3** — 控制中心 / 通知中心改为两段式渲染，与状态栏观感一致；图标放大并重做为纯黑底白字 `5G`

**6.0.2** — 修复控制中心 / 通知中心显示原生 `5G+` 而非 `5Gᴀ`（补 `UILabel` 兜底，并排除已拆段的 `NetworkTypeView`）

**6.0.1** — 图标尺寸改为 29/58pt、去掉「当前状态」分组、界面只保留 4G / 5G

**6.0.0** — 稳定版

- `4Gᴀ` / `4G+` / `5Gᴀ` / 自定义 与原生标识渲染完全一致
- 移除全部诊断日志与诊断分组，修复状态栏刷新卡顿
- 偏好读取加 1 秒缓存，减少状态栏刷新时的磁盘访问
- 新图标

**5.0.x** — 逐层定位渲染问题：从枚举改写 → 字符串层 → `setOriginalText:` → `typeStringProvider`
→ 最终确认入口是 `STUIStatusBarCellularNetworkTypeView`，细节见下方「渲染实现」。

**5.0.1** — 修复进入设置页闪退：`PSListController` 会给 detail 控制器发 `setSpecifier:` 等
`PSViewController` 接口，设置页改为继承 `PSViewController`。

**5.0.0** — 重构：只保留 4G / 5G，新增 `4Gᴀ` / `5Gᴀ`，重做设置界面，改名 NetMark。

## 功能

| 分组 | 可选标识 |
| --- | --- |
| 4G | 默认、**4Gᴀ**、4G+、自定义 |
| 5G | 默认、5G+、**5Gᴀ**、5G UWB、5G UC、自定义 |

- **固定显示**：选项直接决定状态栏文本，不再依赖系统对连接类型的枚举渲染。
- **自定义**：选择「自定义」后输入任意文本（上限 6 个字符），留空则回落到系统默认。
- **跟随系统**：选「默认」时完全交给 iOS 与运营商配置，插件不做任何干预。
- **同字号**：`4Gᴀ`、`5Gᴀ` 与自定义文本都按状态栏原生标识的字号渲染，不会被系统压小。
- 只接管 4G / 5G 两种制式，3G、2G、Wi-Fi 一律不干预。

## 渲染实现（iOS 17）

状态栏标识不是普通文本，它由三层共同决定。改任何一层都不够，必须三层对齐：

| 层 | 位置 | 作用 |
| --- | --- | --- |
| 制式枚举 | `STTelephonySubscriptionContext -modemDataConnectionType` | 决定用哪套样式属性与槽位宽度 |
| 运营商开关 | `STTelephonyCarrierBundleInfo -LTEConnectionShows4G` | 为 YES 时把 LTE / LTE-A / LTE+ 全塌缩成 `4G` |
| 文本渲染 | `STUIStatusBarCellularNetworkTypeView -setText:prefixLength:withStyleAttributes:forType:animated:` | 把标识拆成 `prefixLabel` + `accessoryLabel` 两段分别渲染 |

关键点：

1. **字体由枚举决定**。`type 11(5G)` → `.SFUI-Medium`（常规宽度）；`type 12(5G+)` →
   `.SFUI-SemiCondensedMedium`（半压缩），槽位也更宽。所以 `5Gᴀ` 借用 `5G+` 的枚举，
   才能拿到同款字形与足够宽度。
2. **`prefixLength` 决定拆分位置**。`2` 表示 `5G` + 后缀（后缀走小字号），
   `NSNotFound` 表示整串不拆。要和 `5G+` 一致就传 `2`。
3. **4G 不要改枚举**。实测 `type 9(LTE+)` 在部分运营商配置下不可渲染，状态栏会显示 `?`。
   4G 靠 `LTEConnectionShows4G = NO` 让系统渲染标准 `LTE`，再替换文本。
4. **`UILabel` 兜底必须排除 `NetworkTypeView`**。控制中心 / 通知中心的运营商行不走
   `NetworkTypeView`，只靠上面两层拿不到替换文本，会原样显示枚举对应的原生字样
   （借了 `5G+` 的枚举就显示 `5G+`）。所以补一层 `UILabel` 兜底，但要把
   `STUIStatusBarCellularNetworkTypeView` 内部的标签排除掉，否则会揉乱已经拆好的两段结构。
5. **两段式要自己拼**。`NetworkTypeView` 有 `prefixLabel` + `accessoryLabel` 这套结构，
   控制中心的普通 `UILabel` 没有。兜底时用 `NMTwoPartLabel()` 生成富文本：
   前缀保持原字号，后缀缩到 `0.78` 倍并对齐基线，两处观感才一致。

## 界面

设置页是一个原生 `UITableViewStyleInsetGrouped` 列表，外观与系统设置页一致，没有任何自绘视图：

- 两个分组（`4G`、`5G`），组内逐项列出可选标识，右侧对勾表示当前选择
- 选中「自定义」时在组内追加一行输入框，自动聚焦
- 分组底部说明实时反映当前标识（如「4G 网络下显示「4Gᴀ」。」）
- 独立分组的居中文字按钮「保存并注销」
- 深浅色、动态字体、iPad 分栏宽度、安全区全部由系统列表负责

## 编译

需要 **roothide/theos**（上游 theos 不含 roothide 打包方案，该分支兼容 rootful / rootless / roothide）
与 iOS SDK 14.5：

```sh
make package THEOS_PACKAGE_SCHEME=rootless FINALPACKAGE=1   # 无根
make package THEOS_PACKAGE_SCHEME=roothide FINALPACKAGE=1   # 隐根
make package FINALPACKAGE=1                                 # 有根（旧设备）
```

产物位于 `packages/`。部署目标 iOS 13.0，架构 arm64 / arm64e。

若本机 SDK 版本不同，改 `Makefile` 里的 `TARGET = iphone:clang:14.5:13.0`。

## 云端编译

仓库自带 GitHub Actions 工作流（`.github/workflows/build.yml`），在 macOS 上自动装
roothide/theos 与 iPhoneOS14.5 SDK，用 matrix 并行产出两种包：

| scheme | 产物 | 适用越狱 |
| --- | --- | --- |
| `rootless` | `com.netmark.logo_5.0.0_iphoneos-arm64.deb` | 无根（Dopamine / palera1n rootless），装到 `/var/jb` |
| `roothide` | `com.netmark.logo_5.0.0_iphoneos-arm64e.deb` | 隐根（roothide Bootstrap），路径由 `jbroot()` 运行时解析 |

- 触发条件：推送到 `master` / `main`、PR、或手动 `Run workflow`
- 产物：Actions 运行页底部的 `NetMark-rootless` / `NetMark-roothide` 两个 artifact
- 本地不需要任何 iOS 开发环境

### 两种越狱的差异

- **无根（rootless）**：编译期把 `/var/jb` 写进包路径，二进制链接 `libroot`。
- **隐根（roothide）**：`THEOS_PACKAGE_SCHEME=roothide` 时 `ROOT_PATH_NS` 被重定义为
  `jbroot()`，路径在运行时解析，因此同一个 `jbroot` 位置不同的设备都能用；
  包内文件路径不带 `/var/jb` 前缀。
- 本插件的设置数据写在 `/var/mobile/Library/Preferences/`，属于用户数据，两种越狱下位置一致。

## 设置存储

`/var/mobile/Library/Preferences/com.netmark.logo.plist`

| 键 | 含义 |
| --- | --- |
| `4G` | 4G 选项索引（0 默认 / 1..4 固定 / 99 自定义） |
| `5G` | 5G 选项索引（0 默认 / 1..5 固定 / 99 自定义） |
| `custom4GString` / `custom5GString` | 自定义文本 |
| `schemaVersion` | 数据结构版本（当前 2，用于旧数据迁移） |

首次打开设置页会自动迁移旧数据：删除 `3G` / `custom3GString`，并把已移除的跨制式选项回落为「默认」。

从旧版 `Data Logo Switcher`（`tw.hiraku.datalogoswitcher`）升级时，会自动读取
`tw.hiraku.datalogoswitcher.plist`（含 rootless 误写路径）并写入新域，无需重新设置。

## 从 4.x 移除的内容

- 3G 分组、3G 自定义文本、3G → 4G/5G 的转换逻辑
- 4G 分组里的 5GE / 5G / 5G+ / 5G UWB / 5G UC 跨制式伪装选项
- 5GE 标识（本质是 LTE-A Pro，属于 4G 营销名称）
- `modemDataConnectionType` 枚举改写与 `LTEConnectionShows4G` 强制关闭
- iOS 7–12 的 `SBTelephonyManager` / `Connection*` 旧枚举分支与 armv7 架构
- PSSpecifier 列表式界面

## 无效代码清理

| 项目 | 说明 |
| --- | --- |
| `NMChoiceGridView` | 自绘标签网格，改用系统列表勾选后不再需要 |
| `NMPreviewView` | `drawRect:` 手绘状态栏预览，改由分组底部说明文字承担 |
| `custom4GCell` / `custom5GCell` | 缓存单元格实例，改为按需重建，避免复用冲突 |
| `NMBundleIdentifier` | 宏定义但从未引用 |
| `NMLogoDefault` / `NMLogoCustom` | 通用枚举，实际用的是分组内枚举 |
| `NMConnection*` 6 个枚举值 | None / 1x / GPRS / Edge / UMTS / HSDPA / Bluetooth 均无引用 |
| `NetMarkSettings/entry.plist` | 与 `layout/.../NetMark.plist` 重复且不会被安装 |
| `theos`、`NetMarkSettings/theos` | 旧版独立编译用的路径文件，Makefile 已改用 `$(THEOS)` |

## License

MIT. Please kindly keep the credit of contributors.
