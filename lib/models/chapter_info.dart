import 'package:flutter/foundation.dart';

/// 一个章节（来自 mpv chapter-list 属性）。
@immutable
class ChapterInfo {
  const ChapterInfo({
    required this.index,
    required this.title,
    required this.start,
  });

  final int index;
  final String title;
  final Duration start;
}
