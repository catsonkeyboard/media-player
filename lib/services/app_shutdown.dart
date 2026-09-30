/// 进程退出前需要执行的任务注册表（落盘进度、销毁 libmpv 等）。
/// PlayerPage 在 initState 注册、dispose 注销；NativeBridge 收到
/// appWillTerminate 后依次执行。
class AppShutdown {
  static final List<Future<void> Function()> _tasks = [];

  static void register(Future<void> Function() task) => _tasks.add(task);

  static void unregister(Future<void> Function() task) => _tasks.remove(task);

  static Future<void> runAll() async {
    final tasks = List.of(_tasks);
    _tasks.clear();
    for (final task in tasks) {
      try {
        await task();
      } catch (_) {
        // 退出路径上不抛错
      }
    }
  }
}
