/// dsh 会话级流(手机与电脑共用同一个会话)。
///
/// 与 `server/src/routes/harness.ts` 的 `/v1/harness/sessions/:id/stream` 对应:
/// - 持久事件 `harness_session_event`:时间线(用户/助手/工具),`seq` 用于断线续传;
/// - 瞬时事件 `harness_session_live`:打字增量、状态、排队提示,不落库;
/// - `harness_session_ready`:首帧,带 last_seq/status/permission。
library;

sealed class HarnessStreamEvent {
  const HarnessStreamEvent({required this.sessionId});

  final String sessionId;
}

/// 首帧:告诉客户端从哪里续传、电脑上的会话现在是什么状态。
final class HarnessSessionReady extends HarnessStreamEvent {
  const HarnessSessionReady({
    required super.sessionId,
    required this.lastSeq,
    required this.status,
    this.permission,
    this.model,
  });

  final int lastSeq;
  final String status;
  final String? permission;
  final String? model;

  bool get running => status == 'running';
}

/// 持久事件(可重放):kind ∈ user_message / assistant_message / tool_call / tool_result / turn_start / turn_end
final class HarnessSessionEvent extends HarnessStreamEvent {
  const HarnessSessionEvent({
    required super.sessionId,
    required this.seq,
    required this.kind,
    required this.payload,
    this.dshSeq,
  });

  final int seq;
  final int? dshSeq;
  final String kind;
  final Map<String, dynamic> payload;

  factory HarnessSessionEvent.fromJson(Map<String, dynamic> json) => HarnessSessionEvent(
        sessionId: (json['session_id'] as String?) ?? '',
        seq: (json['seq'] as num?)?.toInt() ?? 0,
        dshSeq: (json['dsh_seq'] as num?)?.toInt(),
        kind: (json['kind'] as String?) ?? '',
        payload: json['payload'] is Map ? Map<String, dynamic>.from(json['payload'] as Map) : const {},
      );
}

/// 瞬时事件:打字增量 / 状态 / 输入排队 / 手机输入回显 / 错误
final class HarnessSessionLive extends HarnessStreamEvent {
  const HarnessSessionLive({
    required super.sessionId,
    required this.kind,
    this.text,
    this.status,
    this.action,
    this.mode,
    this.message,
  });

  final String kind;
  final String? text;
  final String? status;
  final String? action;
  final String? mode;
  final String? message;

  factory HarnessSessionLive.fromJson(Map<String, dynamic> json) => HarnessSessionLive(
        sessionId: (json['session_id'] as String?) ?? '',
        kind: (json['kind'] as String?) ?? '',
        text: json['text'] as String?,
        status: json['status'] as String?,
        action: json['action'] as String?,
        mode: json['mode'] as String?,
        message: json['message'] as String?,
      );
}

/// 会话里一次工具调用(参数/结果都在这里,手机上可展开)。
class HarnessToolCall {
  HarnessToolCall({
    required this.callId,
    required this.name,
    required this.arguments,
    this.result,
    this.isError = false,
  });

  final String callId;
  final String name;
  final String arguments;
  String? result;
  bool isError;

  bool get done => result != null;
}

sealed class HarnessEntry {
  const HarnessEntry();
}

/// 一条用户消息。source=jingling 表示从手机发的,user 表示在电脑上打的。
final class HarnessUserEntry extends HarnessEntry {
  const HarnessUserEntry({required this.text, required this.source});

  final String text;
  final String source;

  bool get fromPhone => source == 'jingling';
}

final class HarnessAssistantEntry extends HarnessEntry {
  HarnessAssistantEntry({
    required this.text,
    required this.reasoning,
    required this.tools,
    this.interrupted = false,
  });

  final String text;
  final String reasoning;
  final List<HarnessToolCall> tools;
  final bool interrupted;
}

/// 会话时间线:把事件流折叠成手机上要渲染的条目(纯逻辑,便于单测)。
class HarnessTimeline {
  final List<HarnessEntry> entries = [];
  final Map<String, HarnessToolCall> _toolsByCallId = {};
  final Set<int> _seenSeqs = {};
  /// tool_call 早于 assistant_message 到达时先挂在这里,助手消息落地后再挂上去
  final List<HarnessToolCall> _orphanTools = [];

  /// 正在流式到达的助手内容(持久 assistant_message 到达后清空)
  String draftText = '';
  String draftReasoning = '';

  /// 手机刚发出、还没在持久事件里落地的输入(本地回显)
  String? pendingInput;

  bool running = false;

  int lastSeq = 0;

