import 'package:flutter_test/flutter_test.dart';
import 'package:jingling/models/models.dart';

void main() {
  group('ModelKeyStatus', () {
    test('解析 custom/default/none 与 hint', () {
      final custom = ModelKeyStatus.fromJson(const {'source': 'custom', 'hint': '…abcd'});
      expect(custom.isCustom, isTrue);
      expect(custom.hint, '…abcd');

      final fallback = ModelKeyStatus.fromJson(const {'source': 'default', 'hint': '…efgh'});
      expect(fallback.isCustom, isFalse);
      expect(fallback.source, 'default');

      final none = ModelKeyStatus.fromJson(const {'source': 'none', 'hint': ''});
      expect(none.isCustom, isFalse);
    });

    test('缺字段兜底不抛', () {
      final status = ModelKeyStatus.fromJson(const {});
      expect(status.source, 'none');
      expect(status.hint, '');
    });
  });
}
