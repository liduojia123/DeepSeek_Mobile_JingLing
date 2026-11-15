/// dsh 远程开发桥(电脑页)的数据模型。
/// 与 server/src/routes/harness.ts 的 REST/SSE 字段对应。
library;

class HarnessNode {
  const HarnessNode({
    required this.nodeId,
    required this.name,
    required this.platform,
    required this.online,
    required this.capabilities,
    this.lastSeen,
  });

  final String nodeId;
  final String name;
  final String platform;
  final bool online;
  final List<String> capabilities;
  final String? lastSeen;

  factory HarnessNode.fromJson(Map<String, dynamic> json) => HarnessNode(
        nodeId: (json['node_id'] as String?) ?? '',
        name: (json['name'] as String?) ?? 'dsh',
        platform: (json['platform'] as String?) ?? '',
        online: json['online'] == true,
        capabilities:
            ((json['capabilities'] as List?) ?? const []).whereType<String>().toList(growable: false),
        lastSeen: json['last_seen'] as String?,
      );
}

class HarnessWorkspace {
  const HarnessWorkspace({
    required this.id,
    required this.title,
    required this.path,
    required this.sessionIds,
  });

  final String id;
  final String title;
  final String path;
  final List<String> sessionIds;

  factory HarnessWorkspace.fromJson(Map<String, dynamic> json) => HarnessWorkspace(
        id: (json['id'] as String?) ?? '',
        title: (json['title'] as String?) ?? '',
        path: (json['path'] as String?) ?? '',
        sessionIds:
            ((json['session_ids'] as List?) ?? const []).whereType<String>().toList(growable: false),
      );
}

class HarnessSession {
  const HarnessSession({
    required this.id,
    required this.cwd,
    required this.live,
    required this.createdAt,
    this.title,
    this.agentPreset,
  });

  final String id;
  final String? cwd;
  final bool live;
  final String? createdAt;
  final String? title;
  final String? agentPreset;

  factory HarnessSession.fromJson(Map<String, dynamic> json) => HarnessSession(
        id: (json['id'] as String?) ?? '',
        cwd: json['cwd'] as String?,
        live: json['live'] == true,
        createdAt: json['created_at']?.toString(),
        title: json['title'] as String?,
        agentPreset: json['agent_preset'] as String?,
      );

  String get displayName {
    final trimmedTitle = (title ?? '').trim();
    if (trimmedTitle.isNotEmpty) return trimmedTitle;
    final trimmedCwd = (cwd ?? '').trim();
    if (trimmedCwd.isNotEmpty) {
      final parts = trimmedCwd.split(RegExp(r'[\\/]'));
      return parts.isEmpty ? trimmedCwd : parts.last;
    }
    return id;
  }
}

class HarnessWorkspaceSnapshot {
  const HarnessWorkspaceSnapshot({
    required this.nodeId,
    required this.workspaces,
    required this.sessions,
  });

  final String nodeId;
  final List<HarnessWorkspace> workspaces;
  final List<HarnessSession> sessions;

  factory HarnessWorkspaceSnapshot.fromJson(Map<String, dynamic> json) => HarnessWorkspaceSnapshot(
        nodeId: (json['node_id'] as String?) ?? '',
        workspaces: ((json['workspaces'] as List?) ?? const [])
            .whereType<Map>()
            .map((item) => HarnessWorkspace.fromJson(Map<String, dynamic>.from(item)))
            .toList(growable: false),
        sessions: ((json['sessions'] as List?) ?? const [])
            .whereType<Map>()
            .map((item) => HarnessSession.fromJson(Map<String, dynamic>.from(item)))
            .toList(growable: false),
      );
}

/// 任务事件:服务端把插件上行事件按 kind 分类存/推。
class HarnessEvent {
  const HarnessEvent({required this.seq, required this.kind, required this.payload, this.ts});

  final int seq;
  final String kind;
  final Map<String, dynamic> payload;
  final String? ts;

  factory HarnessEvent.fromJson(Map<String, dynamic> json) => HarnessEvent(
        seq: (json['seq'] as num?)?.toInt() ?? 0,
        kind: (json['kind'] as String?) ?? '',
        payload: json['payload'] is Map ? Map<String, dynamic>.from(json['payload'] as Map) : const {},
        ts: json['ts'] as String?,
      );
}

class HarnessTaskSnapshot {
  const HarnessTaskSnapshot({
    required this.taskId,
    required this.status,
    required this.events,
  });

  final String taskId;
  final String status;
  final List<HarnessEvent> events;

  bool get running => status == 'running';

  factory HarnessTaskSnapshot.fromJson(Map<String, dynamic> json) => HarnessTaskSnapshot(
        taskId: (json['task_id'] as String?) ?? '',
        status: (json['status'] as String?) ?? 'unknown',
        events: ((json['events'] as List?) ?? const [])
            .whereType<Map>()
            .map((item) => HarnessEvent.fromJson(Map<String, dynamic>.from(item)))
            .toList(growable: false),
      );
}

/// 手机上待确认的一次工具调用。
class HarnessConfirmRequest {
  const HarnessConfirmRequest({
    required this.approvalId,
    required this.tool,
    required this.reason,
    required this.timeoutSec,
  });

  final String approvalId;
  final String tool;
  final String reason;
  final int timeoutSec;

  factory HarnessConfirmRequest.fromPayload(Map<String, dynamic> payload) => HarnessConfirmRequest(
        approvalId: (payload['approval_id'] as String?) ?? '',
        tool: (payload['tool'] as String?) ?? 'tool',
        reason: (payload['reason'] as String?) ?? '',
        timeoutSec: (payload['timeout_sec'] as num?)?.toInt() ?? 15,
      );
}

/// dsh 会话里的一条历史消息(只读展示)。
class HarnessMessage {
  const HarnessMessage({required this.role, required this.text, this.tools = const []});

  final String role; // user | assistant
  final String text;
  final List<String> tools;

  factory HarnessMessage.fromJson(Map<String, dynamic> json) => HarnessMessage(
        role: (json['role'] as String?) ?? 'assistant',
        text: (json['text'] as String?) ?? '',
        tools: ((json['tools'] as List?) ?? const []).whereType<String>().toList(growable: false),
      );
}