  /// 应用一条持久事件;返回是否真的改变了时间线(重复 seq 直接忽略)。
  bool applyEvent(HarnessSessionEvent event) {
    if (event.seq > lastSeq) lastSeq = event.seq;
    // 服务端 seq 单调;同一 seq 重复到达(重连补发)时幂等
    if (event.seq > 0 && !_seenSeqs.add(event.seq)) return false;

    switch (event.kind) {
      case 'user_message':
        final text = (event.payload['text'] as String?) ?? '';
        if (text.trim().isEmpty) return false;
        pendingInput = null;
        entries.add(HarnessUserEntry(
          text: text,
          source: (event.payload['source'] as String?) ?? 'user',
        ));
        // 用户开口 = 新的一轮:上一轮的流式草稿已落库的不再叠加
        draftText = '';
        draftReasoning = '';
        running = true;
        return true;

      case 'assistant_message':
        final text = (event.payload['text'] as String?) ?? '';
        final reasoning = (event.payload['reasoning'] as String?) ?? '';
        final tools = <HarnessToolCall>[];
        for (final raw in (event.payload['tools'] as List?) ?? const []) {
          if (raw is! Map) continue;
          tools.add(_toolFor(
            callId: (raw['call_id'] as String?) ?? '',
            name: (raw['name'] as String?) ?? 'tool',
            arguments: (raw['arguments'] as String?) ?? '',
          ));
        }
        if (text.trim().isEmpty && reasoning.trim().isEmpty && tools.isEmpty) return false;
        // 之前先到的工具调用现在有归属了
        tools.addAll(_orphanTools);
        _orphanTools.clear();
        entries.add(HarnessAssistantEntry(
          text: text,
          reasoning: reasoning,
          tools: tools,
          interrupted: event.payload['interrupted'] == true,
        ));
        draftText = '';
        draftReasoning = '';
        return true;

      case 'tool_call':
        _ensureTool(
          callId: (event.payload['call_id'] as String?) ?? '',
          name: (event.payload['name'] as String?) ?? 'tool',
          arguments: (event.payload['arguments'] as String?) ?? '',
        );
        return true;

      case 'tool_result':
        final callId = (event.payload['call_id'] as String?) ?? '';
        final text = (event.payload['text'] as String?) ?? '';
        final isError = event.payload['is_error'] == true;
        final existing = _toolsByCallId[callId];
        if (existing != null) {
          existing
            ..result = text
            ..isError = isError;
          return true;
        }
        // 没找到调用记录(历史被压缩等):单独补一条,避免结果丢失
        _ensureTool(
          callId: callId,
          name: (event.payload['name'] as String?) ?? 'tool',
          arguments: '',
        ).result = text;
        return true;

      case 'turn_start':
        running = true;
        return true;

      case 'turn_end':
        running = false;
        draftText = '';
        draftReasoning = '';
        return true;
    }
    return false;
  }

  /// 应用一条瞬时事件;返回是否需要重绘。
  bool applyLive(HarnessSessionLive event) {
    switch (event.kind) {
      case 'text':
        draftText += event.text ?? '';
        return true;
      case 'reasoning':
        draftReasoning += event.text ?? '';
        return true;
      case 'status':
        running = event.status == 'running';
        return true;
      case 'input_echo':
        pendingInput = event.text;
        return true;
      case 'inbox':
        // inserted/claimed/discarded:排队状态,UI 只用 pendingInput 表示
        if (event.action == 'discarded') pendingInput = null;
        return true;
      case 'error':
        return false;
    }
    return false;
  }

  /// 登记/复用一次工具调用(只进索引,不挂到消息上)
  HarnessToolCall _toolFor({required String callId, required String name, required String arguments}) {
    final existing = _toolsByCallId[callId];
    if (existing != null) return existing;
    final call = HarnessToolCall(callId: callId, name: name, arguments: arguments);
    _toolsByCallId[callId] = call;
    return call;
  }

  /// tool_call 事件:登记后挂到最近一条助手消息;还没有助手消息时先当孤儿
  HarnessToolCall _ensureTool({required String callId, required String name, required String arguments}) {
    final existing = _toolsByCallId[callId];
    if (existing != null) return existing;
    final call = _toolFor(callId: callId, name: name, arguments: arguments);
    HarnessAssistantEntry? lastAssistant;
    for (final entry in entries.reversed) {
      if (entry is HarnessAssistantEntry) {
        lastAssistant = entry;
        break;
      }
    }
    if (lastAssistant != null) {
      lastAssistant.tools.add(call);
    } else {
      _orphanTools.add(call);
    }
    return call;
  }

  bool get isEmpty => entries.isEmpty && draftText.isEmpty && draftReasoning.isEmpty;
}
