/// 会话列表项(GET /v1/conversations)。
class Conversation {
  const Conversation({
    required this.id,
    required this.title,
    required this.pinned,
    required this.ephemeral,
    required this.activeLeafId,
    required this.preview,
    required this.updatedAt,
  });

  final String id;
  final String title;
  final bool pinned;
  final bool ephemeral;
  final String? activeLeafId;
  final String preview;
  final String updatedAt;

  factory Conversation.fromJson(Map<String, dynamic> json) => Conversation(
        id: json['id'] as String,
        title: (json['title'] as String?) ?? '',
        pinned: json['pinned'] == true,
        ephemeral: json['ephemeral'] == true,
        activeLeafId: json['active_leaf_id'] as String?,
        preview: (json['preview'] as String?) ?? '',
        updatedAt: (json['updated_at'] as String?) ?? '',
      );

  String get displayTitle => title.trim().isEmpty ? '新对话' : title;
}

/// 内容安全标识(input=输入被拦截 / output=模型拒答),由服务端启发式识别后下发并落库。
class SafetyFlag {
  const SafetyFlag({required this.source, required this.reason});

  final String source;
  final String reason;

  bool get isOutput => source == 'output';

  factory SafetyFlag.fromJson(Map<String, dynamic> json) => SafetyFlag(
        source: (json['source'] as String?) ?? 'input',
        reason: (json['reason'] as String?) ?? '',
      );
}

class Citation {
  const Citation({
    required this.index,
    required this.title,
    required this.url,
    this.startIndex,
    this.endIndex,
  });

  final int index;
  final String title;
  final String url;

  /// 正文里的字符偏移(相对本轮正文);有值才渲染角标
  final int? startIndex;
  final int? endIndex;

  factory Citation.fromJson(Map<String, dynamic> json) => Citation(
        index: (json['index'] as num?)?.toInt() ?? 0,
        title: (json['title'] as String?) ?? '',
        url: (json['url'] as String?) ?? '',
        startIndex: (json['start_index'] as num?)?.toInt(),
        endIndex: (json['end_index'] as num?)?.toInt(),
      );
}

class ToolTraceResult {
  const ToolTraceResult({
    required this.title,
    required this.url,
    this.siteName,
    this.snippet,
  });

  final String title;
  final String url;
  final String? siteName;
  final String? snippet;

  factory ToolTraceResult.fromJson(Map<String, dynamic> json) => ToolTraceResult(
        title: (json['title'] as String?) ?? '',
        url: (json['url'] as String?) ?? '',
        siteName: (json['site_name'] as String?) ?? (json['site'] as String?),
        snippet: json['snippet'] as String?,
      );
}

/// 工具调用留痕(入参/出参/耗时),M2 起有真实数据。
class ToolTrace {
  const ToolTrace({
    required this.tool,
    required this.summary,
    this.callId,
    this.status,
    this.durationMs,
    this.results = const [],
  });

  final String tool;
  final String summary;
  final String? callId;
  final String? status;
  final int? durationMs;
  final List<ToolTraceResult> results;

  factory ToolTrace.fromJson(Map<String, dynamic> json) => ToolTrace(
        tool: (json['tool'] as String?) ?? '',
        summary: (json['summary'] as String?) ?? '',
        callId: json['call_id'] as String?,
        status: json['status'] as String?,
        durationMs: (json['duration_ms'] as num?)?.toInt(),
        results: ((json['results'] as List?) ?? const [])
            .whereType<Map>()
            .map((item) => ToolTraceResult.fromJson(Map<String, dynamic>.from(item)))
            .toList(growable: false),
      );
}

/// 消息树节点。parent_id 构成分支,children 由服务端返回的树直接填充。
class MessageNode {
  MessageNode({
    required this.id,
    required this.parentId,
    required this.role,
    required this.text,
    required this.thinking,
    required this.citations,
    required this.toolTraces,
    required this.tokensIn,
    required this.tokensOut,
    required this.cost,
    required this.stopReason,
    required this.children,
    this.safety,
  });

  final String id;
  final String? parentId;
  final String role;
  final String text;
  final String thinking;
  final List<Citation> citations;
  final List<ToolTrace> toolTraces;
  final int tokensIn;
  final int tokensOut;
  final double cost;
  final String? stopReason;
  final List<MessageNode> children;

