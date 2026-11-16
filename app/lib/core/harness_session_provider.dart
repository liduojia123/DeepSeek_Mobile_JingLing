import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/harness_stream.dart';
import 'api.dart';
import 'providers.dart';
import 'wait_alert.dart';

/// 一个 dsh 会话在手机上的实时视图:时间线 + 状态 + 输入。
class HarnessSessionState {
  const HarnessSessionState({
    this.sessionId = '',
    this.title = '',
    this.connecting = false,
    this.sending = false,
    this.status = 'idle',
    this.permission,
    this.model,
    this.error,
    this.revision = 0,
    this.timeline,
  });

  final String sessionId;
  final String title;
  final bool connecting;
  final bool sending;

  /// 电脑上的会话状态:idle / running
  final String status;
  final String? permission;
  final String? model;
  final String? error;

  /// 每次时间线变化 +1,用来通知 UI 重绘(时间线本身是可变对象,避免整树复制)
  final int revision;
  final HarnessTimeline? timeline;

  bool get running => status == 'running';
  HarnessTimeline get view => timeline ?? HarnessTimeline();

  HarnessSessionState copyWith({
    String? sessionId,
    String? title,
    bool? connecting,
    bool? sending,
    String? status,
    String? permission,
    String? model,
    String? error,
    bool clearError = false,
    int? revision,
    HarnessTimeline? timeline,
  }) =>
      HarnessSessionState(
        sessionId: sessionId ?? this.sessionId,
        title: title ?? this.title,
        connecting: connecting ?? this.connecting,
        sending: sending ?? this.sending,
        status: status ?? this.status,
        permission: permission ?? this.permission,
        model: model ?? this.model,
        error: clearError ? null : (error ?? this.error),
        revision: revision ?? this.revision,
        timeline: timeline ?? this.timeline,
      );
}

class HarnessSessionController extends Notifier<HarnessSessionState> {
  StreamSubscription<HarnessStreamEvent>? _subscription;
  Timer? _retryTimer;
  int _attempts = 0;
  /// 递增代号:切会话后旧流的事件必须丢弃
  int _generation = 0;
  /// 是否已进入"等待电脑结果"态(前台服务在跑)
  bool _waiting = false;
  /// 通知权限只问一次,避免每次等待都弹
  bool _askedNotificationPermission = false;

  @override
  HarnessSessionState build() {
    ref.onDispose(_teardown);
    return const HarnessSessionState();
  }

  void _teardown() {
    _subscription?.cancel();
    _subscription = null;
    _retryTimer?.cancel();
    _retryTimer = null;
    _generation += 1;
    unawaited(_endWait(notify: false));
  }

  String get _sessionLabel => state.title.trim().isEmpty ? '电脑上的会话' : state.title.trim();

  /// 进入等待态:前台服务保活 SSE + 通知栏常驻「正在等电脑」
  Future<void> _beginWait() async {
    if (_waiting) return;
    _waiting = true;
    if (!_askedNotificationPermission) {
      _askedNotificationPermission = true;
      await WaitAlert.ensurePermission();
    }
    final started = await WaitAlert.start(
      title: '鲸灵 · 正在等电脑',
      text: '$_sessionLabel 正在执行,可以锁屏',
    );
    if (!started) {
      // 没有通知权限:不保活前台服务,但会话页照常工作
      _waiting = false;
      return;
    }
    // 权限申请的 await 期间这一轮可能已经结束(或被切走):立刻收掉,避免服务空转
    if (!_waiting) {
      await WaitAlert.stop();
    }
  }

  /// 结束等待。`notify` 为真且 App 不在前台时发一条结果通知。
  Future<void> _endWait({required bool notify, String? message}) async {
    if (!_waiting) return;
    _waiting = false;
    await WaitAlert.stop();
    if (notify && !AppVisibility.foreground) {
      await WaitAlert.notifyResult(
        title: '电脑上的这一轮结束了',
        text: '$_sessionLabel · ${message ?? '可以回来看结果了'}',
      );
    }
  }

  String _reasonText(String? reason) {
    switch (reason) {
      case 'completed':
      case 'end_turn':
        return '已完成';
      case 'error':
        return '出错了,打开看看';
      case 'interrupted':
        return '已中断';
      default:
        return reason == null || reason.isEmpty ? '可以回来看结果了' : '结束($reason)';
    }
  }

  /// 进入会话:重置时间线,从 after_seq=0 拉历史并接实时。
  Future<void> open(String sessionId, {String title = ''}) async {
    _teardown();
    final generation = _generation;
    _attempts = 0;
    state = HarnessSessionState(
      sessionId: sessionId,
      title: title,
      connecting: true,
      timeline: HarnessTimeline(),
      revision: DateTime.now().microsecondsSinceEpoch,
    );
    await _connect(generation);
  }

