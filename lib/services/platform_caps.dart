import 'dart:io';

import 'package:flutter/foundation.dart';

/// 平台能力判断的统一出口。
class PlatformCaps {
  static bool get isDesktop =>
      !kIsWeb && (Platform.isMacOS || Platform.isWindows || Platform.isLinux);

  static bool get isMobile =>
      !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  static bool get isMacOS => !kIsWeb && Platform.isMacOS;
}
