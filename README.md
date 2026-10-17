# NetMark

修改 iOS 状态栏中 4G / 5G 网络标识的越狱插件（Theos + Logos）。

- 名称：**NetMark**
- 标识符：**`com.netmark.logo`**
- 本分支为 5.0 重构版：**只保留 4G 与 5G**，新增 `4Gᴀ` / `5Gᴀ` 显示，并重做了设置界面。

> 由 [Data Logo Switcher](https://github.com/hirakujira/DataLogoSwitcher) 重构而来，MIT 协议与原作者署名保留。

## 更新记录

**5.0.3** — 修复「选了没变化」。

5.0.2 把替换逻辑全放在字符串层（`_stringForCellularType:` / `-setText:`），实测在 iOS 17 上
这条路径不生效；而上游原版靠改写 `modemDataConnectionType` 让系统自己渲染，是验证过可用的。
本版恢复**双保险**：

1. **枚举层**（`STTelephonySubscriptionContext -modemDataConnectionType`）：按选择把制式
   改写成对应枚举（`4Gᴀ`→LTE-A、`4G+`→LTE+、`5G+`/`5G UWB`/`5G UC`→对应值），系统自己渲染。
   这条即使字符串层失效也能看到变化。
2. **字符串层**：把系统渲染出的原生标识替换成 `4Gᴀ` / `5Gᴀ` / 自定义等枚举表达不了的精确文本。
   两层叠加，最终显示以字符串层为准。
3. **偏好双路径**：同时写 `/var/mobile/...` 与 `ROOT_PATH_NS` 前缀路径，读取时取 mtime 最新的那份。
   rootless / roothide 下两个进程对 `/var/mobile` 的可见性可能不同，双写双读兜住这种情况。
4. 设置页底部在写入失败时会显示「⚠️ 设置写入失败」，不再静默。

**5.0.2** — 修复「设置后状态栏没变化」。

1. 替换依据从 `modemDataConnectionType` 枚举值改为**系统原生标识文本**。原实现把 6/7/8/9 当 4G、
   11–14 当 5G，一旦 iOS 调整枚举顺序就整条失效；现在只认系统渲染出来的 `LTE` / `5G` 等字符串，
   与枚举完全解耦。
2. 增加第二层兜底：除了 `_stringForCellularType:`，还在 `_UIStatusBarStringView -setText:` 里
   再替换一次。哪一层先命中都能生效，替换后的文本不是原生标识，两层不会互相叠加。
3. 注销按钮改为从**自身 bundle 位置反推越狱根目录**（`.../Library/PreferenceBundles/NetMark.bundle`
   往上三层），rootless 得到 `/var/jb`、roothide 得到 `.jbroot-XXXX`、rootful 得到 `/`。
   原先依赖 `ROOT_PATH_NS`，在 roothide 下拿不到正确路径，点了等于没点。找不到 `sbreload` /
   `killall` 时会弹窗提示，不再静默失败。
4. 移除 `4G` / `LTE` / `5G` 三个选项（等同系统默认或已被 `4Gᴀ` / `4G+` / `5G+` 覆盖）。
   旧数据里选过这三项会自动回落到「默认」。

**5.0.1** — 修复进入设置页闪退。`PSListController` 在 `controllerForSpecifier:` 中会直接给
detail 控制器发 `setSpecifier:` / `setRootController:` / `setParentController:`，
设置页原先继承 `UIViewController`，收到未知 selector 触发 `unrecognized selector` → `SIGABRT`。
现改为继承 `PSViewController`，并链接 Preferences 私有框架。

**5.0.0** — 重构：只保留 4G / 5G，新增 `4Gᴀ` / `5Gᴀ`，重做设置界面，改名 NetMark。

## 功能

| 分组 | 可选标识 |
| --- | --- |
| 4G / LTE | 默认、**4Gᴀ**、4G+、自定义 |
| 5G | 默认、5G+、**5Gᴀ**、5G UWB、5G UC、自定义 |

- **固定显示**：选项直接决定状态栏文本，不再依赖系统对连接类型的枚举渲染。
- **自定义**：选择「自定义」后输入任意文本（上限 6 个字符），留空则回落到系统默认。
- **跟随系统**：选「默认」时完全交给 iOS 与运营商配置，插件不做任何干预。
- **同字号**：`4Gᴀ`、`5Gᴀ` 与自定义文本都按状态栏原生标识的字号渲染，不会被系统压小。
- 只接管 4G / 5G 两种制式，3G、2G、Wi-Fi 一律不干预。

## 实现方式

在状态栏文本层替换显示字符串：

```objc
%hook _UIStatusBarCellularItem
- (NSString *)_stringForCellularType:(int)connectionType { ... }
%end
```

同时接管 `_UIStatusBarCellularCondensedItem`，保证刘海屏 / 灵动岛的紧凑布局显示一致。

**不再改写 `modemDataConnectionType`**，因此不会伪造真实网络状态，也不影响系统对网络类型的其它判断。

### 字号对齐

`_UIStatusBarStringView` 在文本变宽时会自动缩小字号，导致自定义文本比原生标识小一圈。
插件在 `setText:` 之后：

1. 记录系统渲染原生标识时使用的字号（首次见到非本插件文本时采样）；
2. 对 `4Gᴀ` / `5Gᴀ` / 自定义文本强制使用同一字号；
3. 关闭 `adjustsFontSizeToFitWidth`，避免长文本被再次压小。

## 界面

设置页是一个原生 `UITableViewStyleInsetGrouped` 列表，外观与系统设置页一致，没有任何自绘视图：

- 两个分组（`4G / LTE`、`5G`），组内逐项列出可选标识，右侧对勾表示当前选择
- 选中「自定义」时在组内追加一行输入框，自动聚焦
- 分组底部说明实时反映当前标识（如「4G / LTE 网络下显示「4Gᴀ」。」）
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
