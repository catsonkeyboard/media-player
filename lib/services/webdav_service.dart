import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xml/xml.dart';

import '../models/media_item.dart';
import '../utils/natural_sort.dart';

/// 一个已保存的 WebDAV 服务器。
class WebdavServer {
  WebdavServer({
    required this.id,
    required this.name,
    required this.url,
    this.username = '',
    this.password = '',
  });

  final String id;
  final String name;
  final String url;
  final String username;
  final String password;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'url': url,
        'username': username,
        'password': password,
      };

  factory WebdavServer.fromJson(Map<String, dynamic> json) => WebdavServer(
        id: json['id'] as String,
        name: (json['name'] as String?) ?? '',
        url: json['url'] as String,
        username: (json['username'] as String?) ?? '',
        password: (json['password'] as String?) ?? '',
      );

  Uri get baseUri => Uri.parse(url);

  String basicAuthHeader() {
    final raw = '$username:$password';
    return 'Basic ${base64Encode(utf8.encode(raw))}';
  }

  /// 携带凭据的播放 URL（mpv 能从 URL 的 userinfo 部分解析认证）。
  String urlForPath(String path) {
    final base = baseUri;
    return Uri(
      scheme: base.scheme.isEmpty ? 'http' : base.scheme,
      userInfo: username.isEmpty ? '' : '$username:$password',
      host: base.host,
      port: base.hasPort ? base.port : null,
      path: path,
    ).toString();
  }
}

/// PROPFIND 返回的一个目录项。
@immutable
class WebdavEntry {
  const WebdavEntry({
    required this.name,
    required this.path,
    required this.isDirectory,
    this.sizeBytes,
  });

  final String name;

  /// 以 / 开头的解码后路径。
  final String path;
  final bool isDirectory;
  final int? sizeBytes;

  bool get isVideo => !isDirectory && MediaItem.isVideoFile(name);

  String get sizeText {
    final size = sizeBytes;
    if (size == null) return '';
    if (size >= 1024 * 1024 * 1024) {
      return '${(size / 1024 / 1024 / 1024).toStringAsFixed(1)} GB';
    }
    if (size >= 1024 * 1024) {
      return '${(size / 1024 / 1024).toStringAsFixed(0)} MB';
    }
    return '${(size / 1024).toStringAsFixed(0)} KB';
  }
}

/// WebDAV 客户端 + 已保存服务器管理。
class WebdavService extends ChangeNotifier {
  WebdavService._();

  static final WebdavService instance = WebdavService._();

  static const String _serversKey = 'webdav.servers.v1';
  final HttpClient _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 10);

  List<WebdavServer> _servers = [];
  List<WebdavServer> get servers => List.unmodifiable(_servers);

  Future<void> init() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_serversKey);
      if (raw != null && raw.isNotEmpty) {
        _servers = (jsonDecode(raw) as List)
            .map((e) => WebdavServer.fromJson(Map<String, dynamic>.from(e)))
            .toList();
      }
    } catch (_) {}
    notifyListeners();
  }

  Future<void> saveServer(WebdavServer server) async {
    final index = _servers.indexWhere((s) => s.id == server.id);
    if (index >= 0) {
      _servers[index] = server;
    } else {
      _servers.add(server);
    }
    await _persist();
    notifyListeners();
  }

  Future<void> removeServer(String id) async {
    _servers.removeWhere((s) => s.id == id);
    await _persist();
    notifyListeners();
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
          _serversKey, jsonEncode(_servers.map((e) => e.toJson()).toList()));
    } catch (_) {}
  }

  /// PROPFIND 列目录（Depth:1）。[path] 为以 / 开头的解码路径。
  Future<List<WebdavEntry>> listDirectory(
    WebdavServer server,
    String path,
  ) async {
    final uri = _requestUri(server, path);
    final request = await _client.openUrl('PROPFIND', uri);
    request.headers.set(HttpHeaders.authorizationHeader,
        server.basicAuthHeader());
    request.headers.set('Depth', '1');
    request.headers.contentType =
        ContentType('application', 'xml', charset: 'utf-8');
    request.add(utf8.encode('<?xml version="1.0"?>'
        '<d:propfind xmlns:d="DAV:"><d:prop>'
        '<d:resourcetype/><d:getcontentlength/><d:displayname/>'
        '</d:prop></d:propfind>'));
    final response = await request.close();
    final body = await utf8.decodeStream(response);
    if (response.statusCode == 401) {
      throw Exception('认证失败（401），请检查用户名与密码');
    }
    if (response.statusCode != 207) {
      throw Exception('WebDAV 请求失败：HTTP ${response.statusCode}');
    }
    return parsePropfindResponse(body, parentPath: path);
  }

  Uri _requestUri(WebdavServer server, String path) {
    final base = server.baseUri;
    final basePath = base.path.endsWith('/') ? base.path : '${base.path}/';
    final encoded = path
        .split('/')
        .where((segment) => segment.isNotEmpty)
        .map(Uri.encodeComponent)
        .join('/');
    return Uri(
      scheme: base.scheme.isEmpty ? 'http' : base.scheme,
      host: base.host,
      port: base.hasPort ? base.port : null,
      path: '$basePath$encoded',
    );
  }

  /// 解析 PROPFIND 207 多状态 XML；自动跳过集合自身条目。
  static List<WebdavEntry> parsePropfindResponse(
    String xmlBody, {
    required String parentPath,
  }) {
    final document = XmlDocument.parse(xmlBody);
    final entries = <WebdavEntry>[];
    final normalizedParent = _normalizePath(parentPath);
    for (final response
        in document.descendantElements.where((e) => e.name.local == 'response')) {
      String? href;
      var isDirectory = false;
      int? size;
      for (final child in response.childElements) {
        switch (child.name.local) {
          case 'href':
            href = child.innerText.trim();
          case 'propstat':
            for (final prop in child.descendantElements) {
              switch (prop.name.local) {
                case 'resourcetype':
                  isDirectory = prop.descendantElements
                      .any((e) => e.name.local == 'collection');
                case 'getcontentlength':
                  size = int.tryParse(prop.innerText.trim()) ?? size;
              }
            }
        }
      }
      if (href == null) continue;
      // href 可能是完整 URL 或路径
      final parsed = Uri.tryParse(href);
      final rawPath = (parsed != null && parsed.hasScheme) ? parsed.path : href;
      final normalized = _normalizePath(rawPath);
      if (normalized == normalizedParent || normalized.isEmpty) {
        continue; // 集合自身
      }
      final segments =
          normalized.split('/').where((s) => s.isNotEmpty).toList();
      if (segments.isEmpty) continue;
      entries.add(WebdavEntry(
        name: segments.last,
        path: normalized,
        isDirectory: isDirectory,
        sizeBytes: size,
      ));
    }
    entries.sort((a, b) {
      if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
      return naturalCompare(a.name, b.name);
    });
    return entries;
  }

  static String _normalizePath(String path) {
    final decoded = Uri.tryParse(path)?.path ?? path;
    var normalized = Uri.decodeComponent(decoded);
    if (!normalized.startsWith('/')) normalized = '/$normalized';
    while (normalized.length > 1 && normalized.endsWith('/')) {
      normalized = normalized.substring(0, normalized.length - 1);
    }
    return normalized;
  }
}
