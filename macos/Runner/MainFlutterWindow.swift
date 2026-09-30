import Cocoa
import FlutterMacOS
import MediaPlayer

// applicationShouldTerminate 与 Dart 侧的握手状态（仅在主线程访问）
var gTerminateReplySent = false
var gAppMethodChannel: FlutterMethodChannel?

func replyTerminateNow() {
  if gTerminateReplySent { return }
  gTerminateReplySent = true
  NSApp.reply(toApplicationShouldTerminate: true)
}

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    setupNativeChannel(flutterViewController)

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }

  /// 沙盒安全作用域书签 + 优雅退出 + 系统媒体控制，配合 lib/services/native_bridge.dart
  private func setupNativeChannel(_ controller: FlutterViewController) {
    let channel = FlutterMethodChannel(
      name: "app/native",
      binaryMessenger: controller.engine.binaryMessenger)
    gAppMethodChannel = channel
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "isSandboxed":
        // 沙盒内运行时系统会注入 APP_SANDBOX_CONTAINER_ID 环境变量
        result(ProcessInfo.processInfo.environment.keys.contains("APP_SANDBOX_CONTAINER_ID"))
      case "createBookmark":
        guard let args = call.arguments as? [String: Any],
              let path = args["path"] as? String else {
          result(FlutterError(code: "invalid_args", message: nil, details: nil))
          return
        }
        result(Self.createSecurityScopedBookmark(path: path))
      case "resolveBookmark":
        guard let args = call.arguments as? [String: Any],
              let bookmark = args["bookmark"] as? String else {
          result(FlutterError(code: "invalid_args", message: nil, details: nil))
          return
        }
        result(Self.resolveSecurityScopedBookmark(bookmark))
      case "stopAccess":
        guard let args = call.arguments as? [String: Any],
              let path = args["path"] as? String else {
          result(FlutterError(code: "invalid_args", message: nil, details: nil))
          return
        }
        Self.stopSecurityScopedAccess(path)
        result(nil)
      case "nowPlayingUpdate":
        if let args = call.arguments as? [String: Any] {
          Self.updateNowPlaying(args)
        }
        result(nil)
      case "nowPlayingClear":
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        result(nil)
      case "terminateNow":
        replyTerminateNow()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    Self.setupRemoteCommands(channel: channel)
  }

  // MARK: - Now Playing（系统媒体控制）

  private static func updateNowPlaying(_ args: [String: Any]) {
    var info: [String: Any] = [:]
    if let title = args["title"] as? String, !title.isEmpty {
      info[MPMediaItemPropertyTitle] = title
    }
    if let duration = (args["durationMs"] as? NSNumber)?.doubleValue {
      info[MPMediaItemPropertyPlaybackDuration] = duration / 1000.0
    }
    if let position = (args["positionMs"] as? NSNumber)?.doubleValue {
      // 该键在部分 SDK 的 Swift 接口中不可见；其 API 字符串值恒为同名常量
      info["MPNowPlayingInfoPropertyElapsedTime"] = position / 1000.0
    }
    info[MPNowPlayingInfoPropertyPlaybackRate] = (args["rate"] as? NSNumber)?.doubleValue ?? 0.0
    MPNowPlayingInfoCenter.default().nowPlayingInfo = info
  }

  private static func setupRemoteCommands(channel: FlutterMethodChannel) {
    let commandCenter = MPRemoteCommandCenter.shared()
    commandCenter.playCommand.addTarget { _ in
      channel.invokeMethod("remoteCommand", arguments: ["action": "play"])
      return .success
    }
    commandCenter.pauseCommand.addTarget { _ in
      channel.invokeMethod("remoteCommand", arguments: ["action": "pause"])
      return .success
    }
    commandCenter.togglePlayPauseCommand.addTarget { _ in
      channel.invokeMethod("remoteCommand", arguments: ["action": "toggle"])
      return .success
    }
    commandCenter.nextTrackCommand.addTarget { _ in
      channel.invokeMethod("remoteCommand", arguments: ["action": "nextTrack"])
      return .success
    }
    commandCenter.previousTrackCommand.addTarget { _ in
      channel.invokeMethod("remoteCommand", arguments: ["action": "previousTrack"])
      return .success
    }
    commandCenter.changePlaybackPositionCommand.addTarget { event in
      if let positionEvent = event as? MPChangePlaybackPositionCommandEvent {
        channel.invokeMethod(
          "remoteCommand",
          arguments: [
            "action": "seek",
            "positionMs": Int(positionEvent.positionTime * 1000),
          ])
        return .success
      }
      return .commandFailed
    }
  }

  // MARK: - 沙盒安全作用域书签

  private static var accessedPaths: Set<String> = []

  private static func createSecurityScopedBookmark(path: String) -> String? {
    let url = URL(fileURLWithPath: path, isDirectory: false)
    do {
      let data = try url.bookmarkData(
        options: .withSecurityScope,
        includingResourceValuesForKeys: nil,
        relativeTo: nil)
      return data.base64EncodedString()
    } catch {
      return nil
    }
  }

  /// 解析书签并开始访问；返回可用于播放的路径，用完需 stopSecurityScopedAccess。
  private static func resolveSecurityScopedBookmark(_ base64: String) -> String? {
    guard let data = Data(base64Encoded: base64) else { return nil }
    var isStale = false
    do {
      let url = try URL(resolvingBookmarkData: data,
                        options: .withSecurityScope,
                        relativeTo: nil,
                        bookmarkDataIsStale: &isStale)
      guard url.startAccessingSecurityScopedResource() else { return nil }
      accessedPaths.insert(url.path)
      return url.path
    } catch {
      return nil
    }
  }

  private static func stopSecurityScopedAccess(_ path: String) {
    guard accessedPaths.remove(path) != nil else { return }
    URL(fileURLWithPath: path, isDirectory: false)
      .stopAccessingSecurityScopedResource()
  }
}
