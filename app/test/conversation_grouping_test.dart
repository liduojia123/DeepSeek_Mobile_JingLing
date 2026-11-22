import 'package:flutter_test/flutter_test.dart';
import 'package:jingling/models/models.dart';
import 'package:jingling/pages/conversation_grouping.dart';

/// M8 §4.1 的分组与搜索是纯函数,直接测,不碰 UI。
void main() {
  final now = DateTime(2026, 11, 18, 11, 30); // 周三

  Conversation conv(
    String id, {
    required DateTime updatedAt,
    bool pinned = false,
    String title = '',
    String preview = '',
  }) =>
      Conversation(
        id: id,
        title: title,
        pinned: pinned,
        ephemeral: false,
        activeLeafId: null,
        preview: preview,
        updatedAt: updatedAt.toIso8601String(),
      );

  group('分组', () {
    test('置顶永远在最前,且不参与日期分桶', () {
      final groups = groupConversations([
        conv('a', updatedAt: DateTime(2026, 9, 1, 9)),
        conv('pin', updatedAt: DateTime(2026, 9, 2, 9), pinned: true),
        conv('b', updatedAt: DateTime(2026, 11, 18, 10)),
      ], now: now);

      expect(groups.first.bucket, ConversationBucket.pinned);
      expect(groups.first.items.single.id, 'pin');
      // 后面的分桶里不应再出现置顶那条
      expect(groups.skip(1).expand((g) => g.items).map((c) => c.id), isNot(contains('pin')));
    });

    test('今天 / 昨天 / 本周 / 更早 分桶正确', () {
      final groups = groupConversations([
        conv('today', updatedAt: DateTime(2026, 11, 18, 8)),
        conv('yesterday', updatedAt: DateTime(2026, 11, 17, 23)),
        conv('week', updatedAt: DateTime(2026, 11, 16, 9)), // 周一
        conv('old', updatedAt: DateTime(2026, 10, 1, 9)),
      ], now: now);

      final byBucket = {for (final g in groups) g.bucket: g.items.map((c) => c.id).toList()};
      expect(byBucket[ConversationBucket.today], ['today']);
      expect(byBucket[ConversationBucket.yesterday], ['yesterday']);
      expect(byBucket[ConversationBucket.thisWeek], ['week']);
      expect(byBucket[ConversationBucket.earlier], ['old']);
    });

    test('空分组不出现,时间不可解析的落到更早', () {
      final groups = groupConversations([
        Conversation(
          id: 'broken',
          title: '',
          pinned: false,
          ephemeral: false,
          activeLeafId: null,
          preview: '',
          updatedAt: 'not-a-date',
        ),
      ], now: now);
      expect(groups, hasLength(1));
      expect(groups.single.bucket, ConversationBucket.earlier);
    });

    test('分组标题是中文', () {
      expect(ConversationBucket.pinned.label, '置顶');
      expect(ConversationBucket.thisWeek.label, '本周');
    });
  });

  group('时间标签', () {
    test('今天只给时分,今年给月日,跨年给年月日', () {
      expect(conversationTimeLabel(DateTime(2026, 11, 18, 7, 5).toIso8601String(), now: now), '07:05');
      expect(conversationTimeLabel(DateTime(2026, 11, 2, 7, 5).toIso8601String(), now: now), '11-02');
      expect(conversationTimeLabel(DateTime(2025, 12, 31, 7, 5).toIso8601String(), now: now), '2025-12-31');
    });

    test('解析不了返回空串,不抛异常', () {
      expect(conversationTimeLabel('nope', now: now), '');
    });
  });

  group('预览纯文本化', () {
    test('去掉加粗/反引号/标题/引用记号', () {
      expect(plainPreview('根据我保存的记忆,你平时用 **DeepSeek Harness** 工具'), '根据我保存的记忆,你平时用 DeepSeek Harness 工具');
      expect(plainPreview('# 标题'), '标题');
      expect(plainPreview('> 引用一行'), '引用一行');
      expect(plainPreview('跑 `npm test` 就行'), '跑 npm test 就行');
    });

    test('链接只留文字,压缩空白', () {
      expect(plainPreview('见 [部署文档](https://example.com/a)\n\n然后'), '见 部署文档 然后');
    });
  });
}
