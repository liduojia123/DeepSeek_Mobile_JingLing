import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// 客户端本地只存两样东西:服务器地址与设备令牌(系统安全存储)。
/// 其余数据以服务端为准,换手机不丢。
class SecureStore {
  const SecureStore([this._storage = const FlutterSecureStorage()]);

  final FlutterSecureStorage _storage;

  static const String defaultServerUrl = 'http://127.0.0.1:3000';
  static const String _serverUrlKey = 'jingling.server_url';
  static const String _tokenKey = 'jingling.device_token';
  static const String _updateSourceKey = 'jingling.update_source';

  Future<String> readServerUrl() async {
    final value = await _storage.read(key: _serverUrlKey);
    final trimmed = value?.trim() ?? '';
    return trimmed.isEmpty ? defaultServerUrl : trimmed;
  }

  Future<void> writeServerUrl(String url) async {
    final trimmed = url.trim();
    await _storage.write(key: _serverUrlKey, value: trimmed.isEmpty ? defaultServerUrl : trimmed);
  }

  /// OTA 更新来源:'server'(默认)或 'github'。
  Future<String> readUpdateSource() async {
    final value = await _storage.read(key: _updateSourceKey);
    return value == 'github' ? 'github' : 'server';
  }

  Future<void> writeUpdateSource(String source) async {
    await _storage.write(key: _updateSourceKey, value: source == 'github' ? 'github' : 'server');
  }

  Future<String?> readToken() async {
    final value = await _storage.read(key: _tokenKey);
    if (value == null || value.trim().isEmpty) return null;
    return value;
  }

  Future<void> writeToken(String? token) async {
    if (token == null || token.trim().isEmpty) {
      await _storage.delete(key: _tokenKey);
      return;
    }
    await _storage.write(key: _tokenKey, value: token);
  }
}
