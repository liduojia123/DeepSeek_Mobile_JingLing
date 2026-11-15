import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:record/record.dart' show Amplitude;

import '../models/models.dart';
import 'api.dart';
import 'providers.dart';
import 'voice.dart';

/// 语音会话阶段
enum VoiceStage { idle, listening, recognizing, thinking, speaking, error }

class VoiceSessionState {
  const VoiceSessionState({
    this.stage = VoiceStage.idle,
    this.volume = 0,
    this.heard = false,
    this.transcript,
    this.lastAnswer,
    this.error,
    this.round = 0,
  });

  final VoiceStage stage;
  /// 当前音量(0..1,用于 UI 脉冲)
  final double volume;
  /// 本轮是否已检测到人声
  final bool heard;
  /// 最近一次识别文本
  final String? transcript;
  /// 最近一次回答文本
  final String? lastAnswer;
  final String? error;
  final int round;

  bool get active => stage != VoiceStage.idle;

  VoiceSessionState copyWith({
    VoiceStage? stage,
    double? volume,
    bool? heard,
    String? transcript,
    String? lastAnswer,
    String? error,
    int? round,
  }) =>
      VoiceSessionState(
        stage: stage ?? this.stage,
        volume: volume ?? this.volume,
        heard: heard ?? this.heard,
        transcript: transcript ?? this.transcript,
        lastAnswer: lastAnswer ?? this.lastAnswer,
        error: error ?? this.error,
        round: round ?? this.round,
      );
}

/// 连续语音对话(免按住):
/// 聆听 → 静音自动断句 → ASR → 发送 → 等回答 → TTS 播报 → 继续聆听。
/// 播放中点击圆钮 = 打断并立刻回到聆听。
class VoiceSessionController extends Notifier<VoiceSessionState> {
  final VoiceService _voice = VoiceService();
  bool _active = false;
  StreamSubscription<Amplitude>? _amplitude;
  Timer? _watchdog;
  Future<void>? _loop;

  static const double _voiceThresholdDb = -38;
  static const int _silenceMsToStop = 900;
  static const int _noSpeechTimeoutMs = 20000;

  @override
  VoiceSessionState build() {
    ref.onDispose(() {
      _active = false;
      _amplitude?.cancel();
      _watchdog?.cancel();
      _voice.dispose();
    });
    return const VoiceSessionState();
  }

  /// 开始语音模式(需要对应会话已在 chatProvider 中打开)。
  Future<void> start() async {
    if (_active) return;
    _active = true;
    state = const VoiceSessionState(stage: VoiceStage.listening);
    _loop ??= _run();
    await _loop;
  }

  /// 退出语音模式。
  Future<void> stop() async {
    _active = false;
    _amplitude?.cancel();
    _amplitude = null;
    _watchdog?.cancel();
    _watchdog = null;
    try {
      if (_voice.isRecording) await _voice.cancelRecording();
    } catch (_) {
      // ignore
    }
    await _voice.stop();
    state = const VoiceSessionState();
    _loop = null;
  }

  /// 打断播报,立即回到聆听。
  Future<void> interrupt() async {
    if (!_active) return;
    await _voice.stop();
    if (_active) unawaited(_listenOnce());
  }

  Future<void> _run() async {
    while (_active) {
      await _listenOnce();
      if (!_active) break;
    }
  }

  Future<void> _listenOnce() async {
    if (!_active) return;
    final api = ref.read(apiProvider);
    if (api == null) {
      state = state.copyWith(stage: VoiceStage.error, error: '还没有连接服务器');
      return;
    }

    state = state.copyWith(stage: VoiceStage.listening, heard: false, volume: 0, error: null);
    final started = await _voice.startRecording();
    if (!started) {
      state = state.copyWith(stage: VoiceStage.error, error: '麦克风不可用或未授权');
      _active = false;
      return;
    }

    var heard = false;
    var silenceMs = 0;
    var elapsedMs = 0;
    final done = Completer<void>();

    _amplitude = _voice.amplitudeStream().listen((amplitude) {
      if (!_active || done.isCompleted) return;
      elapsedMs += 100;
      final current = amplitude.current;
      // -60..0 dBFS → 0..1 供 UI 用
      final normalized = ((current + 60) / 60).clamp(0.0, 1.0);
      if (current > _voiceThresholdDb) {
        heard = true;
        silenceMs = 0;
      } else if (heard) {
        silenceMs += 100;
      }
      state = state.copyWith(volume: normalized, heard: heard);
      if (heard && silenceMs >= _silenceMsToStop) done.complete();
      if (!heard && elapsedMs >= _noSpeechTimeoutMs) done.complete();
    });

    // 兜底:最长 60 秒强制断句
    _watchdog = Timer(const Duration(seconds: 60), () {
      if (!done.isCompleted) done.complete();
    });
    await done.future;
    _watchdog?.cancel();
    _watchdog = null;
    await _amplitude?.cancel();
    _amplitude = null;

    final bytes = await _voice.stopRecording();
    if (!_active) return;
    if (!heard || bytes == null || bytes.isEmpty) {
      // 没人说话:继续听
      return;
    }

    state = state.copyWith(stage: VoiceStage.recognizing, volume: 0);
    String text;
    try {
      text = (await api.transcribe(bytes)).trim();
    } on ApiException catch (error) {
      state = state.copyWith(stage: VoiceStage.error, error: error.message);
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      return;
    }
    if (!_active) return;
    if (text.isEmpty) {
      state = state.copyWith(stage: VoiceStage.listening, transcript: null);
      return;
    }

    state = state.copyWith(
      stage: VoiceStage.thinking,
      transcript: text,
      round: state.round + 1,
    );
    await ref.read(chatProvider.notifier).send(text);

    // 等回答结束(最多 120 秒)
    var waited = 0;
    while (_active && ref.read(chatProvider).generating && waited < 120000) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      waited += 200;
    }
    if (!_active) return;

    final chat = ref.read(chatProvider);
    final answers = chat.detail?.pathNodes.where((node) => node.isAssistant).toList(growable: false) ??
        const <MessageNode>[];
    final answer = answers.isEmpty ? '' : answers.last.text;
    if (answer.trim().isEmpty) {
      return;
    }
    state = state.copyWith(stage: VoiceStage.speaking, lastAnswer: answer);

    try {
      final wav = await api.synthesize(answer);
      if (!_active) return;
      await _voice.play(wav);
    } on ApiException catch (error) {
      state = state.copyWith(stage: VoiceStage.error, error: error.message);
      await Future<void>.delayed(const Duration(milliseconds: 800));
    }
    // 播报结束(或被打断)后继续聆听
    if (_active) {
      state = state.copyWith(stage: VoiceStage.listening);
    }
  }
}

final voiceSessionProvider =
    NotifierProvider<VoiceSessionController, VoiceSessionState>(VoiceSessionController.new);
