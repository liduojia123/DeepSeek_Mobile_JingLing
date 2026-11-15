import 'package:flutter_test/flutter_test.dart';
import 'package:jingling/core/api.dart';
import 'package:jingling/core/update.dart';
import 'package:jingling/models/models.dart';

/// 检查更新的结果必须可区分:有新版本 / 已是最新 / 查询失败。
/// 以前"失败"和"已是最新"都返回 null,任何网络或令牌问题都会显示成「已是最新版本」。
void main() {
  group('UpdateService.check(服务器来源)', () {
    test('服务器版本更高 → 有新版本', () async {
      final api = _FakeApi(release: _release(versionCode: 12, versionName: '1.1.0', notes: '本次更新'));
      final result = await UpdateService.check(
        api,
        UpdateSource.server,
        current: (code: 10, name: '1.0.10'),
      );
      expect(result, isA<UpdateAvailable>());
      final info = (result as UpdateAvailable).info;
      expect(info.versionName, '1.1.0');
      expect(info.versionCode, 12);
      expect(info.notes, '本次更新');
    });

    test('版本相同 → 已是最新,并带上当前版本', () async {
      final api = _FakeApi(release: _release(versionCode: 12, versionName: '1.1.0'));
      final result = await UpdateService.check(
        api,
        UpdateSource.server,
        current: (code: 12, name: '1.1.0'),
      );
      expect(result, isA<UpdateUpToDate>());
      final upToDate = result as UpdateUpToDate;
      expect(upToDate.currentVersion, '1.1.0');
      expect(upToDate.currentCode, 12);
    });

    test('服务器没有发布安装包(404) → 明确说明,而不是"已是最新"', () async {
      final result = await UpdateService.check(
        _FakeApi(release: null),
        UpdateSource.server,
        current: (code: 10, name: '1.0.10'),
      );
      expect(result, isA<UpdateCheckFailed>());
      expect((result as UpdateCheckFailed).message, contains('还没有发布安装包'));
    });

    test('令牌失效/网络错误 → 失败并带原因,不伪装成已是最新', () async {
      final result = await UpdateService.check(
        _FakeApi(error: ApiException('设备令牌无效', statusCode: 401, code: 'unauthorized')),
        UpdateSource.server,
        current: (code: 10, name: '1.0.10'),
      );
      expect(result, isA<UpdateCheckFailed>());
      expect((result as UpdateCheckFailed).message, contains('设备令牌无效'));
    });
  });
}

AppRelease _release({required int versionCode, required String versionName, String notes = ''}) =>
    AppRelease(
      versionCode: versionCode,
      versionName: versionName,
      notes: notes,
      size: 19 * 1024 * 1024,
      downloadPath: '/v1/app/download',
    );

/// 只覆盖 appVersion 的假客户端。
class _FakeApi extends ApiClient {
  _FakeApi({this.release, this.error}) : super(baseUrl: 'http://127.0.0.1:1');

  final AppRelease? release;
  final ApiException? error;

  @override
  Future<AppRelease?> appVersion() async {
    if (error != null) throw error!;
    return release;
  }
}
