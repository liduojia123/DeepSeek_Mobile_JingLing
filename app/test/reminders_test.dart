import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jingling/core/api.dart';
import 'package:jingling/core/reminders.dart';
import 'package:jingling/models/events.dart';
import 'package:jingling/models/reminder.dart';

/// M7 提醒:
///  1) SSE 事件解析(与 server/src/deepseek/events.ts 对齐);
///  2) 原生通道 `jingling/reminders` 的调用契约;
///  3) 补排逻辑:排上/跳过墓碑/过期收尾/时间被改后回写。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('事件解析', () {
    test('reminder 与 reminder_cancel', () {
      final reminder = DpappEvent.fromJson({
        'type': 'reminder',
        'reminder_id': 'r1',
        'text': '关火',
        'fire_at': '2026-11-17T12:30:00.000Z',
      });
      expect(reminder, isA<ReminderEvent>());
      final typed = reminder! as ReminderEvent;
      expect(typed.reminderId, 'r1');
      expect(typed.text, '关火');
      expect(typed.fireAt, '2026-11-17T12:30:00.000Z');

      final cancel = DpappEvent.fromJson({'type': 'reminder_cancel', 'reminder_id': 'r1'});
      expect(cancel, isA<ReminderCancelEvent>());
      expect((cancel! as ReminderCancelEvent).reminderId, 'r1');
    });

    test('未知事件仍然返回 null(旧客户端不崩)', () {
      expect(DpappEvent.fromJson({'type': 'reminder_v2'}), isNull);
    });
  });

  group('原生通道契约', () {
    const channel = MethodChannel('jingling/reminders');
    late List<MethodCall> calls;

    setUp(() {
      calls = [];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        switch (call.method) {
          case 'schedule':
            return true;
          case 'cancel':
            return true;
          case 'listScheduled':
            return <dynamic>[
              {'id': 'local-1', 'text': '本地', 'fireAtMs': 1763382600000},
            ];
          case 'canScheduleExact':
            return true;
          default:
            return null;
        }
      });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('schedule 传 id/text/fireAtMs,cancel 传 id', () async {
      expect(await RemindersChannel.schedule(id: 'r1', text: '关火', fireAtMs: 1763382600000), isTrue);
      final args = calls.first.arguments as Map;
      expect(args['id'], 'r1');
      expect(args['text'], '关火');
      expect(args['fireAtMs'], 1763382600000);

      expect(await RemindersChannel.cancel('r1'), isTrue);
      expect((calls.last.arguments as Map)['id'], 'r1');
    });

    test('listScheduled 解析成 ReminderAlarm', () async {
      final alarms = await RemindersChannel.listScheduled();
      expect(alarms, hasLength(1));
      expect(alarms.first.id, 'local-1');
      expect(alarms.first.fireAtMs, 1763382600000);
    });

    test('没有原生通道时静默失败(Web/测试环境)', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      expect(await RemindersChannel.schedule(id: 'r1', text: 't', fireAtMs: 1), isFalse);
      expect(await RemindersChannel.listScheduled(), isEmpty);
      expect(await RemindersChannel.canScheduleExact(), isFalse);
    });
  });

  group('补排 syncReminders', () {
    late _FakeApi api;
    late List<String> scheduled;
    var now = DateTime.utc(2026, 11, 17, 12, 0, 0);

    setUp(() {
      api = _FakeApi();
      scheduled = [];
      now = DateTime.utc(2026, 11, 17, 12, 0, 0);
    });

    Future<void> run({
      Set<String> tombstones = const <String>{},
      List<ReminderAlarm> local = const [],
      bool scheduleOk = true,
    }) =>
        syncReminders(
          api: api,
          tombstones: tombstones,
          nowMs: () => now.millisecondsSinceEpoch,
          listScheduled: () async => local,
          schedule: ({required String id, required String text, required int fireAtMs}) async {
            scheduled.add(id);
            return scheduleOk;
          },
        );

    test('未来的 pending → 排闹钟并 ack scheduled', () async {
      api.reminders = [_reminder('r1', now.add(const Duration(minutes: 30)))];
      await run();
      expect(scheduled, ['r1']);
      expect(api.acks, [('r1', 'scheduled', null)]);
    });

    test('墓碑里的 id 不再排,并重试 ack cancelled', () async {
      api.reminders = [_reminder('r1', now.add(const Duration(minutes: 30)))];
      await run(tombstones: {'r1'});
      expect(scheduled, isEmpty);
      expect(api.acks, [('r1', 'cancelled', null)]);
    });

    test('已经过期又没排上 → ack fired,不排', () async {
      api.reminders = [_reminder('r1', now.subtract(const Duration(minutes: 5)))];
      await run();
      expect(scheduled, isEmpty);
      expect(api.acks, [('r1', 'fired', null)]);
    });

    test('本地时间被改过(稍后提醒)→ 回写 fire_at', () async {
      final snoozed = now.add(const Duration(minutes: 40));
      api.reminders = [_reminder('r1', now.add(const Duration(minutes: 30)))];
      await run(local: [
        ReminderAlarm(id: 'r1', text: '关火', fireAtMs: snoozed.millisecondsSinceEpoch),
      ]);
      expect(scheduled, isEmpty, reason: '本地已有闹钟,不该重排');
      expect(api.acks, hasLength(1));
      expect(api.acks.first.$1, 'r1');
      expect(api.acks.first.$2, 'scheduled');
      expect(DateTime.parse(api.acks.first.$3!), snoozed);
    });

    test('排不上(没有精确闹钟权限)就不 ack,留给下次', () async {
      api.reminders = [_reminder('r1', now.add(const Duration(minutes: 30)))];
      await run(scheduleOk: false);
      expect(scheduled, ['r1']);
      expect(api.acks, isEmpty);
    });

    test('拉取失败(离线)静默返回', () async {
      api.failure = '离线';
      await run();
      expect(scheduled, isEmpty);
      expect(api.acks, isEmpty);
    });
  });
}

ServerReminder _reminder(String id, DateTime at) => ServerReminder(
      id: id,
      text: '关火',
      fireAt: at.toIso8601String(),
      status: 'pending',
    );

class _FakeApi extends ApiClient {
  _FakeApi() : super(baseUrl: 'http://127.0.0.1:1');

  List<ServerReminder> reminders = const [];
  String? failure;
  final List<(String, String, String?)> acks = [];

  @override
  Future<List<ServerReminder>> remindersActive() async {
    if (failure != null) throw ApiException(failure!);
    return reminders;
  }

  @override
  Future<void> ackReminder(String id, {required String status, String? nativeAlarmId, String? fireAt}) async {
    acks.add((id, status, fireAt));
  }
}
