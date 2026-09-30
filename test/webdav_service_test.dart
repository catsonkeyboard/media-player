import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_player/services/webdav_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _fixtureXml = '''<?xml version="1.0" encoding="utf-8"?>
<D:multistatus xmlns:D="DAV:">
  <D:response>
    <D:href>/dav/</D:href>
    <D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop></D:propstat>
  </D:response>
  <D:response>
    <D:href>/dav/Movies/</D:href>
    <D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop></D:propstat>
  </D:response>
  <D:response>
    <D:href>/dav/EP01.mp4</D:href>
    <D:propstat><D:prop><D:resourcetype/><D:getcontentlength>123456</D:getcontentlength></D:prop></D:propstat>
  </D:response>
  <D:response>
    <D:href>/dav/My%20Video.mkv</D:href>
    <D:propstat><D:prop><D:resourcetype/><D:getcontentlength>1</D:getcontentlength></D:prop></D:propstat>
  </D:response>
  <D:response>
    <D:href>/dav/notes.txt</D:href>
    <D:propstat><D:prop><D:resourcetype/><D:getcontentlength>9</D:getcontentlength></D:prop></D:propstat>
  </D:response>
</D:multistatus>''';

WebdavServer _server(String url) => WebdavServer(
      id: 'test',
      name: 'test',
      url: url,
      username: 'user',
      password: 'pass',
    );

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('parsePropfindResponse', () {
    test('解析目录与文件、跳过自身、目录优先、URL 解码', () {
      final entries = WebdavService.parsePropfindResponse(
        _fixtureXml,
        parentPath: '/dav/',
      );

      // 自身条目 /dav/ 被跳过；目录在前、文件按自然排序、notes.txt 被过滤条件外保留
      expect(entries.map((e) => e.name).toList(),
          ['Movies', 'EP01.mp4', 'My Video.mkv', 'notes.txt']);
      expect(entries.first.isDirectory, isTrue);
      expect(entries[1].isDirectory, isFalse);
      expect(entries[1].sizeBytes, 123456);
      expect(entries[1].isVideo, isTrue);
      expect(entries[2].path, '/dav/My Video.mkv');
      expect(entries[3].isVideo, isFalse);
    });
  });

  group('WebdavServer.urlForPath', () {
    test('构建携带凭据与端口的播放 URL', () {
      final server = _server('http://192.168.1.10:5005/dav');
      expect(server.urlForPath('/dav/My Video.mp4'),
          'http://user:pass@192.168.1.10:5005/dav/My%20Video.mp4');
    });

    test('默认端口不显式携带', () {
      final server = _server('https://nas.example.com');
      expect(server.urlForPath('/media/a.mkv'),
          'https://user:pass@nas.example.com/media/a.mkv');
    });
  });

  test('listDirectory 发送 PROPFIND + Basic 认证 + Depth:1', () async {
    final server = await HttpServer.bind('127.0.0.1', 0);
    final requests = <HttpRequest>[];
    final subscription = server.listen((request) async {
      requests.add(request);
      request.response.statusCode = 207;
      request.response.headers.contentType =
          ContentType('application', 'xml', charset: 'utf-8');
      request.response.write(_fixtureXml);
      await request.response.close();
    });

    try {
      final entries = await WebdavService.instance
          .listDirectory(_server('http://127.0.0.1:${server.port}/dav'), '/dav/');

      expect(entries, hasLength(4));
      expect(requests, hasLength(1));
      expect(requests.first.method, 'PROPFIND');
      expect(requests.first.headers.value('depth'), '1');
      expect(
        requests.first.headers.value('authorization'),
        'Basic ${base64Encode('user:pass'.codeUnits)}',
      );
    } finally {
      await subscription.cancel();
      await server.close(force: true);
    }
  });

  test('401 抛出认证失败异常', () async {
    final server = await HttpServer.bind('127.0.0.1', 0);
    final subscription = server.listen((request) async {
      request.response.statusCode = 401;
      await request.response.close();
    });

    try {
      await expectLater(
        WebdavService.instance
            .listDirectory(_server('http://127.0.0.1:${server.port}'), '/'),
        throwsA(isA<Exception>()),
      );
    } finally {
      await subscription.cancel();
      await server.close(force: true);
    }
  });
}
