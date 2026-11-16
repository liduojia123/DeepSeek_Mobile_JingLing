import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/harness.dart';
import 'wait_alert.dart';
import 'api.dart';
import 'providers.dart';

const Object _unset = Object();

class HarnessState {
  const HarnessState({
    this.loading = false,
    this.error,
    this.nodes = const [],
    this.snapshot,
    this.selectedSessionId,
    this.taskId,
    this.status = 'idle',
    this.thinking = '',
    this.output = '',
    this.toolEvents = const [],
    this.confirm,
    this.confirmRemaining = 0,
    this.permissionMode = 'workspace-write',
    this.confirmTools = false,
    this.viewingTask = false,
    this.viewingSession = false,
    this.history = const [],
    this.historyLoading = false,
  });

  final bool loading;
  final String? error;
  final List<HarnessNode> nodes;
  final HarnessWorkspaceSnapshot? snapshot;
  final String? selectedSessionId;
  final String? taskId;
  final String status;
  final String thinking;
  final String output;
  final List<HarnessEvent> toolEvents;
  final HarnessConfirmRequest? confirm;
  final int confirmRemaining;
  /// 远程会话的沙箱权限模式:workspace-write(默认)或 danger-full-access。
  final String permissionMode;
  /// 是否对每次工具调用逐条确认(默认关;本地设为完全访问时桥接会自动让位)。
  final bool confirmTools;
  /// 当前是否在「任务视图」;false 表示在会话列表视图(可切换会话)。
  final bool viewingTask;
  /// 是否正在查看某个 dsh 会话的历史。
  final bool viewingSession;
  /// 当前会话的历史消息(只读)。
  final List<HarnessMessage> history;
  final bool historyLoading;

  bool get running => status == 'running';
  HarnessNode? get onlineNode {
    for (final node in nodes) {
      if (node.online) return node;
    }
    return nodes.isEmpty ? null : nodes.first;
  }

  HarnessSession? get selectedSession {
    final id = selectedSessionId;
    if (id == null) return null;
    for (final session in snapshot?.sessions ?? const <HarnessSession>[]) {
      if (session.id == id) return session;
    }
    return null;
  }

  HarnessState copyWith({
    bool? loading,
    Object? error = _unset,
    List<HarnessNode>? nodes,
    HarnessWorkspaceSnapshot? snapshot,
    Object? selectedSessionId = _unset,
    Object? taskId = _unset,
    String? status,
    String? thinking,
    String? output,
    List<HarnessEvent>? toolEvents,
    Object? confirm = _unset,
    int? confirmRemaining,
    String? permissionMode,
    bool? viewingTask,
    bool? viewingSession,
    bool? confirmTools,
    List<HarnessMessage>? history,
    bool? historyLoading,
  }) =>
      HarnessState(
        loading: loading ?? this.loading,
        error: identical(error, _unset) ? this.error : error as String?,
        nodes: nodes ?? this.nodes,
        snapshot: snapshot ?? this.snapshot,
        selectedSessionId: identical(selectedSessionId, _unset)
            ? this.selectedSessionId
            : selectedSessionId as String?,
        taskId: identical(taskId, _unset) ? this.taskId : taskId as String?,
        status: status ?? this.status,
        thinking: thinking ?? this.thinking,
        output: output ?? this.output,
        toolEvents: toolEvents ?? this.toolEvents,
        confirm: identical(confirm, _unset) ? this.confirm : confirm as HarnessConfirmRequest?,
        confirmRemaining: confirmRemaining ?? this.confirmRemaining,
        permissionMode: permissionMode ?? this.permissionMode,
        confirmTools: confirmTools ?? this.confirmTools,
        viewingTask: viewingTask ?? this.viewingTask,
        viewingSession: viewingSession ?? this.viewingSession,
        history: history ?? this.history,
        historyLoading: historyLoading ?? this.historyLoading,
      );
}

/// 电脑页控制器:加载节点/工作区 → 派任务 → 订阅事件 → 处理确认卡片。
class HarnessController extends Notifier<HarnessState> {
  StreamSubscription<HarnessEvent>? _events;
  Timer? _ticker;
  Timer? _reconnectTimer;
  int _reconnectAttempts = 0;

  @override
  HarnessState build() {
    ref.onDispose(() {
      _events?.cancel();
      _ticker?.cancel();
      _reconnectTimer?.cancel();
    });
    return const HarnessState();
  }

