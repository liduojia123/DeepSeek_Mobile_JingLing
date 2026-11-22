import 'package:flutter_test/flutter_test.dart';
import 'package:jingling/models/models.dart';
import 'package:jingling/widgets/message_bubble.dart';
import 'package:jingling/widgets/search_snippet.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  group('搜索高亮切分', () {
    test('多处命中都高亮,不区分大小写', () {
      const text = 'Hello world, hello 鲸灵';
      final segments = highlightSegments(text, 'hello');
      expect(segments.map((segment) => segment.text).join(), text);
      expect(segments.where((segment) => segment.highlighted).map((segment) => segment.text), ['Hello', 'hello']);
    });

    test('中文按子串匹配', () {
      final segments = highlightSegments('鲸灵是手机上的助手', '手机');
      expect(segments.where((segment) => segment.highlighted).single.text, '手机');
    });

    test('空查询与未命中返回单段原文', () {
      final blank = highlightSegments('abc', '   ');
      expect(blank.single.text, 'abc');
      expect(blank.single.highlighted, isFalse);
      expect(highlightSegments('abc', 'zzz').single.highlighted, isFalse);
    });
  });

  group('搜索结果模型', () {
    test('SearchGroup/SearchHit 解析', () {
      final group = SearchGroup.fromJson({
        'conversation': {'id': 'c1', 'title': '部署', 'pinned': true, 'updated_at': '2026-01-01T00:00:00.000Z'},
        'hits': [
          {'message_id': null, 'field': 'title', 'role': null, 'created_at': '2026-01-01T00:00:00.000Z', 'snippet': ''},
          {
            'message_id': 'm9',
            'field': 'message',
            'role': 'assistant',
            'created_at': '2026-01-02T00:00:00.000Z',
            'snippet': '…Caddy 配置…',
          },
        ],
      });
      expect(group.conversationId, 'c1');
      expect(group.title, '部署');
      expect(group.pinned, isTrue);
      expect(group.hits.length, 2);
      expect(group.hits[0].isTitleHit, isTrue);
      expect(group.hits[0].messageId, isNull);
      expect(group.hits[1].isTitleHit, isFalse);
      expect(group.hits[1].messageId, 'm9');
      expect(group.hits[1].snippet, '…Caddy 配置…');
    });

    test('缺字段时兜底不抛', () {
      final group = SearchGroup.fromJson(const {});
      expect(group.conversationId, '');
      expect(group.hits, isEmpty);
      final hit = SearchHit.fromJson(const {});
      expect(hit.field, 'message');
      expect(hit.snippet, '');
    });
  });

  group('搜索跳转高亮', () {
    MessageNode node() => MessageNode.fromJson({
          'id': 'm1',
          'parent_id': null,
          'role': 'assistant',
          'blocks': [
            {'type': 'text', 'text': '命中的一条消息'},
          ],
          'thinking': '',
          'citations': <Object>[],
          'tool_traces': <Object>[],
          'usage': {'tokens_in': 0, 'tokens_out': 0, 'cost': 0},
          'children': <Object>[],
        });

    Widget wrap({required bool highlighted}) => MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: MessageBubble(
                node: node(),
                position: 1,
                count: 1,
                highlighted: highlighted,
                onBranchSelected: (_) {},
                onLongPress: () {},
              ),
            ),
          ),
        );

    testWidgets('highlighted=true 包高亮层,正文不丢', (tester) async {
      await tester.pumpWidget(wrap(highlighted: true));
      expect(find.byType(AnimatedContainer), findsOneWidget);
      expect(find.textContaining('命中的一条消息'), findsOneWidget);
    });

    testWidgets('highlighted=false 不包高亮层', (tester) async {
      await tester.pumpWidget(wrap(highlighted: false));
      expect(find.byType(AnimatedContainer), findsNothing);
      expect(find.textContaining('命中的一条消息'), findsOneWidget);
    });
  });
}