  /// 命内容安全时的结构化标识(普通回答为 null);output 表示模型自己拒答
  final SafetyFlag? safety;

  bool get isUser => role == 'user';
  bool get isAssistant => role == 'assistant';
  bool get isEmptyAssistant => isAssistant && text.trim().isEmpty;
  bool get interrupted => stopReason == 'interrupted' || stopReason == 'error';

  factory MessageNode.fromJson(Map<String, dynamic> json) {
    final children = (json['children'] as List?) ?? const [];
    final usage = (json['usage'] as Map?) ?? const {};
    return MessageNode(
      id: json['id'] as String,
      parentId: json['parent_id'] as String?,
      role: (json['role'] as String?) ?? 'assistant',
      text: _blocksToText(json['blocks']),
      thinking: (json['thinking'] as String?) ?? '',
      citations: ((json['citations'] as List?) ?? const [])
          .whereType<Map>()
          .map((item) => Citation.fromJson(Map<String, dynamic>.from(item)))
          .toList(growable: false),
      toolTraces: ((json['tool_traces'] as List?) ?? const [])
          .whereType<Map>()
          .map((item) => ToolTrace.fromJson(Map<String, dynamic>.from(item)))
          .toList(growable: false),
      tokensIn: (usage['tokens_in'] as num?)?.toInt() ?? 0,
      tokensOut: (usage['tokens_out'] as num?)?.toInt() ?? 0,
      cost: (usage['cost'] as num?)?.toDouble() ?? 0,
      stopReason: json['stop_reason'] as String?,
      safety: json['safety'] is Map
          ? SafetyFlag.fromJson(Map<String, dynamic>.from(json['safety'] as Map))
          : null,
      children: children
          .whereType<Map>()
          .map((item) => MessageNode.fromJson(Map<String, dynamic>.from(item)))
          .toList(),
    );
  }
}

String _blocksToText(Object? blocks) {
  if (blocks is! List) return '';
  final buffer = StringBuffer();
  for (final block in blocks) {
    if (block is Map && block['type'] == 'text' && block['text'] is String) {
      buffer.write(block['text'] as String);
    }
  }
  return buffer.toString();
}

/// GET /v1/conversations/{id}:全树 + 活跃路径(根→叶的 id 列表)。
class ConversationDetail {
  ConversationDetail({
    required this.conversation,
    required this.tree,
    required this.path,
  })  : _byId = _index(tree),
        _childrenByParent = _indexChildren(tree);

  final Conversation conversation;
  final List<MessageNode> tree;

  /// 根→叶的消息 id;客户端按它渲染线性对话
  final List<String> path;
  final Map<String, MessageNode> _byId;
  final Map<String, List<MessageNode>> _childrenByParent;

  factory ConversationDetail.fromJson(Map<String, dynamic> json) {
    final conversationJson = Map<String, dynamic>.from(json);
    conversationJson['preview'] = '';
    return ConversationDetail(
      conversation: Conversation.fromJson(conversationJson),
      tree: ((json['tree'] as List?) ?? const [])
          .whereType<Map>()
          .map((item) => MessageNode.fromJson(Map<String, dynamic>.from(item)))
          .toList(),
      path: ((json['path'] as List?) ?? const []).whereType<String>().toList(growable: false),
    );
  }

  List<MessageNode> get pathNodes =>
      path.map((id) => _byId[id]).whereType<MessageNode>().toList(growable: false);

  MessageNode? nodeById(String id) => _byId[id];

  /// 同一位置的全部版本(用于 `‹ n/m ›` 切换器)。根节点取森林顶层。
  List<MessageNode> siblingsOf(String nodeId) {
    final node = _byId[nodeId];
    if (node == null) return const [];
    if (node.parentId == null) return tree;
    return _childrenByParent[node.parentId!] ?? [node];
  }

  /// 切到某个兄弟分支时,活跃叶子应落在它子树里最深的那条(取最新的子节点)。
  String deepestLeafUnder(MessageNode node) {
    var current = node;
    while (current.children.isNotEmpty) {
      current = current.children.last;
    }
    return current.id;
  }

