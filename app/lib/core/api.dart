import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/events.dart';
import '../models/harness.dart';
import '../models/models.dart';
import 'sse_client.dart';

class ApiException implements Exception {
  ApiException(this.message, {this.statusCode, this.code});

  final String message;
  final int? statusCode;
  final String? code;

  @override
  String toString() => message;
}

/// DPAPP 自有协议的客户端封装。除 pairing 外所有请求都带设备令牌。
class ApiClient {
  ApiClient({required String baseUrl, this.token, http.Client? httpClient})
      : _baseUrl = _trimSlash(baseUrl),
        _client = httpClient ?? http.Client();

  final String _baseUrl;
  final String? token;
  final http.Client _client;

  static String _trimSlash(String url) {
    final trimmed = url.trim();
    return trimmed.endsWith('/') ? trimmed.substring(0, trimmed.length - 1) : trimmed;
  }

  Uri _uri(String path, [Map<String, String>? query]) {
    final uri = Uri.parse('$_baseUrl$path');
    return query == null ? uri : uri.replace(queryParameters: query);
  }

  Map<String, String> _headers({bool withAuth = true, bool jsonContentType = true}) => {
        if (jsonContentType) 'Content-Type': 'application/json',
        if (withAuth && token != null && token!.isNotEmpty) 'Authorization': 'Bearer $token',
      };

  void dispose() => _client.close();

  // ---------- 认证 ----------

  Future<PairResult> pair({required String code, required String deviceName}) async {
    final json = await _guard(() async {
      final response = await _client.post(
        _uri('/v1/pair'),
        headers: _headers(withAuth: false),
        body: jsonEncode({'code': code, 'device_name': deviceName}),
      );
      return _decode(response);
    });
    return PairResult.fromJson(json);
  }

  // ---------- 会话 ----------

  Future<List<Conversation>> listConversations() async {
    final json = await _guard(() async => _decode(await _client.get(_uri('/v1/conversations'), headers: _headers())));
    final items = (json['conversations'] as List?) ?? const [];
    return items
        .whereType<Map>()
        .map((item) => Conversation.fromJson(Map<String, dynamic>.from(item)))
        .toList(growable: false);
  }

  Future<Conversation> createConversation({String? title, bool ephemeral = false}) async {
    final json = await _guard(() async {
      final response = await _client.post(
        _uri('/v1/conversations'),
        headers: _headers(),
        body: jsonEncode({
          'title': ?title,
          if (ephemeral) 'ephemeral': true,
        }),
      );
      return _decode(response);
    });
    return Conversation.fromJson(json);
  }

  Future<ConversationDetail> getConversation(String id) async {
    final json = await _guard(() async => _decode(await _client.get(_uri('/v1/conversations/$id'), headers: _headers())));
    return ConversationDetail.fromJson(json);
  }

  Future<void> patchConversation(
    String id, {
    String? title,
    bool? pinned,
    bool? ephemeral,
    String? activeLeafId,
  }) async {
    await _guard(() async {
      final response = await _client.patch(
        _uri('/v1/conversations/$id'),
        headers: _headers(),
        body: jsonEncode({
          'title': ?title,
          'pinned': ?pinned,
          'ephemeral': ?ephemeral,
          'active_leaf_id': ?activeLeafId,
        }),
      );
      _decode(response);
      return null;
    });
  }

  Future<void> deleteConversation(String id) async {
    await _guard(() async {
      final response = await _client.delete(_uri('/v1/conversations/$id'), headers: _headers());
      _expectNoContent(response);
      return null;
    });
  }

  Future<void> deleteMessage(String conversationId, String messageId) async {
    await _guard(() async {
      final response = await _client.delete(
        _uri('/v1/conversations/$conversationId/messages/$messageId'),
        headers: _headers(),
      );
      _expectNoContent(response);
      return null;
    });
  }

  Future<void> stop(String conversationId) async {
    await _guard(() async {
      final response = await _client.post(
        _uri('/v1/conversations/$conversationId/stop'),
        headers: _headers(),
        body: '{}',
      );
      _decode(response);
      return null;
    });
  }

  // ---------- 对话流 ----------

