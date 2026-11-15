import 'package:flutter_test/flutter_test.dart';
import 'package:jingling/core/api.dart';
import 'package:jingling/core/providers.dart';
import 'package:jingling/models/harness_stream.dart';
import 'package:jingling/pages/harness_session_page.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

/// 会话级桥接:时间线折叠逻辑 + 会话页渲染。
void main() {
  group('HarnessTimeline', () {
    test('用户/助手/工具按事件顺序折叠,tool_result 合并进对应调用', () {
      final timeline = HarnessTimeline();
      expect(
        timeline.applyEvent(const HarnessSessionEvent(
          sessionId: 's1',
          seq: 1,
          kind: 'user_message',
          payload: {'text': '电脑上问的', 'source': 'user'},
        )),
        isTrue,
      );
      expect(timeline.applyEvent(const HarnessSessionEvent(
        sessionId: 's1',
        seq: 2,
        kind: 'assistant_message',
        payload: {
          'text': '我看下目录',
          'reasoning': '先列目录',
          'tools': [
            {'call_id': 'c1', 'name': 'bash', 'arguments': '{"command":"ls"}'},
          ],
        },
      )), isTrue);
      expect(timeline.applyEvent(const HarnessSessionEvent(
        sessionId: 's1',
        seq: 3,
        kind: 'tool_result',
        payload: {'call_id': 'c1', 'text': 'a.txt\nb.txt', 'is_error': false},
      )), isTrue);

      expect(timeline.entries.length, 2);
      final assistant = timeline.entries[1] as HarnessAssistantEntry;
      expect(assistant.text, '我看下目录');
      expect(assistant.reasoning, '先列目录');
      expect(assistant.tools.single.name, 'bash');
      expect(assistant.tools.single.result, 'a.txt\nb.txt');
      expect(assistant.tools.single.done, isTrue);
    });

    test('重复 seq(重连补发)幂等,lastSeq 单调前进', () {
      final timeline = HarnessTimeline();
      const event = HarnessSessionEvent(
        sessionId: 's1',
        seq: 5,
        kind: 'user_message',
        payload: {'text': '一句话', 'source': 'jingling'},
      );
      expect(timeline.applyEvent(event), isTrue);
      expect(timeline.applyEvent(event), isFalse, reason: '同一 seq 不应重复入时间线');
      expect(timeline.entries.length, 1);
      expect(timeline.lastSeq, 5);
      final user = timeline.entries.single as HarnessUserEntry;
      expect(user.fromPhone, isTrue);
    });

    test('打字增量进草稿,持久 assistant_message 到达后清空', () {
      final timeline = HarnessTimeline();
      timeline.applyEvent(const HarnessSessionEvent(
        sessionId: 's1',
        seq: 1,
        kind: 'user_message',
        payload: {'text': '写个函数', 'source': 'user'},
      ));
      timeline.applyLive(const HarnessSessionLive(sessionId: 's1', kind: 'text', text: '好'));
      timeline.applyLive(const HarnessSessionLive(sessionId: 's1', kind: 'text', text: '的'));
      timeline.applyLive(const HarnessSessionLive(sessionId: 's1', kind: 'reasoning', text: '想想'));
      expect(timeline.draftText, '好的');
      expect(timeline.draftReasoning, '想想');

      timeline.applyEvent(const HarnessSessionEvent(
        sessionId: 's1',
        seq: 2,
        kind: 'assistant_message',
        payload: {'text': '好的,这是函数…'},
      ));
      expect(timeline.draftText, isEmpty);
      expect(timeline.draftReasoning, isEmpty);
      expect((timeline.entries.last as HarnessAssistantEntry).text, contains('函数'));
    });

    test('手机输入回显在持久 user_message 到达后消失;状态跟随 turn 事件', () {
      final timeline = HarnessTimeline();
      timeline.applyLive(const HarnessSessionLive(sessionId: 's1', kind: 'input_echo', text: '插一句'));
      expect(timeline.pendingInput, '插一句');

      timeline.applyEvent(const HarnessSessionEvent(
        sessionId: 's1',
        seq: 1,
        kind: 'user_message',
        payload: {'text': '插一句', 'source': 'jingling'},
      ));
      expect(timeline.pendingInput, isNull);
      expect((timeline.entries.single as HarnessUserEntry).fromPhone, isTrue);

      timeline.applyEvent(const HarnessSessionEvent(
        sessionId: 's1',
        seq: 2,
        kind: 'turn_end',
        payload: {'reason': 'stop'},
      ));
      expect(timeline.running, isFalse);
    });

    test('tool_call 先于 assistant_message 到达时也不丢工具卡片', () {
      final timeline = HarnessTimeline();
      timeline.applyEvent(const HarnessSessionEvent(
        sessionId: 's1',
        seq: 1,
        kind: 'tool_call',
        payload: {'call_id': 'c9', 'name': 'write', 'arguments': '{"file_path":"a.txt"}'},
      ));
      timeline.applyEvent(const HarnessSessionEvent(
        sessionId: 's1',
        seq: 2,
        kind: 'assistant_message',
        payload: {'text': '写好了'},
      ));
      final assistant = timeline.entries.whereType<HarnessAssistantEntry>().single;
      expect(assistant.tools.single.name, 'write');
    });
  });

  group('HarnessSessionPage', () {
    testWidgets('渲染历史 + 工具卡片 + 手机标记', (tester) async {
      final fake = _FakeHarnessApi(events: [
        const HarnessSessionReady(sessionId: 's1', lastSeq: 0, status: 'idle', permission: 'workspace-write'),
        const HarnessSessionEvent(
          sessionId: 's1',
          seq: 1,
          kind: 'user_message',
          payload: {'text': '电脑上问的', 'source': 'user'},
        ),
        const HarnessSessionEvent(
          sessionId: 's1',
          seq: 2,
          kind: 'assistant_message',
          payload: {
            'text': '列一下目录',
            'tools': [
              {'call_id': 'c1', 'name': 'bash', 'arguments': '{"command":"ls"}'},
            ],
          },
        ),
        const HarnessSessionEvent(
          sessionId: 's1',
          seq: 3,
          kind: 'tool_result',
          payload: {'call_id': 'c1', 'text': 'a.txt', 'is_error': false},
        ),
        const HarnessSessionEvent(
          sessionId: 's1',
          seq: 4,
          kind: 'user_message',
          payload: {'text': '手机上补一句', 'source': 'jingling'},
        ),
      ]);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [apiProvider.overrideWithValue(fake)],
          child: const MaterialApp(home: HarnessSessionPage(sessionId: 's1', title: '测试会话')),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.text('电脑上问的'), findsOneWidget);
      expect(find.text('列一下目录'), findsOneWidget);
      expect(find.text('bash'), findsOneWidget);
      expect(find.text('手机上补一句'), findsOneWidget);
      expect(find.text('手机'), findsOneWidget, reason: '手机发的消息要有来源标记');
      expect(find.text('测试会话'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
    });
  });
}

/// 只实现会话流的最小假 API(其余方法不会被这个页面用到)。
class _FakeHarnessApi extends ApiClient {
  _FakeHarnessApi({required this.events}) : super(baseUrl: 'http://127.0.0.1:1');

  final List<HarnessStreamEvent> events;

  @override
  Stream<HarnessStreamEvent> harnessSessionStream(String sessionId, {int afterSeq = 0}) =>
      Stream<HarnessStreamEvent>.fromIterable(events);

  @override
  Future<Map<String, dynamic>> harnessSessionInput(
    String sessionId, {
    required String text,
    String mode = 'auto',
  }) async =>
      {'session_id': sessionId, 'mode': mode, 'status': 'running'};
}
