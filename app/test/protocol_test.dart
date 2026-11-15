import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:jingling/core/sse_client.dart';
import 'package:jingling/models/events.dart';
import 'package:jingling/models/models.dart';

/// 协议层回归:SSE 切包鲁棒性 + 与 server/src/deepseek/events.ts 的字段同步。
void main() {
  group('SseStreamParser', () {
    test('跨 chunk 切断、CRLF、心跳注释都能正确解析', () {
      final parser = SseStreamParser();
      final events = <SseEvent>[];

      events.addAll(parser.addChunk('event: text_delta\r\ndata: {"type":"text_de'));
      events.addAll(parser.addChunk('lta","text":"你"}\r\n\r\n'));
      events.addAll(parser.addChunk(': ping\n\n'));
      events.addAll(parser.addChunk('event: message_end\ndata: {"a":1}\n\n'));

      expect(events.length, 2);
      expect(events[0].event, 'text_delta');
      expect(jsonDecode(events[0].data), {'type': 'text_delta', 'text': '你'});
      expect(events[1].event, 'message_end');
    });

    test('多行 data 按 SSE 规范用换行拼接', () {
      final parser = SseStreamParser();
      final events = parser.addChunk('event: x\ndata: line1\ndata: line2\n\n').toList();
      expect(events.single.data, 'line1\nline2');
    });

    test('流结束没有空行收尾时,flush 仍吐出最后一个事件', () {
      final parser = SseStreamParser();
      expect(parser.addChunk('event: text_delta\ndata: {"text":"尾"}'), isEmpty);
      final events = parser.flush().toList();
      expect(events.single.event, 'text_delta');
    });

    test('只有注释行时不产生事件', () {
      final parser = SseStreamParser();
      expect(parser.addChunk(': ping\n\n').toList(), isEmpty);
    });
  });

  group('DpappEvent', () {
    test('message_start 带 user_message_id(与 server schema 同步)', () {
      final event = DpappEvent.fromJson({
        'type': 'message_start',
        'message_id': 'm-1',
        'user_message_id': 'u-1',
        'model': 'deepseek-flash',
      });
      expect(event, isA<MessageStartEvent>());
      final start = event! as MessageStartEvent;
      expect(start.messageId, 'm-1');
      expect(start.userMessageId, 'u-1');
    });

    test('message_end 的 stop_reason 三值都能解析', () {
      for (final reason in ['end_turn', 'interrupted', 'error']) {
        final event = DpappEvent.fromJson({
          'type': 'message_end',
          'usage': {'tokens_in': 3, 'tokens_out': 4},
          'cost_estimate': 0.001,
          'stop_reason': reason,
        });
        expect(event, isA<MessageEndEvent>());
        expect((event! as MessageEndEvent).stopReason, reason);
      }
    });

    test('未知事件返回 null,不抛异常(向前兼容)', () {
      expect(DpappEvent.fromJson({'type': 'future_event'}), isNull);
      expect(DpappEvent.fromJson({'type': 'error', 'code': 'x', 'message': 'y'}), isA<DpappErrorEvent>());
    });
  });

  // M2 协议扩展:工具结果、引用偏移、标题、扩展 usage
  group('M2 事件', () {
    test('tool_result 带来源列表与 call_id', () {
      final event = DpappEvent.fromJson({
        'type': 'tool_result',
        'tool': 'deepseek_web_search',
        'call_id': 'call-1',
        'status': 'completed',
        'summary': '搜索「鲸灵」 → 1 条结果',
        'results': [
          {'title': '结果A', 'url': 'https://example.com/a', 'site_name': 'example.com', 'snippet': '摘要'},
        ],
      });
      final result = event! as ToolResultEvent;
      expect(result.results.length, 1);
      expect(result.results.first.siteName, 'example.com');
      expect(result.callId, 'call-1');
    });

    test('citation 带正文字符偏移', () {
      final event = DpappEvent.fromJson({
        'type': 'citation',
        'index': 1,
        'url': 'https://example.com/a',
        'title': '结果A',
        'start_index': 0,
        'end_index': 8,
      })! as CitationEvent;
      expect(event.startIndex, 0);
      expect(event.endIndex, 8);
    });

    test('title 事件与扩展 usage', () {
      expect((DpappEvent.fromJson({'type': 'title', 'title': '鲸灵与搜索'})! as TitleEvent).title, '鲸灵与搜索');
      final end = DpappEvent.fromJson({
        'type': 'message_end',
        'usage': {'tokens_in': 100, 'tokens_out': 20, 'tokens_cached': 40, 'search_calls': 3, 'fetch_calls': 1},
        'cost_estimate': 0.01,
        'stop_reason': 'end_turn',
      })! as MessageEndEvent;
      expect(end.usage.tokensCached, 40);
      expect(end.usage.searchCalls, 3);
      expect(end.usage.fetchCalls, 1);
    });

    test('refusal 也是合法终止原因', () {
      final end = DpappEvent.fromJson({
        'type': 'message_end',
        'usage': {'tokens_in': 1, 'tokens_out': 1},
        'cost_estimate': 0,
        'stop_reason': 'refusal',
      })! as MessageEndEvent;
      expect(end.stopReason, 'refusal');
    });

    test('safety_block 带 source:区分输入被拦与模型拒答', () {
      final input = DpappEvent.fromJson({
        'type': 'safety_block',
        'reason': '输入内容未通过安全审核',
      })! as SafetyBlockEvent;
      expect(input.source, 'input', reason: '老服务端不带 source 时按 input 处理');

      final output = DpappEvent.fromJson({
        'type': 'safety_block',
        'reason': '模型以内容安全为由拒答',
        'source': 'output',
      })! as SafetyBlockEvent;
      expect(output.source, 'output');
      expect(output.reason, contains('拒答'));
    });

    test('MessageNode 解析落库的 safety 标识(历史消息也带拒答标记)', () {
      final node = MessageNode.fromJson({
        'id': 'm1',
        'parent_id': 'u1',
        'role': 'assistant',
        'blocks': [
          {'type': 'text', 'text': '抱歉,我无法提供这类信息。'},
        ],
        'thinking': '',
        'citations': <Object>[],
        'tool_traces': <Object>[],
        'usage': {'tokens_in': 3, 'tokens_out': 9, 'cost': 0.001},
        'stop_reason': 'refusal',
        'safety': {'source': 'output', 'reason': '模型以内容安全为由拒答'},
        'children': <Object>[],
      });
      expect(node.safety, isNotNull);
      expect(node.safety!.isOutput, isTrue);
      expect(node.text, contains('无法提供'));

      final plain = MessageNode.fromJson({
        'id': 'm2',
        'parent_id': null,
        'role': 'assistant',
        'blocks': [
          {'type': 'text', 'text': '正常回答'},
        ],
        'children': <Object>[],
      });
      expect(plain.safety, isNull);
    });
  });
}
