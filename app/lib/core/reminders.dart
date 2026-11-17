import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../models/reminder.dart';
import 'api.dart';

/// 手机本地已经排好的闹钟(来自原生 SharedPreferences 副本)。
class ReminderAlarm {
  const ReminderAlarm({required this.id, required this.text, required this.fireAtMs});

  final String id;
  final String text;
  final int fireAtMs;
}

/// M7 原生通道 `jingling/reminders` 的薄封装。
///
/// 和 `jingling/wait` 一样吞掉 [MissingPluginException]:Web/测试环境没有原生实现,
/// 静默失败即可,不能让设置页或对话页崩。
class RemindersChannel {
  static const MethodChannel _channel = MethodChannel('jingling/reminders');

  /// Android 12+ 需要用户单独允许"精确闹钟";更早版本恒 true。
  static Future<bool> canScheduleExact() async {
    try {
      return await _channel.invokeMethod<bool>('canScheduleExact') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  static Future<void> openExactAlarmSettings() async {
    try {
      await _channel.invokeMethod<void>('openExactAlarmSettings');
    } on MissingPluginException {
      // 非 Android:无此设置页
    } on PlatformException {
      // ignore
    }
  }

  static Future<List<ReminderAlarm>> listScheduled() async {
    try {
      final raw = await _channel.invokeMethod<List<dynamic>>('listScheduled');
      if (raw == null) return const [];
      return raw
          .whereType<Map>()
          .map((item) => ReminderAlarm(
                id: (item['id'] as String?) ?? '',
                text: (item['text'] as String?) ?? '',
                fireAtMs: (item['fireAtMs'] as num?)?.toInt() ?? 0,
              ))
          .where((alarm) => alarm.id.isNotEmpty)
          .toList(growable: false);
    } on MissingPluginException {
      return const [];
    } on PlatformException {
      return const [];
    }
  }

  /// 排一个提醒(同 id 覆盖)。返回 false 表示没有成功(权限被拒/原生不可用)。
  static Future<bool> schedule({required String id, required String text, required int fireAtMs}) async {
    try {
      return await _channel.invokeMethod<bool>('schedule', {
            'id': id,
            'text': text,
            'fireAtMs': fireAtMs,
          }) ??
          false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  static Future<bool> cancel(String id) async {
    try {
      return await _channel.invokeMethod<bool>('cancel', {'id': id}) ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }
}

/// 补排:把服务端还没落地的提醒排进手机闹钟,并把结果 ack 回去。
///
/// 幂等设计:同 id 排闹钟会覆盖,所以每次前台都可以无脑重跑;
/// `tombstones` 是本地"已取消"集合,防止"取消时 ack 失败 → 下次又被排回来"。
Future<void> syncReminders({
  required ApiClient api,
  Future<List<ReminderAlarm>> Function() listScheduled = RemindersChannel.listScheduled,
  Future<bool> Function({required String id, required String text, required int fireAtMs}) schedule =
      RemindersChannel.schedule,
  Set<String> tombstones = const <String>{},
  int Function()? nowMs,
  void Function(Iterable<String> ids)? onSeen,
}) async {
  final now = (nowMs ?? () => DateTime.now().millisecondsSinceEpoch)();
  final List<ServerReminder> pending;
  try {
    pending = await api.remindersActive();
  } catch (_) {
    return; // 离线/未配对:下次前台再来
  }
  onSeen?.call(pending.map((item) => item.id));
  if (pending.isEmpty) return;

  final local = {for (final alarm in await listScheduled()) alarm.id: alarm};

  for (final item in pending) {
    final fireMs = DateTime.tryParse(item.fireAt)?.millisecondsSinceEpoch;
    if (fireMs == null || item.id.isEmpty) continue;

    if (tombstones.contains(item.id)) {
      await _ack(api, item.id, 'cancelled');
      continue;
    }

    final alarm = local[item.id];
    if (alarm != null) {
      // 本地时间被改过(稍后提醒):回写,别让服务端记着旧时间
      if (alarm.fireAtMs != fireMs) {
        await _ack(api, item.id, 'scheduled',
            fireAt: DateTime.fromMillisecondsSinceEpoch(alarm.fireAtMs).toUtc().toIso8601String());
      }
      continue;
    }

    if (fireMs <= now) {
      // 已经过了又没排上:不再重排,标记收尾(多半是强停/关机导致丢了)
      await _ack(api, item.id, 'fired');
      continue;
    }

    final ok = await schedule(id: item.id, text: item.text, fireAtMs: fireMs);
    if (ok) await _ack(api, item.id, 'scheduled');
  }
}

Future<void> _ack(ApiClient api, String id, String status, {String? fireAt}) async {
  try {
    await api.ackReminder(id, status: status, fireAt: fireAt);
  } catch (_) {
    // ack 失败不影响"闹钟已经排上";下次前台会再来一次
  }
}

/// 本地"已取消"墓碑。
///
/// 取消时如果 ack 没送达,服务端仍会把它当 pending 返回;没有墓碑的话,
/// 下次补排会把用户刚取消的闹钟又排回来 —— 这是最容易被忽略的坑。
class ReminderTombstones {
  static const String _key = 'jingling.reminder_cancelled';
  static const FlutterSecureStorage _storage = FlutterSecureStorage();

  static Future<Set<String>> load() async {
    try {
      final raw = await _storage.read(key: _key);
      if (raw == null || raw.trim().isEmpty) return <String>{};
      return raw.split(',').where((id) => id.isNotEmpty).toSet();
    } catch (_) {
      return <String>{}; // 测试/无插件环境
    }
  }

  static Future<void> add(String id) async {
    final current = await load();
    if (!current.add(id)) return;
    await _save(current);
  }

  static Future<void> removeAll(Iterable<String> ids) async {
    final current = await load();
    final removed = ids.where(current.remove).length;
    if (removed == 0) return;
    await _save(current);
  }

  static Future<void> _save(Set<String> ids) async {
    try {
      await _storage.write(key: _key, value: ids.join(','));
    } catch (_) {
      // 存不下就算了:最坏结果是重复排一次闹钟
    }
  }
}

/// App 启动/回前台时调一次(不 await,失败静默)。
void syncRemindersInBackground(ApiClient? api) {
  if (api == null) return;
  unawaited(() async {
    final tombstones = await ReminderTombstones.load();
    final alive = <String>{};
    await syncReminders(
      api: api,
      tombstones: tombstones,
      onSeen: alive.addAll,
    );
    // 服务端已经不再返回的墓碑可以清掉,免得越攒越多
    await ReminderTombstones.removeAll(tombstones.difference(alive));
  }());
}
