# 视频播放器技术方案

> **结论先行**：采用 **Flutter（UI 单代码库）+ media_kit / libmpv（播放内核）**。
> 一套 Dart 代码覆盖 Windows、macOS、Android、iOS 四端；libmpv 内置 FFmpeg
> 全格式解封装/解码能力，直接满足"兼容市面主流视频格式"的核心诉求。

## 1. 需求与约束

| 维度 | 要求 |
| --- | --- |
| 平台 | Windows、macOS、Android、iOS |
| 界面 | 简约：单列表媒体库 + 沉浸式播放页 |
| 格式 | 主流容器/编码全兼容，四端体验一致 |

"主流格式"的具体清单（本项目以此为验收口径）：

- 容器：MP4、MOV、MKV、AVI、FLV、WMV、WebM、MPEG-TS、3GP
- 视频编码：H.264/AVC、H.265/HEVC、VP8/VP9、AV1、MPEG-2、MPEG-4 Part 2
- 音频编码：AAC、MP3、AC-3/E-AC-3、DTS、FLAC、Opus、Vorbis、ALAC
- 字幕：内嵌 SRT/ASS/SSA/PGS/VobSub；外挂 SRT/ASS/SSA/VTT

## 2. 跨平台框架选型

| 方案 | 四端成熟度 | 格式兼容路径 | 体积/性能 | 维护成本 | 结论 |
| --- | --- | --- | --- | --- | --- |
| **Flutter + media_kit(libmpv)** | 高，官方支持四端 | libmpv(FFmpeg)，四端统一 | 中：AOT + 自绘引擎，播放内核增量约 30–60MB/端 | 低：单代码库 | ✅ 推荐 |
| React Native + react-native-video | 移动成熟；桌面依赖微软维护分支，二等公民 | 封装各端系统播放器，格式受限；接 mpv 需自写原生桥 | 中 | 中 | ❌ 桌面弱 |
| Tauri 2（Rust + WebView） | 桌面成熟；移动端 2.x 才落地，生态新 | WebView 原生 video 只认浏览器格式，需再集成 mpv/FFmpeg | 小 | 中高 | ❌ 移动端风险大 |
| Qt 6 / QML + libmpv | 桌面极强；移动端可用但工具链/签名繁琐 | libmpv 全格式 | 最优、包体最小 | 高：C++ 多端构建 | 备选（桌面优先、极致性能） |
| Kotlin Multiplatform + Compose | Android/桌面好，iOS 已 stable，Windows 桌面仍 beta | 无统一视频组件，仍需每端封装 | 小–中 | 中高 | 备选（Kotlin 技术栈团队） |
| 四端原生 + 共享 C++ 内核 | 体验上限最高 | 全格式 | 最优 | 最高：4 套 UI/工程 | ❌ 投入不成比例 |

> Electron 因无移动端支持，直接出局，不参与对比。

**选型逻辑**：格式兼容这个硬指标把"封装系统播放器"的路线（RN、官方
video_player）基本排除；剩下的问题变成"哪家 UI 框架 + libmpv 集成成本最低"。
Flutter 是唯一对四端都有官方一线支持、且社区已有成熟 libmpv 绑定（media_kit）
的方案，因此胜出。

## 3. 播放内核选型（决定格式兼容的关键）

| 内核 | 格式范围 | 硬解 | 字幕 | 主要问题 |
| --- | --- | --- | --- | --- |
| 系统播放器（AVPlayer / Android Media3 / Windows Media Foundation） | 各家不一：MKV、AVI、FLV、内嵌 ASS/PGS 支持差，四端行为不一致 | 全 | 有限 | 格式覆盖不足是硬伤 |
| **libmpv（mpv 播放器内核）** | 市面可见格式基本全支持 | VideoToolbox / MediaCodec / D3D11VA | SRT/ASS/SSA/PGS 全支持 | 库体积、LGPL 合规 |
| 自研 FFmpeg + 渲染管线 | 完全自定义 | 自行接入 | 自行开发 | 工作量最大，起步不建议 |

典型场景对比（系统内核 vs libmpv）：

| 输入 | AVPlayer (iOS/macOS) | Media3 (Android) | Media Foundation (Win) | libmpv |
| --- | --- | --- | --- | --- |
| MP4 / H.264 | ✔ | ✔ | ✔ | ✔ |
| MKV（HEVC + ASS 字幕） | ✖ | 部分 | 部分 | ✔ |
| AVI（MPEG-4 Part 2） | ✖ | 部分 | 部分 | ✔ |
| FLV（H.264） | ✖ | ✔ | ✖ | ✔ |
| WMV | ✖ | ✖/扩展 | ✔ | ✔ |
| AV1 | 新设备部分支持 | 需扩展 | 需扩展 | ✔（dav1d 软解） |
| 内嵌 ASS / PGS 字幕 | ✖/部分 | 部分 | ✖/部分 | ✔ |

**结论**：只有 libmpv 能做到"一套内核、四端一致"覆盖全部主流格式，
且多音轨切换、外挂字幕、倍速、损坏文件容错等能力都是现成的。

