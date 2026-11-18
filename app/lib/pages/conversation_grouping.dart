import '../../models/models.dart';

/// 会话列表的分组:置顶 → 今天 → 昨天 → 本周 → 更早。
///
/// 纯函数,不碰 UI 也不碰时区数据库,方便单测(HANDOFF-M8 §4.1)。
enum ConversationBucket {
  pinned,
  today,
  yesterday,
  thisWeek,
  earlier;

  String get label => switch (this) {
        ConversationBucket.pinned => '置顶',
        ConversationBucket.today => '今天',
        ConversationBucket.yesterday => '昨天',
        ConversationBucket.thisWeek => '本周',
        ConversationBucket.earlier => '更早',
      };
}

class ConversationGroup {
  const ConversationGroup(this.bucket, this.items);

  final ConversationBucket bucket;
  final List<Conversation> items;

  String get label => bucket.label;
}

/// 按"最近改动时间"分桶。`now` 由调用方给(测试里可注入)。
List<ConversationGroup> groupConversations(List<Conversation> items, {DateTime? now}) {
  final current = now ?? DateTime.now();
  final today = DateTime(current.year, current.month, current.day);
  final yesterday = today.subtract(const Duration(days: 1));
  // 周一为一周的开始
  final weekStart = today.subtract(Duration(days: today.weekday - 1));

  final pinned = <Conversation>[];
  final buckets = <ConversationBucket, List<Conversation>>{
    ConversationBucket.today: <Conversation>[],
    ConversationBucket.yesterday: <Conversation>[],
    ConversationBucket.thisWeek: <Conversation>[],
    ConversationBucket.earlier: <Conversation>[],
  };

  for (final item in items) {
    if (item.pinned) {
      pinned.add(item);
      continue;
    }
    final at = _parse(item.updatedAt)?.toLocal();
    final bucket = at == null
        ? ConversationBucket.earlier
        : at.isAfter(today) || at.isAtSameMomentAs(today)
            ? ConversationBucket.today
            : at.isAfter(yesterday) || at.isAtSameMomentAs(yesterday)
                ? ConversationBucket.yesterday
                : at.isAfter(weekStart) || at.isAtSameMomentAs(weekStart)
                    ? ConversationBucket.thisWeek
                    : ConversationBucket.earlier;
    buckets[bucket]!.add(item);
  }

  final groups = <ConversationGroup>[];
  if (pinned.isNotEmpty) groups.add(ConversationGroup(ConversationBucket.pinned, pinned));
  for (final entry in buckets.entries) {
    if (entry.value.isNotEmpty) groups.add(ConversationGroup(entry.key, entry.value));
  }
  return groups;
}

/// 列表里的时间:今天只给时:分,更早给 月-日。
String conversationTimeLabel(String updatedAt, {DateTime? now}) {
  final at = _parse(updatedAt)?.toLocal();
  if (at == null) return '';
  final current = (now ?? DateTime.now()).toLocal();
  String two(int v) => v.toString().padLeft(2, '0');
  final sameDay = at.year == current.year && at.month == current.month && at.day == current.day;
  if (sameDay) return '${two(at.hour)}:${two(at.minute)}';
  if (at.year == current.year) return '${two(at.month)}-${two(at.day)}';
  return '${at.year}-${two(at.month)}-${two(at.day)}';
}

/// 搜索:标题或预览包含关键词(不区分大小写)。空查询返回原列表。
List<Conversation> filterConversations(List<Conversation> items, String query) {
  final needle = query.trim().toLowerCase();
  if (needle.isEmpty) return items;
  return items
      .where((item) =>
          item.displayTitle.toLowerCase().contains(needle) ||
          item.preview.toLowerCase().contains(needle))
      .toList(growable: false);
}

DateTime? _parse(String value) => DateTime.tryParse(value);