  /// 三种用法共用:
  ///  - 普通发送:只给 content
  ///  - 编辑重发:content + parentMessageId(被编辑消息的父节点)或 parentIsRoot
  ///  - 重新生成:regenerate + parentMessageId(该用户消息 id)
  Stream<DpappEvent> chat({
    required String conversationId,
    String? content,
    bool regenerate = false,
    String? parentMessageId,
    bool parentIsRoot = false,
    List<String>? fileIds,
    bool? search,
    bool? thinking,
  }) async* {
    final body = <String, dynamic>{
      'content': ?content,
      if (regenerate) 'regenerate': true,
      if (fileIds != null && fileIds.isNotEmpty) 'file_ids': fileIds,
      'search': ?search,
      'thinking': ?thinking,
    };
    // null 是有意义的取值(挂到根节点),必须显式发送,不能和「未指定」混淆
    if (parentIsRoot) {
      body['parent_message_id'] = null;
    } else if (parentMessageId != null) {
      body['parent_message_id'] = parentMessageId;
    }

    final client = http.Client();
    try {
      final request = http.Request('POST', _uri('/v1/conversations/$conversationId/chat'))
        ..headers.addAll(_headers())
        ..body = jsonEncode(body);

      final response = await client.send(request);
      if (response.statusCode != 200) {
        final text = await response.stream.bytesToString();
        throw _errorFrom(response.statusCode, text);
      }

      final parser = SseStreamParser();
      await for (final chunk in response.stream.transform(utf8.decoder)) {
        for (final sse in parser.addChunk(chunk)) {
          final event = _decodeEvent(sse);
          if (event != null) yield event;
        }
      }
      for (final sse in parser.flush()) {
        final event = _decodeEvent(sse);
        if (event != null) yield event;
      }
    } on ApiException {
      rethrow;
    } on http.ClientException catch (error) {
      throw ApiException('连接中断:${error.message}');
    } finally {
      client.close();
    }
  }

  // ---------- 文件 ----------

  /// 上传文档 → 服务端转发给 DeepSeek Files API 同步解析,成功才返回 file_id。
  Future<FileUploadResult> uploadFile({
    required String filename,
    required List<int> bytes,
    String purpose = 'text_recognition',
  }) async {
    return _guard(() async {
      final request = http.MultipartRequest('POST', _uri('/v1/files', {'purpose': purpose}))
        ..headers.addAll(_headers())
        ..files.add(http.MultipartFile.fromBytes('file', bytes, filename: filename));

      final client = http.Client();
      try {
        final response = await http.Response.fromStream(await client.send(request));
        final json = _decode(response);
        return FileUploadResult.fromJson(json);
      } finally {
        client.close();
      }
    });
  }

  // ---------- 用量 ----------

  Future<UsageSummary> usage({int days = 30}) async {
    final json = await _guard(() async => _decode(await _client.get(
          _uri('/v1/usage', {'days': '$days'}),
          headers: _headers(),
        )));
    return UsageSummary.fromJson(json);
  }

  // ---------- dsh 远程开发桥(M3) ----------

  Future<List<HarnessNode>> harnessNodes() async {
    final json = await _guard(() async =>
        _decode(await _client.get(_uri('/v1/harness/nodes'), headers: _headers())));
    return ((json['nodes'] as List?) ?? const [])
        .whereType<Map>()
        .map((item) => HarnessNode.fromJson(Map<String, dynamic>.from(item)))
        .toList(growable: false);
  }

  Future<HarnessWorkspaceSnapshot> harnessWorkspaces({String? nodeId}) async {
    final json = await _guard(() async => _decode(await _client.get(
          _uri('/v1/harness/workspaces', nodeId == null ? null : {'node_id': nodeId}),
          headers: _headers(),
        )));
    return HarnessWorkspaceSnapshot.fromJson(json);
  }

  Future<String> startHarnessTask({
    required String sessionId,
    required String prompt,
    String? cwd,
    String? agentPreset,
    String? permissionMode,
    bool requireApproval = false,
  }) async {
    final json = await _guard(() async => _decode(await _client.post(
          _uri('/v1/harness/tasks'),
          headers: _headers(),
          body: jsonEncode({
            'session_id': sessionId,
            'prompt': prompt,
            'require_approval': requireApproval,
            'cwd': ?cwd,
            'agent_preset': ?agentPreset,
            'permission_mode': ?permissionMode,
          }),
        )));
    return (json['task_id'] as String?) ?? '';
  }