  bool get isEmpty => tree.isEmpty;

  static Map<String, MessageNode> _index(List<MessageNode> tree) {
    final map = <String, MessageNode>{};
    void visit(MessageNode node) {
      map[node.id] = node;
      for (final child in node.children) {
        visit(child);
      }
    }

    for (final root in tree) {
      visit(root);
    }
    return map;
  }

  static Map<String, List<MessageNode>> _indexChildren(List<MessageNode> tree) {
    final map = <String, List<MessageNode>>{};
    // 必须递归:分支点几乎总是在树中间(用户消息挂在某条助手消息下),
    // 只索引根节点的 children 会让 `‹ n/m ›` 永远不出现。
    void visit(MessageNode node) {
      map[node.id] = node.children;
      for (final child in node.children) {
        visit(child);
      }
    }

    for (final root in tree) {
      visit(root);
    }
    return map;
  }
}

/// 已配对设备(GET /v1/devices)。令牌只在配对时出现一次,这里拿不到任何令牌。
class Device {
  const Device({
    required this.id,
    required this.name,
    required this.pairedAt,
    required this.current,
    this.lastSeen,
  });

  final String id;
  final String name;
  final String pairedAt;
  final String? lastSeen;

  /// 是否是当前这台手机的设备记录
  final bool current;

  factory Device.fromJson(Map<String, dynamic> json) => Device(
        id: (json['id'] as String?) ?? '',
        name: (json['name'] as String?) ?? '',
        pairedAt: (json['paired_at'] as String?) ?? '',
        lastSeen: json['last_seen'] as String?,
        current: json['current'] == true,
      );
}

/// 上传完成的文档引用(服务端 file_id)。
class FileUploadResult {
  const FileUploadResult({
    required this.fileId,
    required this.name,
    required this.size,
    required this.purpose,
    required this.status,
  });

  final String fileId;
  final String name;
  final int size;
  final String purpose;
  final String status;

  factory FileUploadResult.fromJson(Map<String, dynamic> json) => FileUploadResult(
        fileId: (json['file_id'] as String?) ?? '',
        name: (json['name'] as String?) ?? '',
        size: (json['size'] as num?)?.toInt() ?? 0,
        purpose: (json['purpose'] as String?) ?? 'text_recognition',
        status: (json['status'] as String?) ?? 'parsed',
      );
}

/// 对话里挂着的附件(已上传,待发送)。
class ChatFile {
  const ChatFile({required this.id, required this.name});

  final String id;
  final String name;
}

class PairResult {
  const PairResult({required this.deviceId, required this.deviceName, required this.token});

  final String deviceId;
  final String deviceName;
  final String token;

  factory PairResult.fromJson(Map<String, dynamic> json) => PairResult(
        deviceId: (json['device_id'] as String?) ?? '',
        deviceName: (json['device_name'] as String?) ?? '',
        token: (json['token'] as String?) ?? '',
      );
}

class UsageDay {
  const UsageDay({
    required this.date,
    required this.calls,
    required this.tokensIn,
    required this.tokensOut,
    required this.cost,
  });

  final String date;
  final int calls;
  final int tokensIn;
  final int tokensOut;
  final double cost;
}

class UsageKindRow {
  const UsageKindRow({required this.kind, required this.calls, required this.quantity, required this.cost});

  final String kind;
  final int calls;
  final double quantity;
  final double cost;
}

class UsageTopConversation {
  const UsageTopConversation({required this.title, required this.cost, required this.calls});

  final String title;
  final double cost;
  final int calls;
}

class UsageSummary {
  const UsageSummary({
    required this.days,
    required this.calls,
    required this.tokensIn,
    required this.tokensOut,
    required this.cost,
    this.byKind = const [],
    this.topConversations = const [],
    this.todayCost = 0,
    this.todayTokensIn = 0,
    this.todayTokensOut = 0,
    this.toolCalls = 0,
    this.budgetDaily = 0,
    this.budgetUsedToday = 0,
    this.budgetRemaining,
    this.budgetUsedPercent = 0,
    this.budgetExceeded = false,
  });

