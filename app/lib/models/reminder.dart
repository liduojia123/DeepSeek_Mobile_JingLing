/// M7 提醒:服务端只记录"答应过什么时候提醒",真正响的是手机本地闹钟。
library;

/// 服务端 `/v1/reminders` 返回的一条提醒。
class ServerReminder {
  const ServerReminder({
    required this.id,
    required this.text,
    required this.fireAt,
    required this.status,
  });

  final String id;
  final String text;

  /// 带时区偏移的 ISO8601(服务端统一发 UTC `...Z` 形式)
  final String fireAt;

  /// pending(还没排进手机)/ scheduled(排过)/ fired / cancelled
  final String status;

  factory ServerReminder.fromJson(Map<String, dynamic> json) => ServerReminder(
        id: (json['id'] as String?) ?? '',
        text: (json['text'] as String?) ?? '',
        fireAt: (json['fire_at'] as String?) ?? '',
        status: (json['status'] as String?) ?? 'pending',
      );
}