  Future<void> _connect(int generation) async {
    if (generation != _generation) return;
    final api = ref.read(apiProvider);
    if (api == null) {
      state = state.copyWith(connecting: false, error: '未配对');
      return;
    }
    final timeline = state.timeline ?? HarnessTimeline();
    final afterSeq = timeline.lastSeq;
    state = state.copyWith(connecting: true, clearError: true, revision: state.revision + 1);
    try {
      await _subscription?.cancel();
    } catch (_) {
      // ignore
    }
    _subscription = api.harnessSessionStream(state.sessionId, afterSeq: afterSeq).listen(
      (event) {
        if (generation != _generation) return;
        _apply(event);
        _attempts = 0;
      },
      onError: (Object error) {
        if (generation != _generation) return;
        _scheduleReconnect(error is ApiException ? error.message : '$error');
      },
      onDone: () {
        if (generation != _generation) return;
        _scheduleReconnect(null);
      },
      cancelOnError: true,
    );
    state = state.copyWith(connecting: false);
  }

  void _apply(HarnessStreamEvent event) {
    final timeline = state.timeline;
    if (timeline == null) return;
    var changed = false;
    switch (event) {
      case HarnessSessionReady():
        state = state.copyWith(
          status: event.running ? 'running' : 'idle',
          permission: event.permission,
          model: event.model,
          revision: state.revision + 1,
        );
        if (event.running) unawaited(_beginWait());
        return;
      case HarnessSessionEvent():
        changed = timeline.applyEvent(event);
        if (changed) {
          state = state.copyWith(
            revision: state.revision + 1,
            status: timeline.running ? 'running' : 'idle',
          );
          if (timeline.running) {
            unawaited(_beginWait());
          } else if (event.kind == 'turn_end') {
            unawaited(_endWait(notify: true, message: _reasonText(timeline.lastTurnEndReason)));
          }
        }
        return;
      case HarnessSessionLive():
        if (event.kind == 'error') {
          state = state.copyWith(error: event.message ?? '电脑节点断开连接', revision: state.revision + 1);
          if (_waiting) {
            unawaited(_endWait(notify: true, message: '电脑断线了,结果没等到'));
          }
          return;
        }
        changed = timeline.applyLive(event);
        if (changed) {
          state = state.copyWith(
            revision: state.revision + 1,
            status: timeline.running ? 'running' : 'idle',
            error: event.kind == 'error' ? (event.message ?? '出错了') : state.error,
          );
        }
        return;
    }
  }

  /// 断线自动重连:用 lastSeq 续传,指数退避(1s→10s,最多 20 次)
  void _scheduleReconnect(String? message) {
    if (_retryTimer != null) return;
    if (_attempts >= 20) {
      state = state.copyWith(error: message ?? '会话连接已断开', revision: state.revision + 1);
      return;
    }
    _attempts += 1;
    final seconds = (1 << (_attempts - 1)).clamp(1, 10).toInt();
    final delay = Duration(seconds: seconds);
    state = state.copyWith(
      connecting: true,
      error: message,
      revision: state.revision + 1,
    );
    final generation = _generation;
    _retryTimer = Timer(delay, () {
      _retryTimer = null;
      if (generation != _generation) return;
      unawaited(_connect(generation));
    });
  }

  /// 手机输入:auto 由电脑端判定(正在跑 → 插话,空闲 → 追加)
  Future<void> send(String text, {String mode = 'auto'}) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty || state.sending) return;
    final api = ref.read(apiProvider);
    if (api == null) return;
    final timeline = state.timeline;
    if (timeline != null) timeline.pendingInput = trimmed;
    state = state.copyWith(sending: true, clearError: true, revision: state.revision + 1);
    try {
      final result = await api.harnessSessionInput(state.sessionId, text: trimmed, mode: mode);
      final applied = (result['mode'] as String?) ?? mode;
      state = state.copyWith(
        sending: false,
        status: timeline?.running == true || applied == 'steer' ? 'running' : state.status,
        revision: state.revision + 1,
      );
    } on ApiException catch (error) {
      if (timeline != null) timeline.pendingInput = null;
      state = state.copyWith(sending: false, error: error.message, revision: state.revision + 1);
    }
  }

  Future<void> stop() async {
    final api = ref.read(apiProvider);
    if (api == null) return;
    try {
      await api.harnessStopSession(state.sessionId);
      state = state.copyWith(status: 'idle', revision: state.revision + 1);
    } on ApiException catch (error) {
      state = state.copyWith(error: error.message, revision: state.revision + 1);
    }
  }

  Future<void> setPermission(String mode) async {
    final api = ref.read(apiProvider);
    if (api == null) return;
    try {
      await api.harnessSetSessionPermission(state.sessionId, mode);
      state = state.copyWith(permission: mode, revision: state.revision + 1);
    } on ApiException catch (error) {
      state = state.copyWith(error: error.message, revision: state.revision + 1);
    }
  }

  void clearError() => state = state.copyWith(clearError: true, revision: state.revision + 1);

  /// 离开页面:断开流,避免后台一直占着 SSE。
  void leave() => _teardown();
}

final harnessSessionProvider =
    NotifierProvider<HarnessSessionController, HarnessSessionState>(HarnessSessionController.new);