  Future<void> load() async {
    final api = ref.read(apiProvider);
    if (api == null) return;
    state = state.copyWith(loading: true, error: null);
    try {
      final nodes = await api.harnessNodes();
      final online = nodes.where((node) => node.online).toList(growable: false);
      if (online.isEmpty) {
        state = state.copyWith(loading: false, nodes: nodes, error: '电脑节点离线:请确认 dsh 正在运行且桥接插件已连接');
        return;
      }
      final snapshot = await api.harnessWorkspaces(nodeId: online.first.nodeId);
      final sessions = snapshot.sessions;
      final selected = state.selectedSessionId ??
          (sessions.isEmpty ? null : sessions.first.id);
      state = state.copyWith(
        loading: false,
        nodes: nodes,
        snapshot: snapshot,
        selectedSessionId: selected,
        error: null,
      );
    } on ApiException catch (error) {
      state = state.copyWith(loading: false, error: error.message);
    }
  }

  /// 回到会话列表(任务继续在电脑上跑,确认卡片仍会弹出)。
  void showList() => state = state.copyWith(viewingTask: false, viewingSession: false);

  /// 点进一个 dsh 会话:选中并加载只读历史。
  Future<void> openSession(String sessionId) async {
    final api = ref.read(apiProvider);
    state = state.copyWith(
      selectedSessionId: sessionId,
      viewingSession: true,
      viewingTask: false,
      historyLoading: true,
      history: const [],
      error: null,
    );
    if (api == null) return;
    try {
      final history = await api.harnessHistory(sessionId);
      state = state.copyWith(history: history, historyLoading: false);
    } on ApiException catch (error) {
      state = state.copyWith(historyLoading: false, error: error.message);
    }
  }

  /// 从列表回到当前任务视图。
  void openTask() {
    if (state.taskId != null) state = state.copyWith(viewingTask: true);
  }

  void setPermissionMode(String mode) => state = state.copyWith(permissionMode: mode);

  void setConfirmTools(bool enabled) => state = state.copyWith(confirmTools: enabled);

  void selectSession(String sessionId) {
    state = state.copyWith(selectedSessionId: sessionId);
  }

  /// 订阅任务事件流。SSE 是长连接:App 切后台/退出再回来会断,断线且任务仍在跑时自动重连
  /// (服务端会重放该任务的事件缓冲,所以重连前清空本地缓冲避免重复)。
  Future<void> _attachStream(String taskId, {bool reset = false}) async {
    final api = ref.read(apiProvider);
    if (api == null) return;
    await _events?.cancel();
    _events = null;
    if (reset) {
      state = state.copyWith(thinking: '', output: '', toolEvents: const [], confirm: null, confirmRemaining: 0);
    }
    _events = api.harnessTaskEvents(taskId).listen(
      _applyEvent,
      onError: (Object error) {
        if (state.running && state.taskId == taskId) {
          _scheduleReconnect(taskId);
          return;
        }
        state = state.copyWith(
          status: 'error',
          error: error is ApiException ? error.message : '$error',
        );
      },
      onDone: () {
        if (state.running && state.taskId == taskId) {
          _scheduleReconnect(taskId);
          return;
        }
        if (state.running) state = state.copyWith(status: 'done');
      },
    );
  }

  void _scheduleReconnect(String taskId) {
    if (_reconnectTimer != null) return;
    if (_reconnectAttempts >= 20) {
      state = state.copyWith(status: 'error', error: '电脑连接中断,重连失败');
      return;
    }
    _reconnectAttempts += 1;
    _reconnectTimer = Timer(Duration(milliseconds: 500 * _reconnectAttempts.clamp(1, 6)), () async {
      _reconnectTimer = null;
      if (!state.running || state.taskId != taskId) return;
      // 先刷新一次任务状态,确认任务是否已结束
      try {
        final snapshot = await ref.read(apiProvider)!.harnessTask(taskId);
        if (!snapshot.running) {
          state = state.copyWith(status: snapshot.status);
          return;
        }
      } catch (_) {
        // 刷新失败就直接重连流
      }
      await _attachStream(taskId, reset: true);
    });
  }