## 4. 推荐组合：Flutter + media_kit

media_kit 是 Flutter 生态事实上的 libmpv 封装标准库：

- `media_kit_libs_video` 为四端自动打包预编译 libmpv，无需手动处理原生依赖
- 硬解默认开启（`VideoControllerConfiguration.enableHardwareAcceleration`）：
  Apple 走 VideoToolbox，Android 走 MediaCodec，Windows 走 D3D11VA
- 内置 Material / Cupertino 播放控件（进度条、手势、全屏），MVP 阶段零成本
- `Player` / `Media` / `Tracks` API 覆盖：播放、seek、倍速、音轨/字幕切换、错误流

### 4.1 架构分层

```
┌──────────────────────────────────┐
│ UI 层    HomePage / PlayerPage    │ Flutter Widget
├──────────────────────────────────┤
│ 状态层   LibraryService           │ ChangeNotifier + shared_preferences
├──────────────────────────────────┤
│ 播放层   media_kit (Player)       │ Dart API
├──────────────────────────────────┤
│ 内核层   libmpv / FFmpeg          │ 各端预编译原生库
└──────────────────────────────────┘
```

### 4.2 项目结构

```
lib/
├── main.dart                       # 入口：初始化 MediaKit、暗色主题
├── models/media_item.dart          # 媒体记录（路径/标题/进度/时长）
├── services/library_service.dart   # 最近播放 + 进度持久化
└── pages/
    ├── home_page.dart              # 媒体库：文件/网络流入口、历史列表
    └── player_page.dart            # 播放页：内置控件 + 字幕/音轨/倍速
```

### 4.3 关键技术点

1. **硬解**：`VideoController` 默认开启硬件加速，解码失败时 mpv 自动回退软解。
2. **进度记忆**：播放中每 5 秒落盘一次 + 退出页面时落盘；再次进入且进度位于
   5 秒～95% 区间时自动续播。
3. **字幕**：内嵌字幕由 mpv 自动加载渲染（含 ASS 特效）；外挂字幕通过
   `SubtitleTrack.uri()` 注入，支持 srt/ass/ssa/vtt。
4. **控件**：使用 media_kit 内置 `AdaptiveVideoControls`（Android/Windows 用
   Material 风格，iOS/macOS 用 Cupertino 风格），自带全屏与移动端手势；
   顶部右侧补充外挂字幕/音轨/倍速入口。
5. **状态管理**：MVP 用 ChangeNotifier；当页面间共享状态变复杂后再迁 riverpod。

## 5. 各平台接入要点

| 平台 | 要点 | 状态 |
| --- | --- | --- |
| macOS | 开发期禁用 App Sandbox（直接分发，行为对齐 VLC）；上架时恢复 `app-sandbox`，security-scoped 书签机制自动启用 | ✅ 已配置 |
| iOS | 文件经系统选择器授权访问，无额外 Info.plist 配置 | 开箱可用 |
| Android | release 需显式声明 INTERNET 权限（模板只在 debug 注入） | ✅ 已配置 |
| Windows | libmpv DLL 由 media_kit_libs 随包自动复制 | 开箱可用 |

发布工程（后续版本）：macOS 签名+公证、Windows MSIX/安装包、
Android 分 ABI 的 AAB、iOS TestFlight → App Store。

## 6. 合规与风险

| 风险 | 说明 | 对策 |
| --- | --- | --- |
| LGPL/GPL 合规 | media_kit 预编译的 libmpv 为 LGPL 配置，允许闭源商用 | 在"关于"页附开源许可声明；不要自行替换 GPL 全量编译 |
| App Store 审核 | 含 FFmpeg 的播放器有大量上架先例，风险低 | 保留许可声明页，审核备注说明用途 |
| 包体积 | libmpv 使每端安装包增量约 30–60MB | Android 分 ABI 下发；桌面端通常可接受 |
| 4K 高码率 | 纯软解吃 CPU，低端设备可能掉帧 | 默认硬解；回退软解时 UI 提示 |
| iOS 大文件拾取 | file_picker 会把文件拷贝到临时目录，大文件首次打开偏慢 | MVP 接受；后续改安全作用域（security-scoped）直读 |
| 罕见/损坏文件 | 解封装失败 | 监听 `player.stream.error`，UI 提示而非闪退 |

## 7. 路线图

- **v0.1（本次交付）**：本地视频/网络流播放、最近播放列表、进度记忆与续播、
  内嵌字幕、外挂字幕、音轨切换、倍速、内置全屏与手势、宽高比/剪切/旋转、
  硬解/反交错/HDR 色调映射开关、10 段均衡器、
  画中画（Android 系统级 PiP；macOS/Windows 迷你置顶小窗；iOS 因 media_kit
  纹理渲染与系统 PiP 不兼容暂不支持）
- **v0.2**：文件夹扫描媒体库、播放列表、移动端手势增强（亮度/音量/长按倍速）、
  字幕样式设置
- **v0.3**：SMB / DLNA / WebDAV 网络来源、桌面窗口状态记忆、画中画
- **v1.0**：四端发布工程（签名、公证、商店页）与上架
