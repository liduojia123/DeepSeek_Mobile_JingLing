import 'dart:io';

import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

import '../models/models.dart';
import 'api.dart';

/// M6+ OTA:检查更新 → 下载 APK → 交给系统安装器(免插线升级)。
class UpdateService {
  static const MethodChannel _channel = MethodChannel('jingling/installer');

  /// 当前安装的版本号(来自 AndroidManifest)。
  static Future<({int code, String name})> currentVersion() async {
    final info = await PackageInfo.fromPlatform();
    final code = int.tryParse(info.buildNumber) ?? 0;
    return (code: code, name: info.version);
  }

  /// 查询是否有新版本;没有则返回 null。
  static Future<AppRelease?> check(ApiClient api) async {
    final latest = await api.appVersion();
    if (latest == null) return null;
    final current = await currentVersion();
    return latest.versionCode > current.code ? latest : null;
  }

  /// 下载到缓存目录并返回文件路径。
  static Future<String> download(
    ApiClient api, {
    required AppRelease release,
    void Function(double progress)? onProgress,
  }) async {
    final dir = await getTemporaryDirectory();
    final path = '${dir.path}/jingling-update-${release.versionCode}.apk';
    final file = File(path);
    if (await file.exists()) {
      await file.delete();
    }
    await api.downloadApk(path, onProgress: onProgress);
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
