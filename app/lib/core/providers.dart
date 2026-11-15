import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/events.dart';
import '../models/models.dart';
import 'api.dart';
import 'config.dart';

final secureStoreProvider = Provider<SecureStore>((ref) => const SecureStore());

class AppSettings {
  const AppSettings({required this.serverUrl, required this.token});

  final String serverUrl;
  final String? token;

  bool get paired => token != null && token!.trim().isNotEmpty;

  AppSettings copyWith({String? serverUrl, String? token, bool clearToken = false}) => AppSettings(
        serverUrl: serverUrl ?? this.serverUrl,
        token: clearToken ? null : (token ?? this.token),
      );
}

/// 启动时读本地配置;配对/解除配对/改服务器地址都在这里改状态。
class SettingsController extends AsyncNotifier<AppSettings> {
  @override
  Future<AppSettings> build() async {
    final store = ref.watch(secureStoreProvider);
    return AppSettings(
      serverUrl: await store.readServerUrl(),
      token: await store.readToken(),
    );
  }

  Future<void> saveServerUrl(String url) async {
    final store = ref.read(secureStoreProvider);
    await store.writeServerUrl(url);
    final current = state.value;
    final normalized = (await store.readServerUrl());
    state = AsyncData(current == null
        ? AppSettings(serverUrl: normalized, token: null)
        : current.copyWith(serverUrl: normalized));
  }

  Future<PairResult> pairWithCode({required String code, required String deviceName}) async {
    final store = ref.read(secureStoreProvider);
    final current = state.value ?? AppSettings(serverUrl: await store.readServerUrl(), token: null);
    final api = ApiClient(baseUrl: current.serverUrl);
    try {
      final result = await api.pair(code: code.trim(), deviceName: deviceName.trim().isEmpty ? '我的手机' : deviceName.trim());
      await store.writeToken(result.token);
      state = AsyncData(AppSettings(serverUrl: current.serverUrl, token: result.token));
      return result;
    } finally {
      api.dispose();
    }
  }

  Future<void> unpair() async {
    final store = ref.read(secureStoreProvider);
    await store.writeToken(null);
    final current = state.value;
    state = AsyncData(AppSettings(serverUrl: current?.serverUrl ?? SecureStore.defaultServerUrl, token: null));
  }
}

final settingsProvider = AsyncNotifierProvider<SettingsController, AppSettings>(SettingsController.new);

/// 已配对才有 api;服务器地址或令牌变化时自动重建。
final apiProvider = Provider<ApiClient?>((ref) {
  final settings = ref.watch(settingsProvider).value;
  if (settings == null || !settings.paired) return null;
  final api = ApiClient(baseUrl: settings.serverUrl, token: settings.token);
  ref.onDispose(api.dispose);
  return api;
});

class ConversationsController extends AsyncNotifier<List<Conversation>> {
  @override
  Future<List<Conversation>> build() async {
    final api = ref.watch(apiProvider);
    if (api == null) return const [];
    return api.listConversations();
  }

  Future<void> refresh() async {
    final api = ref.read(apiProvider);
    if (api == null) return;
    state = await AsyncValue.guard(api.listConversations);
  }

  Future<Conversation> create({bool ephemeral = false}) async {
    final api = ref.read(apiProvider);
    if (api == null) throw ApiException('未配对');
    final conversation = await api.createConversation(ephemeral: ephemeral);
    await refresh();
    return conversation;
  }

  Future<void> rename(String id, String title) async {
    final api = ref.read(apiProvider);
    if (api == null) return;
    await api.patchConversation(id, title: title);
    await refresh();
  }

  Future<void> togglePin(Conversation conversation) async {
    final api = ref.read(apiProvider);
    if (api == null) return;
    await api.patchConversation(conversation.id, pinned: !conversation.pinned);
    await refresh();
  }

  Future<void> remove(String id) async {
    final api = ref.read(apiProvider);
    if (api == null) return;
    await api.deleteConversation(id);
    await refresh();
  }
}

final conversationsProvider =
    AsyncNotifierProvider<ConversationsController, List<Conversation>>(ConversationsController.new);

const Object _unset = Object();

class ChatState {
  const ChatState({
    this.conversationId,
    this.detail,
    this.loading = false,
    this.generating = false,
    this.thinking = '',
    this.searchEnabled = true,
    this.thinkingEnabled = true,
    this.streamText = '',
    this.streamingCitations = const [],
    this.streamingToolTraces = const [],
    this.toolStatus,
    this.title,
    this.files = const [],
    this.pendingUserText,
    this.error,
    this.info,
  });

  final String? conversationId;
  final ConversationDetail? detail;
  final bool loading;
  final bool generating;
  final String thinking;
  /// 本次对话的联网搜索开关(默认开) */
  final bool searchEnabled;
  /// 深度思考开关(默认开) */
  final bool thinkingEnabled;
  final String streamText;

