import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

import 'api.dart';
import 'config.dart';

/// OTA 更新来源:自己的服务器,或 GitHub Releases(用户自选)。
enum UpdateSource { server, github }

/// 一次可安装的更新(两个来源归一化后的结果)。
class UpdateInfo {
  const UpdateInfo({
    required this.source,
    required this.versionName,
    required this.versionCode,
    required this.notes,
    required this.size,
    required this.downloadUrl,
  });

  final UpdateSource source;
  final String versionName;
  final int versionCode;
  final String notes;
  final int size;
  /// 服务器来源时是相对路径(需要带设备令牌),GitHub 时是绝对 URL。
  final String downloadUrl;
}

/// M6+ OTA:检查更新 → 下载 APK → 交给系统安装器(免插线升级)。
class UpdateService {
  static const MethodChannel _channel = MethodChannel('jingling/installer');
  static const String _githubRepo = 'liduojia123/DeepSeek_Mobile_JingLing';

  /// 当前安装的版本号(来自 AndroidManifest)。
  static Future<({int code, String name})> currentVersion() async {
    final info = await PackageInfo.fromPlatform();
    final code = int.tryParse(info.buildNumber) ?? 0;
    return (code: code, name: info.version);
  }

  static Future<UpdateSource> readSource() async {
    final saved = await const SecureStore().readUpdateSource();
    return saved == 'github' ? UpdateSource.github : UpdateSource.server;
  }

  static Future<void> writeSource(UpdateSource source) async {
    await const SecureStore().writeUpdateSource(source == UpdateSource.github ? 'github' : 'server');
  }

  /// 按来源查询是否有新版本;没有则返回 null。
  static Future<UpdateInfo?> check(ApiClient api, UpdateSource source) async {
    final current = await currentVersion();
    if (source == UpdateSource.server) {
      final latest = await api.appVersion();
      if (latest == null) return null;
      if (latest.versionCode <= current.code) return null;
      return UpdateInfo(
        source: UpdateSource.server,
        versionName: latest.versionName,
        versionCode: latest.versionCode,
        notes: latest.notes,
        size: latest.size,
        downloadUrl: latest.downloadPath,
      );
    }
    return _checkGithub(current.name);
  }

  static Future<UpdateInfo?> _checkGithub(String currentName) async {
    final response = await http.get(
      Uri.parse('https://api.github.com/repos/$_githubRepo/releases/latest'),
      headers: const {'Accept': 'application/vnd.github+json'},
    );
    if (response.statusCode != 200) {
      throw ApiException('GitHub 查询失败(HTTP ${response.statusCode})');
    }
    final json = jsonDecode(response.body) as Map<String, dynamic>;
    final tag = (json['tag_name'] as String?) ?? '';
    final versionName = tag.startsWith('v') ? tag.substring(1) : tag;
    if (versionName.isEmpty || !_isNewer(versionName, currentName)) return null;

    final assets = (json['assets'] as List?) ?? const [];
    Map<String, dynamic>? apk;
    for (final item in assets.whereType<Map>()) {
      final name = (item['name'] as String?) ?? '';
      if (name.endsWith('.apk')) {
        apk = Map<String, dynamic>.from(item);
        break;
      }
    }
    if (apk == null) return null;
    return UpdateInfo(
      source: UpdateSource.github,
      versionName: versionName,
      versionCode: 0,
      notes: (json['body'] as String?) ?? '',
      size: (apk['size'] as num?)?.toInt() ?? 0,
      downloadUrl: (apk['browser_download_url'] as String?) ?? '',
    );
  }

  /// 语义化版本比较:1.0.10 > 1.0.9。
  static bool _isNewer(String candidate, String current) {
    List<int> parse(String value) => value
        .split(RegExp(r'[.+\-]'))
        .where((part) => part.isNotEmpty)
        .map((part) => int.tryParse(part) ?? 0)
        .toList(growable: false);
    final a = parse(candidate);
    final b = parse(current);
    for (var i = 0; i < a.length || i < b.length; i += 1) {
      final left = i < a.length ? a[i] : 0;
      final right = i < b.length ? b[i] : 0;
      if (left != right) return left > right;
    }
    return false;
  }

  /// 下载到缓存目录并返回文件路径。
  static Future<String> download(
    ApiClient api, {
    required UpdateInfo info,
    void Function(double progress)? onProgress,
  }) async {
    final dir = await getTemporaryDirectory();
    final path = '${dir.path}/jingling-update-${info.versionName}.apk';
    final file = File(path);
    if (await file.exists()) {
      await file.delete();
    }
    if (info.source == UpdateSource.server) {
      await api.downloadApk(path, onProgress: onProgress);
      return path;
    }

    final response = await http.Client().send(http.Request('GET', Uri.parse(info.downloadUrl)));
    if (response.statusCode != 200) {
      throw ApiException('GitHub 下载失败(HTTP ${response.statusCode})');
    }
    final total = response.contentLength ?? info.size;
    var received = 0;
    final sink = file.openWrite();
    try {
      await for (final chunk in response.stream) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0 && onProgress != null) onProgress(received / total);
      }
      await sink.flush();
    } finally {
      await sink.close();
    }
    if (received == 0) throw ApiException('下载内容为空,请稍后重试');
    return path;
  }

  static Future<bool> canInstall() async {
    try {
      return await _channel.invokeMethod<bool>('canInstall') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      // Web/桌面端没有安装器通道
      return false;
    }
  }

  static Future<void> openInstallPermission() async {
    try {
      await _channel.invokeMethod('openInstallPermission');
    } on PlatformException {
      // 忽略:用户也可能手动去设置里开
    } on MissingPluginException {
      // ignore
    }
  }

  static Future<void> install(String apkPath) async {
    await _channel.invokeMethod('installApk', {'path': apkPath});
  }
}
