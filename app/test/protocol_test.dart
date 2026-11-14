import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:jingling/core/sse_client.dart';
import 'package:jingling/models/events.dart';

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
}