  /// 流式过程中累积的引用与工具卡片(结束后以服务端落库的树为准)
  final List<Citation> streamingCitations;
  final List<ToolTrace> streamingToolTraces;

  /// 正在进行的工具动作,用于实时提示(如"正在搜索…")
  final String? toolStatus;
  final String? title;

  /// 已上传、待随本条消息发送的附件
  final List<ChatFile> files;

  /// 已发送但服务端还没返回树时的本地用户气泡(避免"点了发送没反应")
  final String? pendingUserText;
  final String? error;
  final String? info;

  List<MessageNode> get pathNodes => detail?.pathNodes ?? const [];
  StreamingAnswer get streaming => StreamingAnswer(
        thinking: thinking,
        text: streamText,
        citations: streamingCitations,
        toolTraces: streamingToolTraces,
      );

  ChatState copyWith({
    String? conversationId,
    ConversationDetail? detail,
    bool? loading,
    bool? generating,
    String? thinking,
    String? streamText,
    List<Citation>? streamingCitations,
    List<ToolTrace>? streamingToolTraces,
    Object? toolStatus = _unset,
    Object? title = _unset,
    List<ChatFile>? files,
    Object? pendingUserText = _unset,
    Object? error = _unset,
    Object? info = _unset,
    bool? searchEnabled,
    bool? thinkingEnabled,
  }) =>
      ChatState(
        conversationId: conversationId ?? this.conversationId,
        detail: detail ?? this.detail,
        loading: loading ?? this.loading,
        generating: generating ?? this.generating,
        thinking: thinking ?? this.thinking,
        streamText: streamText ?? this.streamText,
        streamingCitations: streamingCitations ?? this.streamingCitations,
        streamingToolTraces: streamingToolTraces ?? this.streamingToolTraces,
        toolStatus: identical(toolStatus, _unset) ? this.toolStatus : toolStatus as String?,
        title: identical(title, _unset) ? this.title : title as String?,
        files: files ?? this.files,
        pendingUserText: identical(pendingUserText, _unset) ? this.pendingUserText : pendingUserText as String?,
        error: identical(error, _unset) ? this.error : error as String?,
        info: identical(info, _unset) ? this.info : info as String?,
        searchEnabled: searchEnabled ?? this.searchEnabled,
        thinkingEnabled: thinkingEnabled ?? this.thinkingEnabled,
      );
}

class ChatController extends Notifier<ChatState> {
  @override
  ChatState build() => const ChatState();

  void setSearchEnabled(bool enabled) => state = state.copyWith(searchEnabled: enabled);

  void setThinkingEnabled(bool enabled) => state = state.copyWith(thinkingEnabled: enabled);

  Future<void> open(String conversationId) async {
    state = ChatState(conversationId: conversationId, loading: true);
    await _reload();
    state = state.copyWith(loading: false);
  }

  Future<void> send(
    String content, {
    String? parentMessageId,
    bool parentIsRoot = false,
    bool regenerate = false,
    List<String>? fileIds,
  }) async {
    final api = ref.read(apiProvider);
    final conversationId = state.conversationId;
    if (api == null || conversationId == null || state.generating) return;

    state = state.copyWith(
      generating: true,
      thinking: '',
      streamText: '',
      streamingCitations: const [],
      streamingToolTraces: const [],
      toolStatus: null,
      pendingUserText: regenerate ? null : content,
      error: null,
      info: null,
    );

    String? failure;
    try {
      await for (final event in api.chat(
        conversationId: conversationId,
        content: regenerate ? null : content,
        regenerate: regenerate,
        parentMessageId: parentMessageId,
        parentIsRoot: parentIsRoot,
        fileIds: fileIds,
        search: state.searchEnabled,
        thinking: state.thinkingEnabled,
      )) {
        switch (event) {
          case ThinkingDeltaEvent(:final text):
            state = state.copyWith(thinking: state.thinking + text);
          case TextDeltaEvent(:final text):
            state = state.copyWith(streamText: state.streamText + text, toolStatus: null);
          case ToolProgressEvent(:final tool, :final phase, :final queries, :final url):
            state = state.copyWith(toolStatus: _toolStatusLabel(tool, phase, queries, url));
          case ToolResultEvent(:final tool, :final summary, :final results, :final callId, :final status):
            state = state.copyWith(
              toolStatus: null,
              streamingToolTraces: [
                ...state.streamingToolTraces,
                ToolTrace(
                  tool: tool,
                  summary: summary,
                  callId: callId,
                  status: status,
                  results: results
                      .map((entry) => ToolTraceResult(
                            title: entry.title,
                            url: entry.url,
                            siteName: entry.siteName,
                            snippet: entry.snippet,
                          ))
                      .toList(growable: false),
                ),
              ],
            );
          case CitationEvent(:final index, :final url, :final title, :final startIndex, :final endIndex):
            state = state.copyWith(
              streamingCitations: [
                ...state.streamingCitations,
                Citation(index: index, url: url, title: title, startIndex: startIndex, endIndex: endIndex),
              ],
            );
          case TitleEvent(:final title):
            state = state.copyWith(title: title);
          case DpappErrorEvent(:final message):
            failure = message;
          case SafetyBlockEvent(:final reason):
            failure = '内容安全拦截:$reason';
          case MessageEndEvent(:final stopReason):
            if (stopReason == 'interrupted') {
              state = state.copyWith(info: '已停止生成');
            } else if (stopReason == 'error') {
              failure ??= '本轮生成失败';
            } else if (stopReason == 'refusal') {
              failure ??= '内容未通过安全审核';
            }
          default:
            break;
        }
      }
    } on ApiException catch (error) {
      failure = error.message;
    } catch (error) {
      failure = '生成失败:$error';
    } finally {
      await _reload();
      state = state.copyWith(
        generating: false,
        error: failure,
        pendingUserText: null,
        files: const [],
        toolStatus: null,
      );
    }
  }

