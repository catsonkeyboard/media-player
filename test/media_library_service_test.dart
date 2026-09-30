import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_player/services/media_library_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    MediaLibraryService.instance.reset();
    tempDir = await Directory.systemTemp.createTemp('media_lib_test');
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  test('scan 收集视频文件并自然排序，忽略非视频', () async {
    File('${tempDir.path}/EP10.mp4').writeAsStringSync('x');
    File('${tempDir.path}/EP02.mp4').writeAsStringSync('x');
    File('${tempDir.path}/EP01.mkv').writeAsStringSync('x');
    File('${tempDir.path}/cover.jpg').writeAsStringSync('x');
    final sub = Directory('${tempDir.path}/subs');
    sub.createSync();
    File('${sub.path}/EP02.chs.srt').writeAsStringSync('x');

    final library = MediaLibraryService.instance;
    await library.addFolder(tempDir.path);

    expect(library.scanning, isFalse);
    expect(library.videos, [
      '${tempDir.path}/EP01.mkv',
      '${tempDir.path}/EP02.mp4',
      '${tempDir.path}/EP10.mp4',
    ]);
    expect(library.folders, [tempDir.path]);
  });

  test('removeFolder 后扫描结果清空', () async {
    File('${tempDir.path}/a.mp4').writeAsStringSync('x');
    final library = MediaLibraryService.instance;
    await library.addFolder(tempDir.path);
    expect(library.videos, hasLength(1));

    await library.removeFolder(tempDir.path);
    expect(library.videos, isEmpty);
    expect(library.folders, isEmpty);
  });
}
