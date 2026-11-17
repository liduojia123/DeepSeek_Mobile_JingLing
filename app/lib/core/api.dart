import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../models/events.dart';
import '../models/harness.dart';
import '../models/harness_stream.dart';
import '../models/models.dart';
import '../models/reminder.dart';
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

  // ---------- 设备(令牌吊销) ----------

  Future<List<Device>> devices() async {
    final json = await _guard(() async =>
        _decode(await _client.get(_uri('/v1/devices'), headers: _headers())));
    return ((json['devices'] as List?) ?? const [])
        .whereType<Map>()
        .map((item) => Device.fromJson(Map<String, dynamic>.from(item)))
        .toList(growable: false);
  }

  /// 吊销一台设备的令牌(立即生效,设备下次请求即 401)。
  Future<void> revokeDevice(String id) async {
    await _guard(() async {
      final response = await _client.delete(_uri('/v1/devices/$id'), headers: _headers());
      _expectNoContent(response);
      return null;
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

  // ---------- OTA(M6+) ----------

  /// 查询服务器发布的最新 App 版本;服务器还没发布过返回 null(404),其余错误照常抛出。
  Future<AppRelease?> appVersion() async {
    try {
      final json = await _guard(() async =>
          _decode(await _client.get(_uri('/v1/app/version'), headers: _headers())));
      return AppRelease.fromJson(json);
    } on ApiException catch (error) {
      // 404 = 服务器还没放安装包,这是"没有更新"而不是"检查失败";
      // 其余(401/网络/解析)必须让上层看见,否则会伪装成"已是最新版本"。
      if (error.statusCode == 404) return null;
      rethrow;
    }
  }

  /// 下载 APK 到指定路径,onProgress 回调 0..1。
  Future<void> downloadApk(String savePath, {void Function(double progress)? onProgress}) async {
    final request = http.Request('GET', _uri('/v1/app/download'))
      ..headers.addAll(_headers(jsonContentType: false));
    final response = await _guard(() => _client.send(request));
    if (response.statusCode != 200) {
      throw ApiException('下载安装包失败(HTTP ${response.statusCode})');
    }
    final total = response.contentLength ?? 0;
    var received = 0;
    final file = File(savePath);
    final sink = file.openWrite();
    try {
      await for (final chunk in response.stream) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0 && onProgress != null) {
          onProgress(received / total);
        }
      }
      await sink.flush();
    } finally {
      await sink.close();
    }
  }
  // ---------- 记忆(M5) ----------

  Future<List<MemoryNote>> memories({String? query, int limit = 100}) async {
    final json = await _guard(() async => _decode(await _client.get(
          _uri('/v1/memories', {'limit': '$limit', if (query != null && query.trim().isNotEmpty) 'query': query.trim()}),
          headers: _headers(),
        )));
    return ((json['items'] as List?) ?? const [])
        .whereType<Map>()
        .map((item) => MemoryNote.fromJson(Map<String, dynamic>.from(item)))
        .toList(growable: false);
  }

  Future<void> deleteMemory(String id) async {
    final response = await _guard(() => _client.delete(_uri('/v1/memories/$id'), headers: _headers()));
    _decode(response);
  }

  // ---------- 提醒(M7) ----------

  /// 还没落地的提醒(含 pending 与未来 scheduled),用于启动补排。
  Future<List<ServerReminder>> remindersActive() async {
    final json = await _guard(() async => _decode(await _client.get(
          _uri('/v1/reminders', {'status': 'active'}),
          headers: _headers(),
        )));
    return ((json['reminders'] as List?) ?? const [])
        .whereType<Map>()
        .map((item) => ServerReminder.fromJson(Map<String, dynamic>.from(item)))
        .toList(growable: false);
  }

  Future<void> ackReminder(String id, {required String status, String? nativeAlarmId, String? fireAt}) async {
    final body = <String, String>{'status': status};
    if (nativeAlarmId != null) body['native_alarm_id'] = nativeAlarmId;
    if (fireAt != null) body['fire_at'] = fireAt;
    final response = await _guard(() => _client.post(
          _uri('/v1/reminders/$id/ack'),
          headers: _headers(),
          body: jsonEncode(body),
        ));
    _decode(response);
  }
  // ---------- 语音(M4) ----------

  /// 上传 16kHz WAV → 识别文本。
  Future<String> transcribe(Uint8List wav) async {
    final request = http.MultipartRequest('POST', _uri('/v1/asr'))
      ..headers.addAll(_headers(jsonContentType: false));
    request.files.add(http.MultipartFile.fromBytes('file', wav, filename: 'speech.wav'));
    final streamed = await _guard(() => _client.send(request));
    final response = await http.Response.fromStream(streamed);
    final json = _decode(response);
    return (json['text'] as String?) ?? '';
  }

  /// 文本 → wav 音频字节(TTS)。
  Future<Uint8List> synthesize(String text) async {
    final response = await _guard(() => _client.post(
          _uri('/v1/tts'),
          headers: _headers(),
          body: jsonEncode({'text': text}),
        ));
    if (response.statusCode != 200) throw _errorFrom(response.statusCode, response.body);
    return response.bodyBytes;
  }
  // ---------- dsh 远程开发桥(M3) ----------

  Future<List<HarnessNode>> harnessNodes() async {    final json = await _guard(() async =>
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

  // ---------- 会话级桥接(M3.5,手机与电脑共用同一个会话) ----------

  /// 会话实时流(SSE):先补发 afterSeq 之后的持久事件,再接实时;断线用 lastSeq 续传。
  Stream<HarnessStreamEvent> harnessSessionStream(String sessionId, {int afterSeq = 0}) async* {
    final client = http.Client();
    try {
      final request = http.Request(
        'GET',
        _uri('/v1/harness/sessions/$sessionId/stream', {'after_seq': '$afterSeq'}),
      )..headers.addAll(_headers(jsonContentType: false));
      final response = await client.send(request);
      if (response.statusCode != 200) {
        final text = await response.stream.bytesToString();
        throw _errorFrom(response.statusCode, text);
      }
      final parser = SseStreamParser();
      await for (final chunk in response.stream.transform(utf8.decoder)) {
        for (final sse in parser.addChunk(chunk)) {
          final event = _decodeHarnessStreamEvent(sse);
          if (event != null) yield event;
        }
      }
      for (final sse in parser.flush()) {
        final event = _decodeHarnessStreamEvent(sse);
        if (event != null) yield event;
      }
    } on ApiException {
      rethrow;
    } on http.ClientException catch (error) {
      throw ApiException('会话连接中断:${error.message}');
    } finally {
      client.close();
    }
  }

  /// 手机输入进会话:auto = 电脑上正在跑就插话,空闲就追加一轮。
  Future<Map<String, dynamic>> harnessSessionInput(
    String sessionId, {
    required String text,
    String mode = 'auto',
  }) async {
    final json = await _guard(() async => _decode(await _client.post(
          _uri('/v1/harness/sessions/$sessionId/input'),
          headers: _headers(),
          body: jsonEncode({'text': text, 'mode': mode}),
        )));
    return json;
  }

  /// 停止电脑上的当前回合。
  Future<void> harnessStopSession(String sessionId) async {
    await _guard(() async {
      final response = await _client.post(
        _uri('/v1/harness/sessions/$sessionId/stop'),
        headers: _headers(),
        body: '{}',
      );
      _decode(response);
      return null;
    });
  }

  /// 会话状态(电脑上是否在跑 / 权限预设 / 模型)。
  Future<Map<String, dynamic>> harnessSessionState(String sessionId) async {
    final json = await _guard(() async =>
        _decode(await _client.get(_uri('/v1/harness/sessions/$sessionId/state'), headers: _headers())));
    return json;
  }

  /// 会话级权限预设:workspace-write(沙箱内)/ danger-full-access(完全访问)。
  Future<void> harnessSetSessionPermission(String sessionId, String mode) async {
    await _guard(() async {
      final response = await _client.put(
        _uri('/v1/harness/sessions/$sessionId/permission'),
        headers: _headers(),
        body: jsonEncode({'mode': mode}),
      );
      _decode(response);
      return null;
    });
  }

  /// 在电脑上新建一个 dsh 会话,cwd 决定工作区。
  Future<String> harnessCreateSession({
    required String cwd,
    String? agentPreset,
    String? permission,
  }) async {
    final json = await _guard(() async => _decode(await _client.post(
          _uri('/v1/harness/sessions'),
          headers: _headers(),
          body: jsonEncode({
            'cwd': cwd,
            'agent_preset': ?agentPreset,
            'permission': ?permission,
          }),
        )));
    return (json['session_id'] as String?) ?? '';
  }

  HarnessStreamEvent? _decodeHarnessStreamEvent(SseEvent sse) {
    try {
      final decoded = jsonDecode(sse.data);
      if (decoded is! Map) return null;
      final json = Map<String, dynamic>.from(decoded);
      switch (sse.event) {
        case 'harness_session_ready':
          return HarnessSessionReady(
            sessionId: (json['session_id'] as String?) ?? '',
            lastSeq: (json['last_seq'] as num?)?.toInt() ?? 0,
            status: (json['status'] as String?) ?? 'idle',
            permission: json['permission'] as String?,
            model: json['model'] as String?,
          );
        case 'harness_session_event':
          return HarnessSessionEvent.fromJson(json);
        case 'harness_session_live':
          return HarnessSessionLive.fromJson(json);
        default:
          return null;
      }
    } catch (_) {
      return null;
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