  static String _toolStatusLabel(String tool, String phase, List<String>? queries, String? url) {
    if (phase == 'searching') {
      final q = (queries ?? const []).map((item) => '「$item」').join(' ');
      return q.isEmpty ? '正在联网搜索…' : '正在搜索 $q';
    }
    if (phase == 'reading' || phase == 'fetching') return '正在阅读网页…';
    if (phase == 'finding') return '正在网页内查找…';
    return '正在调用工具…';
  }

  /// 上传并解析附件(M2);解析是同步的,失败会带上游原因。
  Future<void> attachFile({required String name, required List<int> bytes}) async {
    final api = ref.read(apiProvider);
    if (api == null) return;
    state = state.copyWith(info: '正在上传并解析「$name」…', error: null);
    try {
      final result = await api.uploadFile(filename: name, bytes: bytes);
      state = state.copyWith(
        info: null,
        files: [...state.files, ChatFile(id: result.fileId, name: result.name)],
      );
    } on ApiException catch (error) {
      state = state.copyWith(error: error.message, info: null);
    }
  }

  void removeFile(String id) {
    state = state.copyWith(files: state.files.where((file) => file.id != id).toList(growable: false));
  }

  Future<void> regenerate(MessageNode assistantNode) async {
    final parentId = assistantNode.parentId;
    if (parentId == null) return;
    await send('', regenerate: true, parentMessageId: parentId);
  }

  Future<void> editResend(MessageNode userNode, String newContent) async {
    final trimmed = newContent.trim();
    if (trimmed.isEmpty) return;
    await send(
      trimmed,
      parentMessageId: userNode.parentId,
      parentIsRoot: userNode.parentId == null,
    );
  }

  Future<void> switchBranch(String siblingId) async {
    final api = ref.read(apiProvider);
    final detail = state.detail;
    final conversationId = state.conversationId;
    if (api == null || detail == null || conversationId == null || state.generating) return;

    final node = detail.nodeById(siblingId);
    if (node == null) return;
    final leaf = detail.deepestLeafUnder(node);
    try {
      await api.patchConversation(conversationId, activeLeafId: leaf);
      await _reload();
    } on ApiException catch (error) {
      state = state.copyWith(error: error.message);
    }
  }

  Future<void> stop() async {
    final api = ref.read(apiProvider);
    final conversationId = state.conversationId;
    if (api == null || conversationId == null) return;
    try {
      await api.stop(conversationId);
    } on ApiException {
      // 已经没有进行中的生成也无所谓,流会自己结束
    }
  }

  Future<void> deleteMessage(String messageId) async {
    final api = ref.read(apiProvider);
    final conversationId = state.conversationId;
    if (api == null || conversationId == null || state.generating) return;
    try {
      await api.deleteMessage(conversationId, messageId);
      await _reload();
    } on ApiException catch (error) {
      state = state.copyWith(error: error.message);
    }
  }

  void clearBanner() => state = state.copyWith(error: null, info: null);

  Future<void> _reload() async {
    final api = ref.read(apiProvider);
    final conversationId = state.conversationId;
    if (api == null || conversationId == null) return;
    try {
      final detail = await api.getConversation(conversationId);
      state = state.copyWith(
        detail: detail,
        thinking: '',
        streamText: '',
        streamingCitations: const [],
        streamingToolTraces: const [],
        toolStatus: null,
        title: null,
      );
      ref.invalidate(conversationsProvider);
    } on ApiException catch (error) {
      state = state.copyWith(error: error.message);
    }
  }
}

final chatProvider = NotifierProvider<ChatController, ChatState>(ChatController.new);