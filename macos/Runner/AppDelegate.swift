import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  /// 文件关联：双击视频文件 / Finder"打开方式"时收到文件路径，转发给 Dart
  override func application(_ sender: NSApplication, openFile filename: String) -> Bool {
    gAppMethodChannel?.invokeMethod("openFile", arguments: filename)
    return true
  }

  /// 关窗即退出进程；先挂起终止，让 Dart 释放 libmpv（否则 mpv 核心线程会在
  /// 进程退出时访问已回收的客户端句柄导致 SIGSEGV），Dart 完成后调用
  /// terminateNow 放行，3 秒兜底防止卡在退出流程。
  override func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard let channel = gAppMethodChannel else {
      return .terminateNow
    }
    gTerminateReplySent = false
    channel.invokeMethod("appWillTerminate", arguments: nil, result: nil)
    DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
      replyTerminateNow()
    }
    return .terminateLater
  }
}