  final List<UsageDay> days;
  final int calls;
  final int tokensIn;
  final int tokensOut;
  final double cost;
  final List<UsageKindRow> byKind;
  final List<UsageTopConversation> topConversations;
  final double todayCost;
  final int todayTokensIn;
  final int todayTokensOut;
  final int toolCalls;
  final double budgetDaily;
  final double budgetUsedToday;
  final double? budgetRemaining;
  final int budgetUsedPercent;
  final bool budgetExceeded;

  factory UsageSummary.fromJson(Map<String, dynamic> json) {
    final totals = (json['totals'] as Map?) ?? const {};
    return UsageSummary(
      days: ((json['days'] as List?) ?? const [])
          .whereType<Map>()
          .map((item) => UsageDay(
                date: (item['date'] as String?) ?? '',
                calls: (item['calls'] as num?)?.toInt() ?? 0,
                tokensIn: (item['tokens_in'] as num?)?.toInt() ?? 0,
                tokensOut: (item['tokens_out'] as num?)?.toInt() ?? 0,
                cost: (item['cost'] as num?)?.toDouble() ?? 0,
              ))
          .toList(growable: false),
      calls: (totals['calls'] as num?)?.toInt() ?? 0,
      tokensIn: (totals['tokens_in'] as num?)?.toInt() ?? 0,
      tokensOut: (totals['tokens_out'] as num?)?.toInt() ?? 0,
      cost: (totals['cost'] as num?)?.toDouble() ?? 0,
      byKind: ((json['by_kind'] as List?) ?? const [])
          .whereType<Map>()
          .map((item) => UsageKindRow(
                kind: (item['kind'] as String?) ?? '',
                calls: (item['calls'] as num?)?.toInt() ?? 0,
                quantity: (item['quantity'] as num?)?.toDouble() ?? 0,
                cost: (item['cost'] as num?)?.toDouble() ?? 0,
              ))
          .toList(growable: false),
      topConversations: ((json['top_conversations'] as List?) ?? const [])
          .whereType<Map>()
          .map((item) => UsageTopConversation(
                title: (item['title'] as String?) ?? '(无标题)',
                cost: (item['cost'] as num?)?.toDouble() ?? 0,
                calls: (item['calls'] as num?)?.toInt() ?? 0,
              ))
          .toList(growable: false),
      todayCost: ((json['today'] as Map?)?['cost'] as num?)?.toDouble() ?? 0,
      todayTokensIn: ((json['today'] as Map?)?['tokens_in'] as num?)?.toInt() ?? 0,
      todayTokensOut: ((json['today'] as Map?)?['tokens_out'] as num?)?.toInt() ?? 0,
      toolCalls: (json['tool_calls'] as num?)?.toInt() ?? 0,
      budgetDaily: ((json['budget'] as Map?)?['daily_cny'] as num?)?.toDouble() ?? 0,
      budgetUsedToday: ((json['budget'] as Map?)?['used_today'] as num?)?.toDouble() ?? 0,
      budgetRemaining: ((json['budget'] as Map?)?['remaining_cny'] as num?)?.toDouble(),
      budgetUsedPercent: ((json['budget'] as Map?)?['used_percent'] as num?)?.toInt() ?? 0,
      budgetExceeded: ((json['budget'] as Map?)?['exceeded'] ?? false) == true,
    );
  }
}

/// 让 UI 少写分支:引用列表和工具留痕都可能有事件流里的临时态。
class StreamingAnswer {
  const StreamingAnswer({
    required this.thinking,
    required this.text,
    required this.citations,
    required this.toolTraces,
  });

  final String thinking;
  final String text;
  final List<Citation> citations;
  final List<ToolTrace> toolTraces;

  static const empty = StreamingAnswer(thinking: '', text: '', citations: [], toolTraces: []);

  bool get hasContent => thinking.trim().isNotEmpty || text.trim().isNotEmpty;
}

/// M5 记忆:memory 工具沉淀的一条个人记忆。
class MemoryNote {
  const MemoryNote({
    required this.id,
    required this.content,
    required this.tags,
    required this.updatedAt,
  });

  final String id;
  final String content;
  final List<String> tags;
  final String updatedAt;

