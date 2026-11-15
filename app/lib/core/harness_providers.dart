import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/harness.dart';
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
      );
}

/// 电脑页控制器:加载节点/工作区 → 派任务 → 订阅事件 → 处理确认卡片。
class HarnessController extends Notifier<HarnessState> {
  StreamSubscription<HarnessEvent>? _events;
  Timer? _ticker;

  @override
  HarnessState build() {
    ref.onDispose(() {
      _events?.cancel();
      _ticker?.cancel();
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

  void selectSession(String sessionId) {
    state = state.copyWith(selectedSessionId: sessionId);
  }

  Future<void> startTask(String prompt) async {
    final api = ref.read(apiProvider);
    final sessionId = state.selectedSessionId;
    if (api == null || sessionId == null || prompt.trim().isEmpty) return;

    state = state.copyWith(
      status: 'running',
      thinking: '',
      output: '',
      toolEvents: const [],
      confirm: null,
      confirmRemaining: 0,
      error: null,
    );

    try {
      final taskId = await api.startHarnessTask(sessionId: sessionId, prompt: prompt.trim());
      if (taskId.isEmpty) throw ApiException('服务器未返回 task_id');
      state = state.copyWith(taskId: taskId);
      await _events?.cancel();
      _events = api.harnessTaskEvents(taskId).listen(
        _applyEvent,
        onError: (Object error) => state = state.copyWith(
          status: 'error',
          error: error is ApiException ? error.message : '$error',
        ),
        onDone: () {
          if (state.running) state = state.copyWith(status: 'done');
        },
      );
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
      case 'confirm_result':
        _ticker?.cancel();
        state = state.copyWith(confirm: null, confirmRemaining: 0);
      case 'status':
        final status = (event.payload['status'] as String?) ?? '';
        if (status == 'idle') {
          state = state.copyWith(status: state.running ? 'done' : state.status);
        } else {
          state = state.copyWith(status: status);
        }
      case 'error':
        state = state.copyWith(
          status: 'error',
          error: (event.payload['message'] as String?) ?? '电脑节点报错',
        );
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
