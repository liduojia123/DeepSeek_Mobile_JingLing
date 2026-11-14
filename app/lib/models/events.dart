/// DPAPP SSE 事件模型 —— 与 server/src/deepseek/events.ts(zod schema)逐字段同步。
/// 修改任何一侧都必须同步另一侧,否则客户端会静默丢事件。
///
/// 线上编码:每行 `event: <type>` + `data: <JSON,含 type 字段>`,空行分块;
/// 服务端每 15s 会发一行 `: ping` 注释,解析层必须忽略。
library;

class DpappUsage {
  const DpappUsage({required this.tokensIn, required this.tokensOut});

  final int tokensIn;
  final int tokensOut;

  factory DpappUsage.fromJson(Map<String, dynamic> json) => DpappUsage(
        tokensIn: _asInt(json['tokens_in']) ?? 0,
        tokensOut: _asInt(json['tokens_out']) ?? 0,
      );
}

sealed class DpappEvent {
  const DpappEvent();

  /// 未知 type 返回 null 而不是抛异常:服务端以后加事件时旧客户端不应崩。
  static DpappEvent? fromJson(Map<String, dynamic> json) {
    final type = json['type'];
    if (type is! String) return null;

    switch (type) {
      case 'message_start':
        return MessageStartEvent(
          messageId: _asString(json['message_id']) ?? '',
          userMessageId: _asString(json['user_message_id']),
          model: _asString(json['model']) ?? '',
        );
      case 'thinking_delta':
        return ThinkingDeltaEvent(text: _asString(json['text']) ?? '');
      case 'thinking_end':
        return const ThinkingEndEvent();
      case 'tool_progress':
        return ToolProgressEvent(
          tool: _asString(json['tool']) ?? '',
          phase: _asString(json['phase']) ?? '',
          query: _asString(json['query']),
        );
      case 'tool_result':
        return ToolResultEvent(
          tool: _asString(json['tool']) ?? '',
          summary: _asString(json['summary']) ?? '',
          results: _asList(json['results'])
              .map((item) => ToolResultEntry.fromJson(item))
              .toList(growable: false),
        );
      case 'text_delta':
        return TextDeltaEvent(text: _asString(json['text']) ?? '');
      case 'citation':
        return CitationEvent(
          index: _asInt(json['index']) ?? 0,
          url: _asString(json['url']) ?? '',
          title: _asString(json['title']) ?? '',
        );
      case 'file_attached':
        return FileAttachedEvent(
          fileId: _asString(json['file_id']) ?? '',
          name: _asString(json['name']) ?? '',
          status: _asString(json['status']) ?? 'pending',
        );
      case 'safety_block':
        return SafetyBlockEvent(reason: _asString(json['reason']) ?? '');
      case 'message_end':
        return MessageEndEvent(
          usage: DpappUsage.fromJson(_asMap(json['usage'])),
          costEstimate: _asDouble(json['cost_estimate']) ?? 0,
          stopReason: _asString(json['stop_reason']) ?? 'end_turn',
        );
      case 'error':
        return DpappErrorEvent(
          code: _asString(json['code']) ?? 'error',
          message: _asString(json['message']) ?? '未知错误',
        );
      default:
        return null;
    }
  }
}

final class MessageStartEvent extends DpappEvent {
  const MessageStartEvent({required this.messageId, required this.userMessageId, required this.model});

  final String messageId;
  final String? userMessageId;
  final String model;
}

final class ThinkingDeltaEvent extends DpappEvent {
  const ThinkingDeltaEvent({required this.text});
  final String text;
}

final class ThinkingEndEvent extends DpappEvent {
  const ThinkingEndEvent();
}

final class ToolProgressEvent extends DpappEvent {
  const ToolProgressEvent({required this.tool, required this.phase, this.query});
  final String tool;
  final String phase;
  final String? query;
}

final class ToolResultEntry {
  const ToolResultEntry({required this.title, required this.url, this.site});

  final String title;
  final String url;
  final String? site;

  factory ToolResultEntry.fromJson(Map<String, dynamic> json) => ToolResultEntry(
        title: _asString(json['title']) ?? '',
        url: _asString(json['url']) ?? '',
        site: _asString(json['site']),
      );
}

final class ToolResultEvent extends DpappEvent {
  const ToolResultEvent({required this.tool, required this.summary, required this.results});
  final String tool;
  final String summary;
  final List<ToolResultEntry> results;
}

final class TextDeltaEvent extends DpappEvent {
  const TextDeltaEvent({required this.text});
  final String text;
}

final class CitationEvent extends DpappEvent {
  const CitationEvent({required this.index, required this.url, required this.title});
  final int index;
  final String url;
  final String title;
}

final class FileAttachedEvent extends DpappEvent {
  const FileAttachedEvent({required this.fileId, required this.name, required this.status});
  final String fileId;
  final String name;
  final String status;
}

final class SafetyBlockEvent extends DpappEvent {
  const SafetyBlockEvent({required this.reason});
  final String reason;
}

final class MessageEndEvent extends DpappEvent {
  const MessageEndEvent({required this.usage, required this.costEstimate, required this.stopReason});
  final DpappUsage usage;
  final double costEstimate;
  final String stopReason;
}

final class DpappErrorEvent extends DpappEvent {
  const DpappErrorEvent({required this.code, required this.message});
  final String code;
  final String message;
}

// ---------- JSON 宽容读取 ----------

String? _asString(Object? value) => value is String ? value : null;

int? _asInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return null;
}

double? _asDouble(Object? value) {
  if (value is num) return value.toDouble();
  return null;
}

Map<String, dynamic> _asMap(Object? value) =>
    value is Map ? Map<String, dynamic>.from(value) : const {};

List<Map<String, dynamic>> _asList(Object? value) => value is List
    ? value.whereType<Map>().map((item) => Map<String, dynamic>.from(item)).toList(growable: false)
    : const [];
