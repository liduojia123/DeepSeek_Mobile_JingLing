import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jingling/core/api.dart';
import 'package:jingling/core/harness_session_provider.dart';
import 'package:jingling/core/providers.dart';
import 'package:jingling/core/wait_alert.dart';
import 'package:jingling/models/harness_stream.dart';

/// M3.6:等待期通知。
///  1) WaitAlert 与原生通道的调用契约(start/update/stop/notifyResult,没通道时静默);
///  2) 会话在跑 → 起等待;本轮结束且 App 在后台 → 停等待并发结果通知。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('jingling/wait');
  late List<MethodCall> calls;

  setUp(() {
    calls = [];
    WaitAlert.resetForTest();
    AppVisibility.foreground = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'start':
          return true;
        case 'requestPermission':
        case 'canNotify':
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

  group('WaitAlert', () {
    test('start 一次、重复 start 变 update、stop 收尾', () async {
      expect(await WaitAlert.start(title: '鲸灵', text: '等着'), isTrue);
      expect(calls.map((c) => c.method).toList(), ['start']);
      expect(WaitAlert.waiting, isTrue);

      expect(await WaitAlert.start(title: '鲸灵', text: '还在等'), isTrue);
      expect(calls.map((c) => c.method).toList(), ['start', 'update']);
      expect((calls.last.arguments as Map)['text'], '还在等');

      await WaitAlert.stop();
      expect(calls.map((c) => c.method).toList(), ['start', 'update', 'stop']);
      expect(WaitAlert.waiting, isFalse);
    });

    test('没有原生通道时静默失败,不抛异常', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      expect(await WaitAlert.start(title: 't', text: 'x'), isFalse);
      await WaitAlert.stop();
      await WaitAlert.notifyResult(title: 't', text: 'x');
    });
  });

  group('会话等待流程', () {
    test('在跑 → 起等待;后台结束 → 停等待并发结果通知', () async {
      final events = StreamController<HarnessStreamEvent>();
      final container = ProviderContainer(
        overrides: [apiProvider.overrideWithValue(_FakeApi(events.stream))],
      );
      addTearDown(container.dispose);
      container.listen(harnessSessionProvider, (_, _) {});

      final controller = container.read(harnessSessionProvider.notifier);
      await controller.open('s1', title: 'DPAPP');
      events.add(const HarnessSessionReady(sessionId: 's1', lastSeq: 0, status: 'running'));
      await pumpEventQueue();
      expect(calls.map((c) => c.method), contains('start'));
      expect(WaitAlert.waiting, isTrue);

      // 用户切走 App,这一轮在后台结束
      AppVisibility.foreground = false;
      events.add(const HarnessSessionEvent(
        sessionId: 's1',
        seq: 1,
        kind: 'turn_end',
        payload: {'reason': 'completed'},
      ));
      await pumpEventQueue();

      expect(calls.map((c) => c.method), containsAllInOrder(['stop', 'notifyResult']));
      final result = calls.firstWhere((c) => c.method == 'notifyResult');
      expect((result.arguments as Map)['text'], contains('已完成'));
      expect(WaitAlert.waiting, isFalse);
    });

    test('App 在前台结束 → 只停等待,不打扰', () async {
      final events = StreamController<HarnessStreamEvent>();
      final container = ProviderContainer(
        overrides: [apiProvider.overrideWithValue(_FakeApi(events.stream))],
      );
      addTearDown(container.dispose);
      container.listen(harnessSessionProvider, (_, _) {});

      final controller = container.read(harnessSessionProvider.notifier);
      await controller.open('s1', title: 'DPAPP');
      events.add(const HarnessSessionReady(sessionId: 's1', lastSeq: 0, status: 'running'));
      await pumpEventQueue();

      AppVisibility.foreground = true;
      events.add(const HarnessSessionEvent(
        sessionId: 's1',
        seq: 1,
        kind: 'turn_end',
        payload: {'reason': 'completed'},
      ));
      await pumpEventQueue();

      expect(calls.map((c) => c.method), contains('stop'));
      expect(calls.map((c) => c.method), isNot(contains('notifyResult')));
    });

    test('电脑断线且正在等 → 通知「电脑断线了」', () async {
      final events = StreamController<HarnessStreamEvent>();
      final container = ProviderContainer(
        overrides: [apiProvider.overrideWithValue(_FakeApi(events.stream))],
      );
      addTearDown(container.dispose);
      container.listen(harnessSessionProvider, (_, _) {});

      final controller = container.read(harnessSessionProvider.notifier);
      await controller.open('s1', title: 'DPAPP');
      events.add(const HarnessSessionReady(sessionId: 's1', lastSeq: 0, status: 'running'));
      await pumpEventQueue();

      AppVisibility.foreground = false;
      events.add(const HarnessSessionLive(
        sessionId: 's1',
        kind: 'error',
        message: '电脑节点断开连接',
      ));
      await pumpEventQueue();

      final result = calls.firstWhere((c) => c.method == 'notifyResult');
      expect((result.arguments as Map)['text'], contains('断线'));
    });
  });
}

class _FakeApi extends ApiClient {
  _FakeApi(this.stream) : super(baseUrl: 'http://127.0.0.1:1');

  final Stream<HarnessStreamEvent> stream;

  @override
  Stream<HarnessStreamEvent> harnessSessionStream(String sessionId, {int afterSeq = 0}) => stream;

  @override
  Future<Map<String, dynamic>> harnessSessionInput(
    String sessionId, {
    required String text,
    String mode = 'auto',
  }) async =>
      {'session_id': sessionId, 'mode': mode, 'status': 'running'};
}
