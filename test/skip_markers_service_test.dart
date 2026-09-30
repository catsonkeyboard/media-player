import 'package:flutter_test/flutter_test.dart';
import 'package:media_player/services/skip_markers_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('set/get/clear 片头片尾标记', () async {
    final markers = SkipMarkersService.instance;
    await markers.init();

    expect(markers.introEndOf('/a/EP01.mp4'), isNull);

    await markers.setIntroEnd('/a/EP01.mp4', const Duration(seconds: 35));
    await markers.setOutroStart('/a/EP01.mp4', const Duration(minutes: 20));

    expect(markers.introEndOf('/a/EP01.mp4'), const Duration(seconds: 35));
    expect(markers.outroStartOf('/a/EP01.mp4'), const Duration(minutes: 20));

    await markers.clearIntroEnd('/a/EP01.mp4');
    expect(markers.introEndOf('/a/EP01.mp4'), isNull);
    expect(markers.outroStartOf('/a/EP01.mp4'), const Duration(minutes: 20));
  });

  test('不同文件互不影响', () async {
    final markers = SkipMarkersService.instance;
    await markers.init();

    await markers.setIntroEnd('/a/1.mp4', const Duration(seconds: 10));
    expect(markers.introEndOf('/a/2.mp4'), isNull);
  });
}
