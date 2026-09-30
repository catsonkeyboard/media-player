# 发布检查清单（v1.0 上架工程）

正式分发前逐项确认。当前开发态为"非沙盒 macOS + 调试签名"，上架需要按下表改造。

## macOS

1. **恢复 App Sandbox**：`macos/Runner/Release.entitlements` 与 `DebugProfile.entitlements`
   加回 `com.apple.security.app-sandbox`（安全作用域书签机制会自动接管，
   见 `SecurityScoped.init()` 的运行时检测）。
2. **签名**：Apple Developer 账号 → Xcode 配置 Developer ID Application 证书；
   `flutter build macos --release` 后 `codesign --deep --options runtime`。
3. **公证**：`xcrun notarytool submit`（需要 App 专用密码或 App Store Connect API key），
   公证通过后 `xcrun stapler staple`。
4. **许可声明**：设置页/关于页附 libmpv/FFmpeg 等 LGPL 组件许可清单。
5. **版本号**：pubspec.yaml `version` 同步 Info.plist / 注册信息。

## Windows

1. **代码签名证书**：EV/OV 证书签名 exe（未签名会触发 SmartScreen 警告）。
2. **分发形态**：MSIX（`msix` pub 包可打包）或 Inno Setup 安装器；
   文件关联需安装器写注册表（`HKCR` ProgID + OpenWith list）。
3. **优雅退出**：已实现（`flutter_window.cpp` 拦截 WM_CLOSE），CI 的
   `build-windows` 任务编译验证；真机点击关闭需人工回归一次。

## Android

1. `applicationId` 从 `com.example.media_player` 改为正式包名（改一次后不可变）。
2. 签名 keystore + `key.properties`（勿提交仓库）；`flutter build appbundle --release`。
3. 分 ABI 下发可减小体积（libmpv 每 ABI 约 30–40MB）。

## iOS

1. Bundle ID / 签名团队；`flutter build ipa` → TestFlight → App Store。
2. `file_picker` 首次打开大文件会拷贝到临时目录，审核备注说明用途。

## 通用

- 关于页附开源许可声明（media_kit / libmpv / FFmpeg / file_picker / desktop_drop 等）。
- `docs/technical-design.md` 第 6 节风险表复查。
- CI（`.github/workflows/ci.yml`）四端构建通过后再打 tag 发布。