  factory MemoryNote.fromJson(Map<String, dynamic> json) => MemoryNote(
        id: (json['id'] as String?) ?? '',
        content: (json['content'] as String?) ?? '',
        tags: ((json['tags'] as List?) ?? const []).whereType<String>().toList(growable: false),
        updatedAt: (json['updated_at'] as String?) ?? '',
      );
}
/// OTA:服务器上发布的 App 版本。
class AppRelease {
  const AppRelease({
    required this.versionCode,
    required this.versionName,
    required this.notes,
    required this.size,
    required this.downloadPath,
  });

  final int versionCode;
  final String versionName;
  final String notes;
  final int size;
  final String downloadPath;

  factory AppRelease.fromJson(Map<String, dynamic> json) => AppRelease(
        versionCode: (json['version_code'] as num?)?.toInt() ?? 0,
        versionName: (json['version_name'] as String?) ?? '',
        notes: (json['notes'] as String?) ?? '',
        size: (json['size'] as num?)?.toInt() ?? 0,
        downloadPath: (json['download_path'] as String?) ?? '/v1/app/download',
      );
}

/// 全局搜索(HANDOFF-SEARCH)的一条命中。
/// `field == 'title'` 时 message_id 为 null、snippet 为空;否则是正文命中。
class SearchHit {
  const SearchHit({
    required this.messageId,
    required this.field,
    required this.role,
    required this.createdAt,
    required this.snippet,
  });

  final String? messageId;
  final String field;
  final String? role;
  final String createdAt;
  final String snippet;

  bool get isTitleHit => field == 'title';

  factory SearchHit.fromJson(Map<String, dynamic> json) => SearchHit(
        messageId: json['message_id'] as String?,
        field: (json['field'] as String?) ?? 'message',
        role: json['role'] as String?,
        createdAt: (json['created_at'] as String?) ?? '',
        snippet: (json['snippet'] as String?) ?? '',
      );
}

/// 全局搜索里一个会话的命中组。
class SearchGroup {
  const SearchGroup({
    required this.conversationId,
    required this.title,
    required this.pinned,
    required this.updatedAt,
    required this.hits,
  });

  final String conversationId;
  final String title;
  final bool pinned;
  final String updatedAt;
  final List<SearchHit> hits;

  factory SearchGroup.fromJson(Map<String, dynamic> json) {
    final conversation = (json['conversation'] as Map?) ?? const {};
    final hits = (json['hits'] as List?) ?? const [];
    return SearchGroup(
      conversationId: (conversation['id'] as String?) ?? '',
      title: (conversation['title'] as String?) ?? '',
      pinned: (conversation['pinned'] as bool?) ?? false,
      updatedAt: (conversation['updated_at'] as String?) ?? '',
      hits: hits.whereType<Map>().map((item) => SearchHit.fromJson(Map<String, dynamic>.from(item))).toList(growable: false),
    );
  }
}

/// v1.5.3:个人 DeepSeek API Key 状态。`hint` 只有尾号,服务端绝不回全文。
class ModelKeyStatus {
  const ModelKeyStatus({required this.source, required this.hint});

  /// custom=个人 key;default=服务器默认 key;none=都没配
  final String source;
  final String hint;

  bool get isCustom => source == 'custom';

  factory ModelKeyStatus.fromJson(Map<String, dynamic> json) => ModelKeyStatus(
        source: (json['source'] as String?) ?? 'none',
        hint: (json['hint'] as String?) ?? '',
      );
}

/// v1.9.0 邮箱账号:注册/激活/登录/重置的统一响应。
/// `token` 只在登录/激活成功时出现;`debugCode` 仅 MOCK 服务端返回(开发/测试)。
class AuthResult {
  const AuthResult({
    this.token,
    this.deviceId,
    this.deviceName,
    this.email,
    this.debugCode,
    this.message,
  });

  final String? token;
  final String? deviceId;
  final String? deviceName;
  final String? email;
  final String? debugCode;
  final String? message;

  factory AuthResult.fromJson(Map<String, dynamic> json) => AuthResult(
        token: json['token'] as String?,
        deviceId: json['device_id'] as String?,
        deviceName: json['device_name'] as String?,
        email: json['email'] as String?,
        debugCode: json['debug_code'] as String?,
        message: json['message'] as String?,
      );
}