  /// App 回到前台:刷新节点/工作区,并重新接上仍在运行的任务流。
  Future<void> onResume() async {
    final taskId = state.taskId;
    if (taskId != null && state.running) {
      _reconnectAttempts = 0;
      await _attachStream(taskId, reset: true);
    }
    await load();
  }
  Future<void> startTask(String prompt) async {
    final api = ref.read(apiProvider);
    final sessionId = state.selectedSessionId;
    if (api == null || sessionId == null || prompt.trim().isEmpty) return;

    state = state.copyWith(
      status: 'running',
      viewingTask: true,
      viewingSession: false,
      thinking: '',
      output: '',
      toolEvents: const [],
      confirm: null,
      confirmRemaining: 0,
      error: null,
    );

    try {
      final taskId = await api.startHarnessTask(
        sessionId: sessionId,
        prompt: prompt.trim(),
        permissionMode: state.permissionMode,
        requireApproval: state.confirmTools,
      );
      if (taskId.isEmpty) throw ApiException('服务器未返回 task_id');
      state = state.copyWith(taskId: taskId);
      // 等待期:M3.6 起前台服务保活 + 通知栏常驻,跑完/出错再提醒
      final firstLine = prompt.trim().split('\n').first;
      await WaitAlert.start(
        title: '鲸灵 · 电脑在跑任务',
        text: firstLine.length > 40 ? '${firstLine.substring(0, 40)}…' : firstLine,
      );
      _reconnectAttempts = 0;
      await _attachStream(taskId);
    } on ApiException catch (error) {
      state = state.copyWith(status: 'error', error: error.message);
    }
  }

  Future<void> stop() async {
    final api = ref.read(apiProvider);
    final taskId = state.taskId;
    if (api == null || taskId == null) return;
    try {
      await api.stopHarnessTask(taskId);
      await WaitAlert.stop();
      state = state.copyWith(status: 'stopped');
    } on ApiException catch (error) {
      state = state.copyWith(error: error.message);
    }
  }

  Future<void> answerConfirm(bool allow) async {
    final api = ref.read(apiProvider);
    final taskId = state.taskId;
    final confirm = state.confirm;
    if (api == null || taskId == null || confirm == null) return;
    _ticker?.cancel();
    state = state.copyWith(confirm: null, confirmRemaining: 0);
    try {
      await api.confirmHarnessTask(taskId: taskId, approvalId: confirm.approvalId, allow: allow);
    } on ApiException catch (error) {
      state = state.copyWith(error: error.message);
    }
  }

  void _applyEvent(HarnessEvent event) {
    switch (event.kind) {
      case 'output':
        state = state.copyWith(output: state.output + ((event.payload['text'] as String?) ?? ''));
      case 'thinking':
        state = state.copyWith(
            thinking: state.thinking + ((event.payload['text'] as String?) ?? ''));
      case 'tool':
        state = state.copyWith(toolEvents: [...state.toolEvents, event]);
      case 'confirm_request':
        final request = HarnessConfirmRequest.fromPayload(event.payload);
        state = state.copyWith(confirm: request, confirmRemaining: request.timeoutSec);
        _startCountdown(request.timeoutSec);
        if (!AppVisibility.foreground) {
          unawaited(WaitAlert.notifyResult(
            title: '电脑要你确认一个操作',
            text: '工具:${request.tool} · 请在 ${request.timeoutSec} 秒内回到 App,超时会自动拒绝',
          ));
        }
      case 'confirm_result':
        _ticker?.cancel();
        state = state.copyWith(confirm: null, confirmRemaining: 0);
      case 'status':
        final status = (event.payload['status'] as String?) ?? '';
        if (status == 'idle') {
          final wasRunning = state.running;
          state = state.copyWith(status: wasRunning ? 'done' : state.status);
          unawaited(WaitAlert.stop());
          if (wasRunning && !AppVisibility.foreground) {
            unawaited(WaitAlert.notifyResult(
              title: '电脑上的任务结束了',
              text: '打开鲸灵看结果',
            ));
          }
        } else {
          state = state.copyWith(status: status);
        }
      case 'error':
        state = state.copyWith(
          status: 'error',
          error: (event.payload['message'] as String?) ?? '电脑节点报错',
        );
        unawaited(WaitAlert.stop());
        if (!AppVisibility.foreground) {
          unawaited(WaitAlert.notifyResult(
            title: '电脑上的任务出错了',
            text: (event.payload['message'] as String?) ?? '打开鲸灵看看',
          ));
        }
    }
  }

  void _startCountdown(int seconds) {
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 1), (timer) {
      final remaining = state.confirmRemaining - 1;
      if (remaining <= 0) {
        timer.cancel();
        // 超时:服务端会自动按拒绝处理,这里只清掉卡片
        state = state.copyWith(confirm: null, confirmRemaining: 0);
        return;
      }
      state = state.copyWith(confirmRemaining: remaining);
    });
  }

  void clearError() => state = state.copyWith(error: null);
}

final harnessProvider = NotifierProvider<HarnessController, HarnessState>(HarnessController.new);
