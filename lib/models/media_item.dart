/// 一条媒体记录：本地文件或网络流，及其播放进度。
class MediaItem {
  MediaItem({
    required this.path,
    required this.title,
    this.lastPositionMs = 0,
    this.durationMs = 0,
    this.bookmark,
    DateTime? lastPlayedAt,
  }) : lastPlayedAt = lastPlayedAt ?? DateTime.now();

  final String path;
  final String title;
  int lastPositionMs;
  int durationMs;

  /// macOS 沙盒安全作用域书签（base64），重启后凭它恢复文件访问权。
  String? bookmark;
  DateTime lastPlayedAt;

  /// 视为网络流的 URL 协议（http 直链 / HLS / RTSP / RTMP 直播流等）
  static const networkSchemes = {
    'http', 'https', 'rtsp', 'rtmps', 'rtmp', 'srt', 'ftp', 'mms',
  };

  /// 视为视频文件的扩展名（文件夹扫描 / 拖拽 / 文件关联共用）
  static const videoExtensions = {
    'mp4', 'm4v', 'mkv', 'avi', 'mov', 'flv', 'wmv', 'webm', 'ts', 'm2ts',
    'mts', 'mpg', 'mpeg', '3gp', 'ogv', 'rmvb', 'rm', 'vob', 'asf', 'divx',
    'f4v',
  };

  static bool isNetworkPath(String path) {
    final scheme = Uri.tryParse(path)?.scheme.toLowerCase();
    return scheme != null && networkSchemes.contains(scheme);
  }

  static bool isVideoFile(String path) {
    final clean = path.split('?').first;
    final dot = clean.lastIndexOf('.');
    if (dot < 0 || dot == clean.length - 1) return false;
    return videoExtensions.contains(clean.substring(dot + 1).toLowerCase());
  }

  /// 从路径/URL 提取展示标题；以 / 结尾的 URL 回退用主机名。
  static String titleOf(String path) {
    final clean = path.split('?').first.replaceAll('\\', '/');
    final name = clean.split('/').last;
    final dot = name.lastIndexOf('.');
    if (dot > 0) return name.substring(0, dot);
    if (name.isNotEmpty) return name;
    final withoutScheme =
        path.replaceFirst(RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://'), '');
    return withoutScheme.split('/').first;
  }

  bool get isNetwork => isNetworkPath(path);

  /// 观看进度 0.0 - 1.0；时长未知时返回 0。
  double get progress =>
      durationMs > 0 ? (lastPositionMs / durationMs).clamp(0.0, 1.0) : 0.0;

  bool get isFinished => durationMs > 0 && progress >= 0.98;

  static String formatMs(int ms) {
    final d = Duration(milliseconds: ms);
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  Map<String, dynamic> toJson() => {
        'path': path,
        'title': title,
        'lastPositionMs': lastPositionMs,
        'durationMs': durationMs,
        if (bookmark != null) 'bookmark': bookmark,
        'lastPlayedAt': lastPlayedAt.toIso8601String(),
      };

  factory MediaItem.fromJson(Map<String, dynamic> json) => MediaItem(
        path: json['path'] as String,
        title: (json['title'] as String?) ?? (json['path'] as String? ?? ''),
        lastPositionMs: (json['lastPositionMs'] as num?)?.toInt() ?? 0,
        durationMs: (json['durationMs'] as num?)?.toInt() ?? 0,
        bookmark: json['bookmark'] as String?,
        lastPlayedAt: DateTime.tryParse(json['lastPlayedAt'] as String? ?? ''),
      );
}