  /// 读取 dsh 会话的历史消息(只读)。
  Future<List<HarnessMessage>> harnessHistory(String sessionId, {int limit = 200}) async {
    final json = await _guard(() async => _decode(await _client.get(
          _uri('/v1/harness/sessions/$sessionId/history', {'limit': '$limit'}),
          headers: _headers(),
        )));
    return ((json['messages'] as List?) ?? const [])
        .whereType<Map>()
        .map((item) => HarnessMessage.fromJson(Map<String, dynamic>.from(item)))
        .toList(growable: false);
  }
  Future<HarnessTaskSnapshot> harnessTask(String taskId) async {
    final json = await _guard(() async =>
        _decode(await _client.get(_uri('/v1/harness/tasks/$taskId'), headers: _headers())));
    return HarnessTaskSnapshot.fromJson(json);
  }

  Future<void> confirmHarnessTask({
    required String taskId,
    required String approvalId,
    required bool allow,
  }) async {
    await _guard(() async {
      final response = await _client.post(
        _uri('/v1/harness/tasks/$taskId/confirm'),
        headers: _headers(),
        body: jsonEncode({'approval_id': approvalId, 'decision': allow ? 'allow' : 'reject'}),
      );
      _decode(response);
      return null;
    });
  }

  Future<void> stopHarnessTask(String taskId) async {
    await _guard(() async {
      final response = await _client.post(
        _uri('/v1/harness/tasks/$taskId/stop'),
        headers: _headers(),
        body: '{}',
      );
      _decode(response);
      return null;
    });
  }

  /// 任务的实时事件流(SSE):`event: harness_<kind>` + `data: <payload JSON>`。
  Stream<HarnessEvent> harnessTaskEvents(String taskId) async* {
    final client = http.Client();
    var seq = 0;
    try {
      // SSE 是 GET 且无 body:不能带 JSON content-type,否则 Fastify 会以
      // "Body cannot be empty when content-type is set to 'application/json'" 拒绝
      final request = http.Request('GET', _uri('/v1/harness/tasks/$taskId/events'))
        ..headers.addAll(_headers(jsonContentType: false));
      final response = await client.send(request);
      if (response.statusCode != 200) {
        final text = await response.stream.bytesToString();
        throw _errorFrom(response.statusCode, text);
      }
      final parser = SseStreamParser();
      await for (final chunk in response.stream.transform(utf8.decoder)) {
        for (final sse in parser.addChunk(chunk)) {
          final payload = jsonDecode(sse.data);
          if (payload is! Map) continue;
          seq += 1;
          yield HarnessEvent(
            seq: seq,
            kind: sse.event.replaceFirst('harness_', ''),
            payload: Map<String, dynamic>.from(payload),
          );
        }
      }
    } on ApiException {
      rethrow;
    } on http.ClientException catch (error) {
      throw ApiException('电脑连接中断:${error.message}');
    } finally {
      client.close();
    }
  }

  // ---------- 内部 ----------

  Future<T> _guard<T>(Future<T> Function() run) async {
    try {
      return await run();
    } on ApiException {
      rethrow;
    } on http.ClientException catch (error) {
      throw ApiException('无法连接服务器:${error.message}');
    } on TimeoutException {
      throw ApiException('请求超时,请检查服务器地址与网络');
    } catch (error) {
      throw ApiException('网络错误:$error');
    }
  }

  Map<String, dynamic> _decode(http.Response response) {
    if (response.statusCode >= 200 && response.statusCode < 300) {
      if (response.body.trim().isEmpty) return const {};
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      return decoded is Map<String, dynamic> ? decoded : const {};
    }
    throw _errorFrom(response.statusCode, response.body);
  }

  void _expectNoContent(http.Response response) {
    if (response.statusCode >= 200 && response.statusCode < 300) return;
    throw _errorFrom(response.statusCode, response.body);
  }

  ApiException _errorFrom(int statusCode, String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map && decoded['error'] is Map) {
        final error = Map<String, dynamic>.from(decoded['error'] as Map);
        return ApiException(
          (error['message'] as String?) ?? '请求失败($statusCode)',
          statusCode: statusCode,
          code: error['code'] as String?,
        );
      }
    } catch (_) {
      // 非 JSON 错误体,走下面的兜底
    }
    return ApiException('请求失败($statusCode)', statusCode: statusCode);
  }

  DpappEvent? _decodeEvent(SseEvent sse) {
    try {
      final decoded = jsonDecode(sse.data);
      if (decoded is! Map) return null;
      return DpappEvent.fromJson(Map<String, dynamic>.from(decoded));
    } catch (_) {
      return null; // 脏块忽略,不打断整条流
    }
  }
}
